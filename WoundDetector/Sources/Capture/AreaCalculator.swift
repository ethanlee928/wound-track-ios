import Accelerate
import CoreGraphics
import CoreVideo
import simd

/// Pure-function area measurement from a YOLO mask + ARKit depth + camera intrinsics.
///
/// Pipeline:
/// 1. Walk mask pixels in captured-image space. For each active pixel (x, y),
///    sample depth at the corresponding depth-map location.
/// 2. Back-project to camera-space 3D points `(X, Y, Z)` using pinhole geometry.
/// 3. Sum naive fronto-parallel area: Σ (d/fx) * (d/fy).
/// 4. Fit a plane `z = a*x + b*y + c` to the 3D points via least-squares normal
///    equations. Compute the surface normal, then divide naive area by cos(θ)
///    between normal and camera axis. This recovers true surface area for
///    oblique captures.
///
/// Inputs:
/// - `mask`: a boolean 2D mask at *captured-image* resolution. The caller is
///   responsible for rasterizing the YOLO segmentation mask into this buffer
///   (`Masks.combinedMask` is already at capture resolution).
/// - `depthMap`: ARKit `sceneDepth.depthMap` (`kCVPixelFormatType_DepthFloat32`,
///   typically 256×192).
/// - `confidenceMap`: optional ARKit `sceneDepth.confidenceMap`
///   (`kCVPixelFormatType_OneComponent8`). If provided, pixels at `.low`
///   confidence are skipped. `.medium` and `.high` are accepted.
/// - `intrinsics`: `ARCamera.intrinsics` (3×3 matrix, in captured-image pixel
///   space). `intrinsics[0][0] = fx`, `intrinsics[1][1] = fy`,
///   `intrinsics[2][0] = cx`, `intrinsics[2][1] = cy`.
/// - `captureSize`: captured-image resolution. Must match `mask` dimensions.
///
/// Returns `nil` when fewer than 20 valid (finite, in-confidence) pixels are
/// collected. A wound with that little usable depth data is not measurable.
enum AreaCalculator {

    struct Result {
        /// Surface area in cm², corrected for oblique angle via plane fit.
        let areaCm2: Double
        /// Naive fronto-parallel area before plane-fit correction, for diagnostics.
        let naiveAreaCm2: Double
        /// Number of mask pixels that contributed valid depth samples.
        let validPixelCount: Int
        /// Angle (radians) between the fitted plane's normal and the camera axis.
        /// 0 = wound is perpendicular to camera (ideal), π/2 = edge-on.
        let tiltAngleRadians: Double
    }

