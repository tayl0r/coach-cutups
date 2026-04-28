import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

/// Mode C preview's `AVVideoCompositing`. Owns the per-frame video composite
/// for live preview playback: source frames (live or pre-decoded for freeze
/// segments) plus the webcam PiP. Strokes and the bottom text bar are NOT
/// drawn here — those sit in the AppKit view hierarchy as overlays so the
/// compositor only does the work that has to be inside the `AVPlayerItem`'s
/// pipeline (frame selection + PiP geometry).
///
/// Per-clip context (segments, pre-decoded freeze frames, track IDs) rides on
/// a `PreviewInstruction` subclass of `AVMutableVideoCompositionInstruction`.
/// The cast in `startRequest` `fatalError`s on miss because subclass
/// passthrough is documented behavior — a failure means a future macOS
/// regressed it, and silently rendering black would mask the bug.
///
/// **Backward-scrub correctness**: AVPlayer can call `startRequest` out of
/// temporal order during seeks. A naive "remember the last `.play` source
/// frame and re-emit it on `.freeze`" cache would display a *future* frame
/// while scrubbing backward. This compositor instead reads the frozen frame
/// from `inst.frozenFrames` (pre-decoded at composition build time, immutable
/// thereafter), so the freeze frame is correct regardless of seek direction.
final class PreviewCompositor: NSObject, AVVideoCompositing {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]

    private var renderContext: AVVideoCompositionRenderContext?

    /// Shared CIContext for `CVPixelBuffer → CGImage` conversions. Eager
    /// init (NOT `lazy var`) — `lazy var` is not thread-safe, and AVFoundation
    /// may call `startRequest(_:)` from a private dispatch queue without a
    /// documented serialization guarantee.
    private let ciContext: CIContext = CIContext(options: [
        .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
        .outputColorSpace: CGColorSpaceCreateDeviceRGB(),
    ])

    override init() { super.init() }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderContext = newRenderContext
    }

    func cancelAllPendingVideoCompositionRequests() {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let inst = request.videoCompositionInstruction as? PreviewInstruction else {
            // Subclass-passthrough is documented behavior; a miss here would
            // mean a future macOS regressed it. Crash visibly rather than
            // silently render black for the entire preview.
            fatalError("PreviewCompositor received a non-PreviewInstruction")
        }

        let recordTime = (request.compositionTime - inst.clipCompositionStart).seconds
        let segIndex = inst.segmentIndex(forRecordTime: recordTime)
        let segment = inst.segments.indices.contains(segIndex) ? inst.segments[segIndex] : nil

        // 1. Pick the base source frame:
        //    - .freeze → pre-decoded frozen frame (immutable; safe under seeks)
        //    - .play   → live source frame for this composition time
        //    - otherwise (gap before the first sample) → nil ⇒ render black
        let base: CVPixelBuffer?
        if let segment, segment.kind == .freeze {
            base = inst.frozenFrames[segIndex]
        } else if let live = request.sourceFrame(byTrackID: inst.sourceTrackID) {
            base = live
        } else {
            base = nil
        }

        // 2. Allocate the output buffer.
        guard let out = renderContext?.newPixelBuffer() else {
            request.finishCancelledRequest()
            return
        }
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }

        let w = CVPixelBufferGetWidth(out)
        let h = CVPixelBufferGetHeight(out)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let cg = CGContext(
            data: CVPixelBufferGetBaseAddress(out),
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(out),
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            request.finishCancelledRequest()
            return
        }

        // newPixelBuffer() doesn't guarantee zeroed memory — fill black first
        // so a missing base (e.g. clip starts paused with no cached frame)
        // renders cleanly instead of showing whatever was in the pool slot.
        cg.setFillColor(CGColor(gray: 0, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // After this transform, user-space (0, 0) is the top-left of the
        // image — same convention CompilationCompositor uses, so a CGImage
        // drawn into it appears right-side-up.
        cg.translateBy(x: 0, y: CGFloat(h))
        cg.scaleBy(x: 1, y: -1)

        // 3. Base full-frame.
        if let base, let img = makeCGImage(base) {
            cg.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }

        // 4. Webcam PiP, bottom-right at 22% width with 2.2% margin — same
        //    geometry as `CompilationCompositor`. Keeping the math here
        //    (rather than in built-in `AVMutableVideoCompositionLayerInstructions`)
        //    is necessary because a custom compositor "owns" frame production;
        //    layer instructions are bypassed when `customVideoCompositorClass`
        //    is set.
        if let webcam = request.sourceFrame(byTrackID: inst.webcamTrackID),
           let wImg = makeCGImage(webcam) {
            let pipW = CGFloat(w) * 0.22
            let webcamH = CVPixelBufferGetHeight(webcam)
            let webcamW = CVPixelBufferGetWidth(webcam)
            let pipH = pipW * CGFloat(webcamH) / CGFloat(max(webcamW, 1))
            let margin = CGFloat(h) * 0.022
            let rect = CGRect(
                x: CGFloat(w) - pipW - margin,
                y: CGFloat(h) - pipH - margin,
                width: pipW,
                height: pipH
            )
            cg.draw(wImg, in: rect)
        }

        request.finish(withComposedVideoFrame: out)
    }

    // MARK: - Helpers

    private func makeCGImage(_ buffer: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: buffer)
        return ciContext.createCGImage(ci, from: ci.extent)
    }
}
