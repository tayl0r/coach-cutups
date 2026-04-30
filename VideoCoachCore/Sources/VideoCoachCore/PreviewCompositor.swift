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
/// `startRequest` casts via `as?` because AVPlayer's playback path on modern
/// macOS sometimes strips the subclass; on miss we fall back to default
/// track IDs (1 = source, 1000 = webcam) and best-effort composite without
/// per-segment freeze rendering. The fallback is documented in detail in
/// the comment above `startRequest`.
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

    /// Hoisted to type scope so `CIContext.render(_:to:bounds:colorSpace:)`
    /// doesn't allocate a fresh `CGColorSpace` per frame on the hot path.
    private static let outputColorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()

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

        guard let renderContext, let out = renderContext.newPixelBuffer() else {
            request.finishCancelledRequest()
            return
        }
        let outW = CGFloat(CVPixelBufferGetWidth(out))
        let outH = CGFloat(CVPixelBufferGetHeight(out))
        let outRect = CGRect(x: 0, y: 0, width: outW, height: outH)

        // 2. Black background only when there's no base. The old CPU path
        //    unconditionally black-filled the buffer even when `base` would
        //    cover the whole frame; that fill was wasted memory traffic and
        //    we drop it. CIImage(color:) is essentially free — it's just a
        //    constant generator the GPU evaluates per-sample on demand.
        var composite: CIImage = CIImage(color: .black).cropped(to: outRect)

        if let base {
            let baseCI = CIImage(cvPixelBuffer: base)
            // Non-uniform scale to match the old `cg.draw(img, in: outRect)`
            // stretch behavior. Don't switch this to `max(sx, sy)` (uniform
            // crop-fill) — that would be a visual policy change.
            let baseScale = CGAffineTransform(
                scaleX: outW / max(baseCI.extent.width, 1),
                y: outH / max(baseCI.extent.height, 1)
            )
            composite = baseCI.transformed(by: baseScale).composited(over: composite)
        }

        // 3. Webcam PiP, bottom-right at 22% width with 2.2% margin — same
        //    geometry as `CompilationCompositor`. CIImage's coordinate origin
        //    is bottom-left, so "bottom-right with margin" = (outW - margin -
        //    pipW, margin). Keeping the math here (rather than in built-in
        //    AVMutableVideoCompositionLayerInstructions) is necessary because
        //    a custom compositor "owns" frame production; layer instructions
        //    are bypassed when `customVideoCompositorClass` is set.
        if let webcam = request.sourceFrame(byTrackID: webcamTrackID) {
            let camCI = CIImage(cvPixelBuffer: webcam)
            let camW = camCI.extent.width
            let camH = camCI.extent.height
            let pipW = outW * 0.22
            let pipH = pipW * camH / max(camW, 1)
            let margin = outH * 0.022
            let scale = CGAffineTransform(
                scaleX: pipW / max(camW, 1),
                y: pipH / max(camH, 1)
            )
            let translate = CGAffineTransform(
                translationX: outW - margin - pipW,
                y: margin
            )
            composite = camCI.transformed(by: scale)
                .transformed(by: translate)
                .composited(over: composite)
        }

        // 4. Single GPU render straight into the output buffer. No CGContext,
        //    no pixel-buffer lock, no per-frame CGImage allocation — saves
        //    ~70 MB/frame of memory traffic at 4K relative to the old path.
        ciContext.render(
            composite,
            to: out,
            bounds: outRect,
            colorSpace: Self.outputColorSpace
        )
        request.finish(withComposedVideoFrame: out)
    }
}
