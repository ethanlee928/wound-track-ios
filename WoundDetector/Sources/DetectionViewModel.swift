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
    let className: String
    let confidence: Float
    let woundStage: WoundStage?
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
    private var modelReady = false
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
        modelReady = false
        isModelLoading = true

        // Store the YOLO instance immediately to keep it alive during async loading.
        // The init returns synchronously, but model compilation happens on a background thread.
        // Without this, the YOLO object gets deallocated before loading finishes.
        let yolo = YOLO(variant.rawValue, task: .segment) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Ignore stale completions if user switched models again
                guard self.currentVariant == variant else { return }
                self.isModelLoading = false
                switch result {
                case .success(let model):
                    self.model = model
                    self.modelReady = true
                    model.setConfidenceThreshold(0.25)
                    model.setIouThreshold(0.45)
                case .failure(let error):
                    self.showError(message: "Failed to load \(variant.displayName) model: \(error.localizedDescription)")
                }
            }
        }
        // Hold a strong reference so the YOLO object survives until completion fires
        self.model = yolo
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

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = model(normalizedImage)

            await MainActor.run {
                self?.annotatedImage = result.annotatedImage
                self?.detections = result.boxes.map { box in
                    DetectionResult(
                        className: box.cls,
                        confidence: box.conf,
                        woundStage: WoundStage.from(classLabel: box.cls)
                    )
                }
                self?.hasRunInference = true
                self?.isProcessing = false
            }
        }
    }

    private func showError(message: String) {
        errorMessage = message
        showError = true
    }
}
