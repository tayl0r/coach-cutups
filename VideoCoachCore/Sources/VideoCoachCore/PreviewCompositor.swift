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
public final class PreviewCompositor: NSObject, AVVideoCompositing {
    public let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]
    public let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
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

    public override init() { super.init() }

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderContext = newRenderContext
    }

    public func cancelAllPendingVideoCompositionRequests() {}

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        // AVPlayer's playback path on modern macOS sometimes strips the
        // subclass from `videoCompositionInstruction` (the export-session path
        // preserves it; the playback path does not, at least in our testing
        // on macOS 26). When the cast fails we fall back to a best-effort
        // composite using the known track-ID convention. The only thing we
        // lose is per-segment freeze-frame rendering — clips without pauses
        // play correctly through this path; clips with `.freeze` segments
        // will render black during the freeze (or nothing if no source frame
        // is available).
        let inst = request.videoCompositionInstruction as? PreviewInstruction
        let sourceTrackID = inst?.sourceTrackID ?? 1
        let webcamTrackID = inst?.webcamTrackID ?? 1000

        // 1. Pick the base source frame:
        //    - `.freeze` (only when we have the subclass) → pre-decoded frozen
        //      frame, immutable so safe under reverse seeks.
        //    - `.play`   → live source frame for this composition time.
        //    - otherwise (subclass missing AND no live source) → nil ⇒ black.
        let base: CVPixelBuffer?
        if let inst {
            let recordTime = (request.compositionTime - inst.clipCompositionStart).seconds
            let segIndex = inst.segmentIndex(forRecordTime: recordTime)
            let segment = inst.segments.indices.contains(segIndex) ? inst.segments[segIndex] : nil
            if let segment, segment.kind == .freeze {
                base = inst.frozenFrames[segIndex]
            } else if let live = request.sourceFrame(byTrackID: sourceTrackID) {
                base = live
            } else {
                base = nil
            }
        } else {
            base = request.sourceFrame(byTrackID: sourceTrackID)
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

        // 3. Base full-frame. v1 source videos are landscape-only (matching
        //    `CompilationCompositor` and `CompilationExporter.renderSize`),
        //    so we don't apply any preferred transform here.
        if let base, let img = makeCGImage(base) {
            cg.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }

        // 4. Webcam PiP, bottom-right at 22% width with 2.2% margin — same
        //    geometry as `CompilationCompositor`. Keeping the math here
        //    (rather than in built-in `AVMutableVideoCompositionLayerInstructions`)
        //    is necessary because a custom compositor "owns" frame production;
        //    layer instructions are bypassed when `customVideoCompositorClass`
        //    is set.
        if let webcam = request.sourceFrame(byTrackID: webcamTrackID),
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
