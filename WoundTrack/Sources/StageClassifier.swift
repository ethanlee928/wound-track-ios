import UIKit
import YOLO

/// Result from the SGIE stage classifier for a single wound crop.
struct StageLabel {
    let name: String        // e.g., "stage1", "stage2", "stage3", "stage4"
    let confidence: Float   // 0.0 – 1.0
}

/// Secondary Generic Inference Engine (SGIE) that classifies wound crops by
/// clinical severity stage. Wraps a YOLO classification model.
///
/// Usage:
/// 1. Create with the model name (must match a `.mlpackage` in Resources/).
/// 2. Call `load(completion:)` — model compiles asynchronously.
/// 3. Once `isReady`, call `classify(crops:)` synchronously on a background thread.
///
/// Thread safety: `classify(crops:)` is synchronous and should be called from
/// a background queue (e.g., inside `Task.detached`). It is NOT safe to call
/// from the main thread — it will block the UI.
final class StageClassifier {
    let modelName: String
    private var yolo: YOLO?
    private(set) var isReady = false

    init(modelName: String) {
        self.modelName = modelName
    }

    /// Load and compile the CoreML classifier asynchronously.
    /// Completion fires on an unspecified queue — caller is responsible for
    /// dispatching to main if needed.
    func load(completion: @escaping (Result<Void, Error>) -> Void) {
        let instance = YOLO(modelName, task: .classify) { [weak self] result in
            switch result {
            case .success(let model):
                self?.yolo = model
                self?.isReady = true
                completion(.success(()))
            case .failure(let error):
                completion(.failure(error))
            }
        }
        // Hold a strong reference so the YOLO object survives until completion fires.
        self.yolo = instance
    }

    /// Classify an array of wound crops. Returns one `StageLabel?` per input,
    /// preserving input order (result[i] corresponds to crops[i]).
    /// Returns nil for a crop if inference fails. Never throws.
    ///
    /// - Important: Call from a background thread. This is synchronous and blocking.
    func classify(crops: [UIImage]) -> [StageLabel?] {
        guard let yolo = yolo, isReady else {
            return Array(repeating: nil, count: crops.count)
        }
        return crops.map { crop in
            let result = yolo(crop)
            guard let probs = result.probs else { return nil }
            return StageLabel(
                name: probs.top1,
                confidence: probs.top1Conf
            )
        }
    }
}

// MARK: - Crop helpers

extension UIImage {
    /// Crop to a pixel-coordinate rect. Assumes the image has `.up` orientation
    /// (caller must normalize EXIF first via `normalizedOrientation()`).
    func cropped(to rect: CGRect) -> UIImage? {
        guard let cgImage = cgImage?.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }
}

/// Expand a bounding box by a padding fraction on each side, clamped to image bounds.
/// Negative inset = expand outward.
func paddedBBox(_ bbox: CGRect, in imageSize: CGSize, padding: CGFloat = 0.3) -> CGRect {
    let padW = bbox.width * padding
    let padH = bbox.height * padding
    let expanded = bbox.insetBy(dx: -padW, dy: -padH)
    return expanded.intersection(CGRect(origin: .zero, size: imageSize))
}
