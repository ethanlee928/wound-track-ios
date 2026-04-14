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
    static func from(cgImage: CGImage, alphaThreshold: UInt8 = 16) -> BooleanMask? {
        let width = cgImage.width
        let height = cgImage.height
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
        let minX = max(0, Int(bbox.minX))
        let maxX = min(width, Int(bbox.maxX))
        let minY = max(0, Int(bbox.minY))
        let maxY = min(height, Int(bbox.maxY))
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