    static func measure(
        mask: BooleanMask,
        depthMap: CVPixelBuffer,
        confidenceMap: CVPixelBuffer?,
        intrinsics: simd_float3x3,
        captureSize: CGSize
    ) -> Result? {
        precondition(
            mask.width == Int(captureSize.width) && mask.height == Int(captureSize.height),
            "mask size must match captureSize"
        )

        let fx = Double(intrinsics[0][0])
        let fy = Double(intrinsics[1][1])
        let cx = Double(intrinsics[2][0])
        let cy = Double(intrinsics[2][1])

        let depthW = CVPixelBufferGetWidth(depthMap)
        let depthH = CVPixelBufferGetHeight(depthMap)
        let captureW = Double(captureSize.width)
        let captureH = Double(captureSize.height)
        let depthScaleX = Double(depthW) / captureW
        let depthScaleY = Double(depthH) / captureH

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float>.size
        let depthPtr = depthBase.assumingMemoryBound(to: Float.self)

        let confPtr: UnsafePointer<UInt8>?
        let confStride: Int
        if let conf = confidenceMap {
            CVPixelBufferLockBaseAddress(conf, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(conf, .readOnly) }
            confPtr = CVPixelBufferGetBaseAddress(conf)
                .map { UnsafePointer<UInt8>($0.assumingMemoryBound(to: UInt8.self)) }
            confStride = CVPixelBufferGetBytesPerRow(conf)
        } else {
            confPtr = nil
            confStride = 0
        }

        let invFx = 1.0 / fx
        let invFy = 1.0 / fy
        let stepX = depthScaleX
        let stepY = depthScaleY

        var naiveAreaM2: Double = 0
        var validCount = 0
        var points: [SIMD3<Double>] = []
        points.reserveCapacity(1024)

        // Walk mask pixels. For wound-size regions at 1920×1440, sampling every
        // pixel is ~few thousand valid samples, which is fine. If we ever hit a
        // perf ceiling, stride by 2.
        for y in 0..<mask.height {
            let dyIdx = Int(Double(y) * stepY)
            guard dyIdx < depthH else { continue }
            let rowBase = y * mask.width
            let depthRow = depthPtr.advanced(by: dyIdx * depthStride)
            for x in 0..<mask.width where mask.storage[rowBase + x] {
                let dxIdx = Int(Double(x) * stepX)
                if dxIdx >= depthW { continue }
                let d = Double(depthRow[dxIdx])
                if !d.isFinite || d <= 0 { continue }

                if let confPtr = confPtr {
                    let c = confPtr.advanced(by: dyIdx * confStride + dxIdx).pointee
                    // ARConfidenceLevel: 0 low, 1 medium, 2 high. Skip low.
                    if c == 0 { continue }
                }

                // Naive fronto-parallel area for this pixel, in meters²:
                //   dA_naive = (d / fx) * (d / fy)
                naiveAreaM2 += (d * invFx) * (d * invFy)
                validCount += 1

                // Back-project to camera-space 3D for the plane fit.
                let X = (Double(x) - cx) * d * invFx
                let Y = (Double(y) - cy) * d * invFy
                points.append(SIMD3<Double>(X, Y, d))
            }
        }

        if validCount < 20 { return nil }

        // Least-squares plane fit: z = a*X + b*Y + c. Solve 3×3 normal equations.
        // Σ(X²) Σ(XY) Σ(X)   a   Σ(Xz)
        // Σ(XY) Σ(Y²) Σ(Y) · b = Σ(Yz)
        // Σ(X)  Σ(Y)  N     c   Σ(z)
        var sX = 0.0, sY = 0.0, sZ = 0.0
        var sXX = 0.0, sXY = 0.0, sYY = 0.0
        var sXZ = 0.0, sYZ = 0.0
        let N = Double(points.count)
        for p in points {
            sX += p.x; sY += p.y; sZ += p.z
            sXX += p.x * p.x; sXY += p.x * p.y; sYY += p.y * p.y
            sXZ += p.x * p.z; sYZ += p.y * p.z
        }
        let M = simd_double3x3(
            SIMD3<Double>(sXX, sXY, sX),
            SIMD3<Double>(sXY, sYY, sY),
            SIMD3<Double>(sX,  sY,  N)
        )
        let rhs = SIMD3<Double>(sXZ, sYZ, sZ)
        let det = M.determinant
        let tiltAngle: Double
        let areaM2: Double
        if abs(det) < 1e-12 {
            // Degenerate fit (co-linear points). Skip oblique correction.
            tiltAngle = 0
            areaM2 = naiveAreaM2
        } else {
            let coeffs = M.inverse * rhs  // (a, b, c)
            // Plane normal in camera frame: (-a, -b, 1) normalized.
            let n = simd_normalize(SIMD3<Double>(-coeffs.x, -coeffs.y, 1))
            // Camera axis is +Z. Tilt angle = angle between n and (0,0,1).
            let cosTheta = abs(n.z)  // abs: we don't care about front/back
            tiltAngle = acos(min(max(cosTheta, -1), 1))
            areaM2 = naiveAreaM2 / max(cosTheta, 1e-3)  // clamp to avoid blowup
        }

        return Result(
            areaCm2: areaM2 * 10_000,
            naiveAreaCm2: naiveAreaM2 * 10_000,
            validPixelCount: validCount,
            tiltAngleRadians: tiltAngle
        )
    }
}

/// Compact boolean mask at a known resolution. Faster than `[[Bool]]` and
/// trivially testable. Row-major, `storage[y * width + x]`.
struct BooleanMask {
    let width: Int
    let height: Int
    let storage: [Bool]

    init(width: Int, height: Int, storage: [Bool]) {
        precondition(storage.count == width * height)
        self.width = width
        self.height = height
        self.storage = storage
    }
}
