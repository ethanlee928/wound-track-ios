import ARKit
import CoreGraphics
import CoreVideo
import UIKit
import simd

/// The bundle of data produced by `ARCaptureView` when the user taps the shutter.
///
/// Holds references to the raw ARKit `CVPixelBuffer`s for depth / confidence and
/// the `simd_float3x3` intrinsics. The RGB frame is already rendered as a
/// `UIImage` with `.up` orientation so downstream code doesn't have to unwrap
/// YCbCr → RGB.
struct ARCapturedFrame {
    /// RGB image at the captured resolution (typically 1920×1440 on iPhone Pro).
    let image: UIImage
    /// Depth in meters, `kCVPixelFormatType_DepthFloat32`, typically 256×192.
    let depthMap: CVPixelBuffer
    /// Optional confidence map. `ARConfidenceLevel` raw values (0/1/2).
    let confidenceMap: CVPixelBuffer?
    /// Camera intrinsics in captured-image pixel space (fx, fy, cx, cy).
    let intrinsics: simd_float3x3
    /// Captured image size, passed alongside intrinsics so the consumer doesn't
    /// have to read it off the `UIImage`.
    let imageSize: CGSize
}
