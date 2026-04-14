import SwiftUI
import UIKit
import YOLO

extension UIImage {
    /// Re-draws the image with `.up` orientation so that the raw pixel data
    /// matches the visual orientation. This prevents CoreML from processing
    /// a rotated pixel buffer when the camera captures in portrait.
    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        draw(in: CGRect(origin: .zero, size: size))
        let normalized = UIGraphicsGetImageFromCurrentImageContext() ?? self
        UIGraphicsEndImageContext()
        return normalized
    }
}

struct DetectionResult: Identifiable {
    let id = UUID()
    let objectId: Int       // 1-based, matches the numbered badge drawn on the image
    let className: String
    let confidence: Float
    var woundStage: WoundStage?
    var stageConfidence: Float?
}

@MainActor
class DetectionViewModel: ObservableObject {
    @Published var annotatedImage: UIImage?
    @Published var detections: [DetectionResult] = []
    @Published var isProcessing = false
    @Published var hasRunInference = false
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var isModelLoading = false
    @Published private(set) var currentVariant: ModelVariant

    private var model: YOLO?
    private var segModelReady = false
    private var clsModelReady = false
    private var modelReady: Bool { segModelReady && clsModelReady }
    private var stageClassifier: StageClassifier?
    private static let modelVariantDefaultsKey = "selectedModelVariant"

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.modelVariantDefaultsKey)
            .flatMap(ModelVariant.init(rawValue:)) ?? .woundNano
        self.currentVariant = saved
        loadModel(variant: saved)
    }

    /// Switch to a different model variant. The current model is released and the
    /// new one is loaded asynchronously. Inference is blocked while loading.
    func switchModel(to variant: ModelVariant) {
        guard variant != currentVariant else { return }
        currentVariant = variant
        UserDefaults.standard.set(variant.rawValue, forKey: Self.modelVariantDefaultsKey)
        loadModel(variant: variant)
    }

    private func loadModel(variant: ModelVariant) {
        segModelReady = false
        clsModelReady = variant.stageClassifierName == nil  // no cls needed → already "ready"
        isModelLoading = true
        stageClassifier = nil

        // Store the YOLO instance immediately to keep it alive during async loading.
        let yolo = YOLO(variant.rawValue, task: .segment) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard self.currentVariant == variant else { return }
                switch result {
                case .success(let model):
                    self.model = model
                    self.segModelReady = true
                    model.setConfidenceThreshold(0.25)
                    model.setIouThreshold(0.45)
                case .failure(let error):
                    self.showError(message: "Failed to load \(variant.displayName) model: \(error.localizedDescription)")
                }
                self.checkLoadingComplete()
            }
        }
        // Hold a strong reference so the YOLO object survives until completion fires
        self.model = yolo

        // Load stage classifier in parallel if this variant has one
        if let clsName = variant.stageClassifierName {
            let classifier = StageClassifier(modelName: clsName)
            classifier.load { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard self.currentVariant == variant else { return }
                    switch result {
                    case .success:
                        self.stageClassifier = classifier
                    case .failure(let error):
                        // Non-fatal: seg-only mode continues to work
                        print("Stage classifier failed to load: \(error.localizedDescription)")
                        self.stageClassifier = nil
                    }
                    self.clsModelReady = true
                    self.checkLoadingComplete()
                }
            }
        }
    }

    private func checkLoadingComplete() {
        if modelReady {
            isModelLoading = false
        }
    }

    func runInference(on image: UIImage) {
        guard let model = model, modelReady else {
            showError(message: "Model not loaded yet. Please wait and try again.")
            return
        }

        isProcessing = true
        hasRunInference = false
        annotatedImage = nil
        detections = []

        // Normalize image orientation so CoreML receives correctly oriented pixels.
        // Camera photos often have .right orientation metadata that CoreML ignores,
        // causing the image to appear rotated during inference.
        let normalizedImage = image.normalizedOrientation()

        let classifier = self.stageClassifier

        Task.detached(priority: .userInitiated) { [weak self] in
            // PGIE: run segmentation
            let result = model(normalizedImage)

            // Build initial detection results from seg output
            var detections = result.boxes.enumerated().map { (i, box) in
                DetectionResult(
                    objectId: i + 1,
                    className: box.cls,
                    confidence: box.conf,
                    woundStage: WoundStage.from(classLabel: box.cls)
                )
            }

            // SGIE: run stage classifier on each wound crop
            if let classifier = classifier, classifier.isReady, !result.boxes.isEmpty {
                let imageSize = normalizedImage.size
                let crops: [UIImage?] = result.boxes.map { box in
                    let padded = paddedBBox(box.xywh, in: imageSize)
                    return normalizedImage.cropped(to: padded)
                }
                let validCrops = crops.map { $0 ?? normalizedImage }
                let stages = classifier.classify(crops: validCrops)

                for i in detections.indices {
                    if let stage = stages[i] {
                        detections[i].woundStage = WoundStage.from(classLabel: stage.name)
                        detections[i].stageConfidence = stage.confidence
                    }
                }
            }

            // Draw numbered badges on the annotated image so the user can map
            // each info panel row to its corresponding wound on the image.
            let finalImage: UIImage? = result.annotatedImage.map {
                Self.drawObjectBadges(on: $0, boxes: result.boxes.map { $0.xywh })
            }

            await MainActor.run {
                self?.annotatedImage = finalImage
                self?.detections = detections
                self?.hasRunInference = true
                self?.isProcessing = false
            }
        }
    }

    /// Run inference and return everything the longitudinal capture flow needs:
    /// the annotated UIImage, the combined mask CGImage, the first detection's
    /// bounding box (for mask-intersection), and the top stage label. Does NOT
    /// mutate any `@Published` state on this view model, so it can coexist with
    /// the single-shot flow.
    ///
    /// Returns nil if the model isn't ready or no wound was detected.
    func inferForCapture(image: UIImage) async -> CaptureInferenceResult? {
        guard let model = model, modelReady else { return nil }
        let classifier = self.stageClassifier
        return await Task.detached(priority: .userInitiated) { () -> CaptureInferenceResult? in
            let result = model(image)
            guard let firstBox = result.boxes.first else { return nil }

            var stageLabel: StageLabel?
            if let classifier = classifier, classifier.isReady {
                let padded = paddedBBox(firstBox.xywh, in: image.size)
                if let crop = image.cropped(to: padded) {
                    stageLabel = classifier.classify(crops: [crop]).first ?? nil
                }
            }
            return CaptureInferenceResult(
                annotatedImage: result.annotatedImage,
                combinedMask: result.masks?.combinedMask,
                firstBox: firstBox.xywh,
                className: firstBox.cls,
                confidence: firstBox.conf,
                stageName: stageLabel?.name,
                stageConfidence: stageLabel?.confidence
            )
        }.value
    }

    /// Draw numbered circular badges at the top-left of each bounding box.
    nonisolated private static func drawObjectBadges(on image: UIImage, boxes: [CGRect]) -> UIImage {
        guard !boxes.isEmpty else { return image }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { ctx in
            image.draw(at: .zero)

            let badgeRadius: CGFloat = max(18, image.size.width * 0.025)
            let font = UIFont.boldSystemFont(ofSize: badgeRadius * 0.9)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            let textAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraphStyle,
            ]

            for (i, box) in boxes.enumerated() {
                let center = CGPoint(
                    x: box.minX + badgeRadius + 4,
                    y: box.minY + badgeRadius + 4
                )
                // Filled circle
                let circle = UIBezierPath(
                    arcCenter: center,
                    radius: badgeRadius,
                    startAngle: 0,
                    endAngle: .pi * 2,
                    clockwise: true
                )
                UIColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 0.85).setFill()
                circle.fill()
                UIColor.white.setStroke()
                circle.lineWidth = 2
                circle.stroke()

                // Number text
                let label = "\(i + 1)"
                let textSize = (label as NSString).size(withAttributes: textAttrs)
                let textRect = CGRect(
                    x: center.x - textSize.width / 2,
                    y: center.y - textSize.height / 2,
                    width: textSize.width,
                    height: textSize.height
                )
                (label as NSString).draw(in: textRect, withAttributes: textAttrs)
            }
        }
    }

    private func showError(message: String) {
        errorMessage = message
        showError = true
    }
}
