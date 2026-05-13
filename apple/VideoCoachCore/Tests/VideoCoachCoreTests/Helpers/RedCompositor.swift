import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

/// Stub `AVVideoCompositing` that paints every output frame solid red. Used by
/// the Phase 9.0 spike to prove the export session actually invokes a custom
/// compositor (and isn't taking a fast pass-through path under HEVC presets).
final class RedCompositor: NSObject, AVVideoCompositing {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]
    private var ctx: AVVideoCompositionRenderContext?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        ctx = newRenderContext
    }

    func cancelAllPendingVideoCompositionRequests() {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let pb = ctx?.newPixelBuffer() else {
            request.finishCancelledRequest()
            return
        }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let cs = CGColorSpaceCreateDeviceRGB()
        if let bitmap = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: CVPixelBufferGetWidth(pb),
            height: CVPixelBufferGetHeight(pb),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            bitmap.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            bitmap.fill(CGRect(
                x: 0, y: 0,
                width: CVPixelBufferGetWidth(pb),
                height: CVPixelBufferGetHeight(pb)
            ))
        }
        request.finish(withComposedVideoFrame: pb)
    }
}
