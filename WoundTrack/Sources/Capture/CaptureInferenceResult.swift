import CoreGraphics
import UIKit

/// Bundle of data the longitudinal capture flow needs back from the YOLO
/// pipeline. Separate from `DetectionResult` because the capture flow only
/// cares about the "primary" (first) detection and needs mask pixels.
struct CaptureInferenceResult {
    let annotatedImage: UIImage?
    let combinedMask: CGImage?
    let firstBox: CGRect
    let className: String
    let confidence: Float
    let stageName: String?
    let stageConfidence: Float?
}
