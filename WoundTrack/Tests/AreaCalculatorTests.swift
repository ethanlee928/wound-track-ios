import CoreVideo
import XCTest
import simd
@testable import WoundTrack

final class AreaCalculatorTests: XCTestCase {

    // MARK: - Helpers

    /// Build a depth `CVPixelBuffer` (`kCVPixelFormatType_DepthFloat32`) from a
    /// row-major float array.
    private func makeDepthBuffer(width: Int, height: Int, fill: (Int, Int) -> Float) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil, width, height,
            kCVPixelFormatType_DepthFloat32,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &buffer
        )
        precondition(status == kCVReturnSuccess)
        let buf = buffer!
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let stride = CVPixelBufferGetBytesPerRow(buf) / MemoryLayout<Float>.size
        let ptr = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: Float.self)
        for y in 0..<height {
            for x in 0..<width {
                ptr[y * stride + x] = fill(x, y)
            }
        }
        return buf
    }

    private func fullMask(width: Int, height: Int) -> BooleanMask {
        BooleanMask(width: width, height: height, storage: Array(repeating: true, count: width * height))
    }

    /// Intrinsics for a `w × h` sensor with focal length `f` and centered principal point.
    private func intrinsics(fx: Float, fy: Float, w: Int, h: Int) -> simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(fx, 0, 0),
            SIMD3<Float>(0, fy, 0),
            SIMD3<Float>(Float(w) / 2, Float(h) / 2, 1)
        )
    }

    // MARK: - Test 1: uniform depth accuracy

    /// With uniform depth d and focal length f, a mask of N pixels should measure
    /// `N · (d/f)² · 10⁴` cm². Assert within 0.5% (allowing for depth-map
    /// downsampling and bounds checks).
    func testUniformDepthGivesExpectedArea() {
        let W = 640, H = 480
        let fx: Float = 1440, fy: Float = 1440
        let d: Float = 0.20
        let mask = fullMask(width: W, height: H)
        let depth = makeDepthBuffer(width: W, height: H) { _, _ in d }

        let result = AreaCalculator.measure(
            mask: mask,
            depthMap: depth,
            confidenceMap: nil,
            intrinsics: intrinsics(fx: fx, fy: fy, w: W, h: H),
            captureSize: CGSize(width: W, height: H)
        )

        let expectedCm2 = Double(W * H) * pow(Double(d) / Double(fx), 2) * 10_000
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.areaCm2, expectedCm2, accuracy: expectedCm2 * 0.005)
        // At uniform depth, plane fit is degenerate; tilt should clamp near 0.
        XCTAssertLessThan(result!.tiltAngleRadians, 0.01)
    }

    // MARK: - Test 2: NaN / zero depth pixels skipped

    /// Pixels with NaN or 0 depth must not contribute to area. If they were
    /// counted as zero, total area would be unchanged (still wrong by omission
    /// for NaN specifically). Test: half the mask has valid depth, half NaN.
    /// Area should be ~half the full-valid-depth case.
    func testNaNAndZeroDepthSkipped() {
        let W = 200, H = 200
        let fx: Float = 500, fy: Float = 500
        let d: Float = 0.25
        let mask = fullMask(width: W, height: H)
        let depth = makeDepthBuffer(width: W, height: H) { x, _ in
            x < W / 2 ? d : .nan  // left half valid, right half NaN
        }

        let result = AreaCalculator.measure(
            mask: mask,
            depthMap: depth,
            confidenceMap: nil,
            intrinsics: intrinsics(fx: fx, fy: fy, w: W, h: H),
            captureSize: CGSize(width: W, height: H)
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result!.validPixelCount, W / 2 * H, accuracy: W * H / 50)  // ~2% tolerance
        let expectedHalf = Double(W / 2 * H) * pow(Double(d) / Double(fx), 2) * 10_000
        XCTAssertEqual(result!.areaCm2, expectedHalf, accuracy: expectedHalf * 0.01)

        // Zero depth is also invalid:
        let depthZero = makeDepthBuffer(width: W, height: H) { _, _ in 0 }
        let zeroResult = AreaCalculator.measure(
            mask: mask,
            depthMap: depthZero,
            confidenceMap: nil,
            intrinsics: intrinsics(fx: fx, fy: fy, w: W, h: H),
            captureSize: CGSize(width: W, height: H)
        )
        XCTAssertNil(zeroResult, "All-zero depth should produce nil (<20 valid pixels)")
    }

    // MARK: - Test 3: tilted-plane cos correction

    /// Build a synthetic depth buffer that models a plane tilted ~45° around
    /// the Y axis: depth varies linearly with x. Without oblique correction,
    /// measured area < true area. With correction, measured ≈ true.
    func testTiltedPlaneCosineCorrection() {
        let W = 200, H = 200
        let fx: Float = 500, fy: Float = 500
        let centerDepth: Float = 0.30
        // z(x) = centerDepth + (x - W/2) * slope
        // slope chosen so that tan(θ) = 1 → θ = 45°.
        // At the camera, tan(θ_surface) = dZ/dX (world). In image pixels,
        // d(z) per pixel at depth d ≈ (1 / fx) * d, so pick a per-pixel slope
        // that yields a 45° plane: slope_per_pixel = centerDepth / fx.
        let slope = Double(centerDepth) / Double(fx)
        let mask = fullMask(width: W, height: H)
        let depth = makeDepthBuffer(width: W, height: H) { x, _ in
            Float(Double(centerDepth) + Double(x - W / 2) * slope)
        }

        let result = AreaCalculator.measure(
            mask: mask,
            depthMap: depth,
            confidenceMap: nil,
            intrinsics: intrinsics(fx: fx, fy: fy, w: W, h: H),
            captureSize: CGSize(width: W, height: H)
        )

        XCTAssertNotNil(result)
        // Plane fit should recover ~45° tilt.
        XCTAssertEqual(result!.tiltAngleRadians, .pi / 4, accuracy: 0.1)
        // Corrected area should be ~sqrt(2) × naive area (within 15%).
        let ratio = result!.areaCm2 / result!.naiveAreaCm2
        XCTAssertEqual(ratio, sqrt(2), accuracy: 0.15)
    }
}
