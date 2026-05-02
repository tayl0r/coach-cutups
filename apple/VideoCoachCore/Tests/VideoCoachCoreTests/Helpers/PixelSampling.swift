import CoreGraphics
import Foundation

/// Read pixels from a `CGImage` into a CPU buffer and compute statistics over
/// a normalized region. Used by the Phase 9.0 spike to verify exported frame
/// content (e.g. solid red) without a GPU dependency.
enum PixelSampling {
    struct AvgRGB {
        var r: Double
        var g: Double
        var b: Double
    }

    static func averageRGB(in image: CGImage, normalizedRect: CGRect) -> AvgRGB {
        let cs = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = image.width * 4
        var pixels = [UInt8](repeating: 0, count: image.height * bytesPerRow)
        let ctx = CGContext(
            data: &pixels,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        let xStart = Int(normalizedRect.minX * CGFloat(image.width))
        let yStart = Int(normalizedRect.minY * CGFloat(image.height))
        let xEnd = Int(normalizedRect.maxX * CGFloat(image.width))
        let yEnd = Int(normalizedRect.maxY * CGFloat(image.height))
        var sumR = 0.0
        var sumG = 0.0
        var sumB = 0.0
        var n = 0.0
        for y in yStart..<yEnd {
            for x in xStart..<xEnd {
                let i = y * bytesPerRow + x * 4
                sumR += Double(pixels[i]) / 255.0
                sumG += Double(pixels[i + 1]) / 255.0
                sumB += Double(pixels[i + 2]) / 255.0
                n += 1
            }
        }
        return .init(r: sumR / n, g: sumG / n, b: sumB / n)
    }
}
