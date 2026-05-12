import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreText
import CoreVideo
import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// The export pipeline's `AVVideoCompositing`. Owns per-output-frame rendering
/// for the entire compilation: source frames (live or cached during freeze),
/// the webcam PiP overlay, the strokes overlay (replayed from event log), and
/// the bottom text bar — all in one pass into the render context's pixel
/// buffer.
///
/// Per-clip context (segments, strokes, events, track IDs, text bar string)
/// rides on a `CompilationInstruction` subclass of
/// `AVMutableVideoCompositionInstruction`. AVFoundation passes the subclass
/// through unchanged. See ``CompilationInstruction`` for the contract.
public final class CompilationCompositor: NSObject, AVVideoCompositing {
    public let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]
    public let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]

    private var renderContext: AVVideoCompositionRenderContext?

    /// Hoisted to type scope so `CIContext.render(_:to:bounds:colorSpace:)`
    /// doesn't allocate a fresh `CGColorSpace` per frame on the hot path.
    /// Mirrors `PreviewCompositor.outputColorSpace`.
    private static let outputColorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()

    /// Shared CIContext used to render the composed base + PiP CIImage
    /// directly into the output CVPixelBuffer (stage 1 of startRequest).
    /// `CIContext.render(_:to:bounds:colorSpace:)` writes into the buffer's
    /// IOSurface without an intermediate CGImage, keeping the frame
    /// GPU-resident from source decode through encoder hand-off. Working
    /// and output color spaces are pinned to deviceRGB so the subsequent
    /// CGContext overlay pass (stage 2) draws on bytes laid down in the
    /// same color space.
    ///
    /// `render(_:to:bounds:colorSpace:)` is synchronous — it flushes the
    /// GPU pipeline before returning, so stage 2's `CVPixelBufferLockBaseAddress`
    /// safely reads the bytes stage 1 wrote with no ordering hazard.
    ///
    /// Eager init (NOT `lazy var`) — `lazy var` is not thread-safe, and
    /// AVFoundation may call `startRequest(_:)` from a private dispatch
    /// queue without a documented serialization guarantee. Eager init dodges
    /// the race entirely.
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
        // macOS 26 strips the AVMutableVideoCompositionInstruction subclass
        // on at least the playback path (PreviewCompositor saw this) and
        // appears to do the same on the export path under some conditions
        // ("AVAssetExportSession failed: Operation Stopped" was traced to
        // this fatalError firing inside the export pipeline). Recover
        // gracefully: when the cast misses, fall back to a "no per-clip
        // context" path that still emits a frame so the export completes.
        let inst = request.videoCompositionInstruction as? CompilationInstruction
        let recordTime = inst.map { (request.compositionTime - $0.clipCompositionStart).seconds } ?? 0

        // Resolve source + webcam track IDs (same logic as before — the
        // instruction subclass exposes them directly, with a fallback to
        // `requiredSourceTrackIDs` declaration order when stripped).
        let sourceTrackID: CMPersistentTrackID
        if let inst {
            sourceTrackID = inst.sourceTrackID
        } else if let firstRequiredID = request.videoCompositionInstruction
                    .requiredSourceTrackIDs?.first as? CMPersistentTrackID {
            sourceTrackID = firstRequiredID
        } else {
            sourceTrackID = kCMPersistentTrackID_Invalid
        }
        let webcamTrackID: CMPersistentTrackID
        if let inst {
            webcamTrackID = inst.webcamTrackID
        } else if let required = request.videoCompositionInstruction.requiredSourceTrackIDs,
                  required.count >= 2,
                  let second = required[1] as? CMPersistentTrackID {
            webcamTrackID = second
        } else {
            webcamTrackID = kCMPersistentTrackID_Invalid
        }

        let base: CVPixelBuffer? = request.sourceFrame(byTrackID: sourceTrackID)
        let webcam: CVPixelBuffer? = request.sourceFrame(byTrackID: webcamTrackID)

        guard let renderContext, let out = renderContext.newPixelBuffer() else {
            request.finishCancelledRequest()
            return
        }
        let outW = CGFloat(CVPixelBufferGetWidth(out))
        let outH = CGFloat(CVPixelBufferGetHeight(out))
        let outRect = CGRect(x: 0, y: 0, width: outW, height: outH)

        // ── Stage 1: GPU-direct render of base + PiP ───────────────────
        //
        // This block is a structural mirror of PreviewCompositor.startRequest
        // lines 117–177. If you change anything here that's not strictly a
        // stroke/text overlay concern, mirror it in PreviewCompositor too —
        // they're paired by visual contract (preview must match export).

        var composite: CIImage = CIImage(color: .black).cropped(to: outRect)

        if let base {
            let baseCI = CIImage(cvPixelBuffer: base)
            // baseCI.extent.origin is (0,0) for any CIImage made from an
            // AVFoundation-allocated CVPixelBuffer (which is what
            // `request.sourceFrame(byTrackID:)` always returns). The fit
            // math below assumes origin (0,0); we don't translate by
            // -origin because the assumption holds for all real inputs.
            let baseScale = CGAffineTransform(
                scaleX: outW / max(baseCI.extent.width, 1),
                y: outH / max(baseCI.extent.height, 1)
            )
            let stretched = baseCI.transformed(by: baseScale)
            let zoom = inst?.events.zoomAt(recordTime: recordTime) ?? .identity
            // Identity-zoom early-out — skip `.cropped(to: outRect)` op so
            // behavior is bit-identical to the prior pipeline at zoom=1.
            // `deltaTransform` early-outs at identity already, but `.cropped`
            // is a non-trivial CIImage op we don't want on the hot path.
            // At any non-identity zoom the cropped path is required to keep
            // the zoomed image bounded by outRect.
            let zoomed = (zoom == .identity)
                ? stretched
                : stretched.transformed(by: zoom.deltaTransform(viewportSize: outRect.size))
                           .cropped(to: outRect)
            composite = zoomed.composited(over: composite)
        }

        if let webcam {
            let camCI = CIImage(cvPixelBuffer: webcam)
            let camW = camCI.extent.width
            let camH = camCI.extent.height
            let pipW = outW * 0.22
            let pipH = pipW * camH / max(camW, 1)
            let margin = outH * 0.022
            // CIImage's coordinate origin is bottom-left, so "bottom-right
            // with margin" = (outW - margin - pipW, margin). This matches
            // PreviewCompositor.startRequest lines 159–173 exactly.
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

        ciContext.render(
            composite,
            to: out,
            bounds: outRect,
            colorSpace: Self.outputColorSpace
        )

        // ── Stage 2: CGContext overlays (strokes + text bar) ───────────
        //
        // The output buffer now contains the composed base + PiP. Open a
        // CGContext over its IOSurface-backed memory to draw the smaller
        // overlays (strokes are typically a few thousand pixels of work
        // per frame; text bar is a single-line CoreText draw). The Y-flip
        // is preserved so stroke coordinates (top-left, normalized) and
        // the text-bar Y math continue to work unchanged.
        //
        // `CIContext.render` is synchronous (flushes GPU before returning),
        // so there's no ordering hazard between the IOSurface write above
        // and the lockBaseAddress + CG draws below.

        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }

        let w = Int(outW)
        let h = Int(outH)
        guard let cg = CGContext(
            data: CVPixelBufferGetBaseAddress(out),
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(out),
            space: Self.outputColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            request.finishCancelledRequest()
            return
        }

        // After this transform, user-space (0, 0) is top-left — matches how
        // strokes are recorded and how drawTextBar's bar-rect math is
        // written.
        cg.translateBy(x: 0, y: outH)
        cg.scaleBy(x: 1, y: -1)

        let size = CGSize(width: outW, height: outH)

        if let inst {
            let synthClip = Clip(
                name: "_compositorReplay",
                sourceIndex: 0,
                startSourceSeconds: 0,
                recordingDuration: max(recordTime, 0) + 1,
                recordingFilename: "",
                events: inst.events,
                sortIndex: 0
            )
            for vs in visibleStrokes(in: synthClip, atRecordTime: recordTime) {
                drawStroke(vs, into: cg, size: size)
            }
            drawTextBar(inst.textBarLine, into: cg, size: size)
        }

        request.finish(withComposedVideoFrame: out)
    }

    // MARK: - Helpers

    private func drawStroke(_ vs: VisibleStroke, into cg: CGContext, size: CGSize) {
        guard vs.drawnPointCount > 0 else { return }
        let count = min(vs.drawnPointCount, vs.stroke.points.count)

        let c = vs.stroke.color
        let color = CGColor(
            red: CGFloat(c.r),
            green: CGFloat(c.g),
            blue: CGFloat(c.b),
            alpha: CGFloat(c.a)
        )
        let lineWidth = CGFloat(vs.stroke.lineWidth) * size.height

        // flipY: false — the cg.translateBy + scaleBy at the top of
        // startRequest already established a top-left user-space.
        let firstP = vs.stroke.points[0]
        let firstPt = Denormalize.point(firstP.x, firstP.y, into: size, flipY: false)

        if count == 1 {
            // Single-point stroke (instant click) → fill a circle at the
            // point with the stroke's line width as diameter. Stroking a
            // zero-length path doesn't render with .round line cap on
            // CGContext (it does on CAShapeLayer — different code path),
            // so this dot is what the live overlay's CA-rendered click
            // would visually correspond to in the export.
            cg.setFillColor(color)
            let r = lineWidth / 2
            cg.fillEllipse(in: CGRect(
                x: firstPt.x - r,
                y: firstPt.y - r,
                width: lineWidth,
                height: lineWidth
            ))
            return
        }

        let path = CGMutablePath()
        path.move(to: firstPt)
        for i in 1..<count {
            let p = vs.stroke.points[i]
            let pt = Denormalize.point(p.x, p.y, into: size, flipY: false)
            path.addLine(to: pt)
        }
        cg.setStrokeColor(color)
        cg.setLineWidth(lineWidth)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.addPath(path)
        cg.strokePath()
    }

    private func drawTextBar(_ line: String, into cg: CGContext, size: CGSize) {
        let barH = size.height * 0.08
        // Bottom strip — but we're under a flipped CGContext, so "bottom" in
        // image coordinates is at user-space y = height - barH.
        let barRect = CGRect(
            x: 0,
            y: size.height - barH,
            width: size.width,
            height: barH
        )
        cg.setFillColor(CGColor(gray: 0, alpha: 0.6))
        cg.fill(barRect)

        guard !line.isEmpty else { return }

        // Font size has to be small enough for one line of text + ascender +
        // descender to fit inside the inset text rect. CoreText line height
        // ≈ 1.2 × point size; if that exceeds the available height the
        // framesetter silently draws nothing. Targeting ~50% of barH leaves
        // comfortable vertical headroom.
        let fontSize = barH * 0.5
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1),
        ]
        let attributed = CFAttributedStringCreate(
            nil,
            line as CFString,
            attrs as CFDictionary
        )
        guard let attributed else { return }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        // Inset the text rect slightly so glyphs don't kiss the bar edges.
        let inset = barH * 0.15
        let textRect = barRect.insetBy(dx: inset, dy: inset)

        // CoreText draws into a bottom-left coordinate system in user-space.
        // Our outer cg is currently top-left (after the translateBy/scaleBy
        // flip). Restore a bottom-left frame for the text bar draw, render,
        // then restore the outer state.
        cg.saveGState()
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        // Now back in bottom-left user-space matching the pixel buffer's
        // native orientation. The bar is at the bottom, which in this space
        // is y = 0..barH.
        let drawRect = CGRect(x: inset, y: inset, width: textRect.width, height: textRect.height)
        let path = CGPath(rect: drawRect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil
        )
        CTFrameDraw(frame, cg)
        cg.restoreGState()
    }


}
