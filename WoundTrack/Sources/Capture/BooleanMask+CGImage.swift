import CoreGraphics
import Foundation

extension BooleanMask {
    /// Rasterize a `CGImage` mask (e.g. `Masks.combinedMask` from the YOLO
    /// package) to a `BooleanMask` at the captured-image resolution. A pixel is
    /// considered active if its alpha (or red channel for grayscale) is above
    /// the threshold.
    ///
    /// The YOLO package renders `combinedMask` with semi-transparent color fill
    /// where masks are active and fully transparent elsewhere, so alpha > 0
    /// cleanly discriminates.
    static func from(
        cgImage: CGImage,
        targetSize: CGSize? = nil,
        alphaThreshold: UInt8 = 16
    ) -> BooleanMask? {
        // YOLO's `combinedMask` is rendered at model input size (e.g. 640×640),
        // but callers want a mask whose coordinates line up with the captured
        // image (e.g. 1920×1440). Passing `targetSize` rasterizes the source
        // into that resolution via CG's built-in scaling so downstream math
        // stays in a single coordinate space.
        let width = targetSize.map { Int($0.width) } ?? cgImage.width
        let height = targetSize.map { Int($0.height) } ?? cgImage.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitsPerComponent = 8
        var buffer = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .none  // preserve binary mask edges
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var storage = [Bool](repeating: false, count: width * height)
        for i in 0..<(width * height) {
            let alpha = buffer[i * bytesPerPixel + 3]
            storage[i] = alpha >= alphaThreshold
        }
        return BooleanMask(width: width, height: height, storage: storage)
    }

    /// Intersect this mask with a bounding box (captured-image coords). Any
    /// pixels outside the bbox are cleared. Use this to isolate a single
    /// detection when `combinedMask` contains multiple.
    func intersected(with bbox: CGRect) -> BooleanMask {
        let minX = max(0, min(width, Int(bbox.minX)))
        let maxX = max(minX, min(width, Int(bbox.maxX)))
        let minY = max(0, min(height, Int(bbox.minY)))
        let maxY = max(minY, min(height, Int(bbox.maxY)))
        // If the bbox is fully outside the mask — after both clamps — return
        // an empty mask rather than trying to iterate an inverted range.
        if minX >= maxX || minY >= maxY {
            return BooleanMask(
                width: width, height: height,
                storage: [Bool](repeating: false, count: width * height)
            )
        }
        var newStorage = [Bool](repeating: false, count: width * height)
        for y in minY..<maxY {
            let row = y * width
            for x in minX..<maxX where storage[row + x] {
                newStorage[row + x] = true
            }
        }
        return BooleanMask(width: width, height: height, storage: newStorage)
    }
}
