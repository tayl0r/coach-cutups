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
    private var lastSourceFrame: CVPixelBuffer?
    private var lastClipIndex: Int = -1

    /// Shared CIContext for `CVPixelBuffer → CGImage` conversions in
    /// ``makeCGImage(_:)``. Allocated once per compositor instance (one
    /// allocation per export, not per frame). Working color space is pinned
    /// to deviceRGB so the CG draw matches our output buffer's colorspace
    /// (avoids subtle color shifts in the export).
    ///
    /// Eager init (NOT `lazy var`) — `lazy var` is not thread-safe, and
    /// AVFoundation may call `startRequest(_:)` from a private dispatch queue
    /// without a documented serialization guarantee. Eager init dodges the
    /// race entirely.
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
        // Subclass-passthrough is documented behavior; failing here would
        // mean a future macOS regressed it. Crash visibly rather than
        // silently render black for the entire export.
        guard let inst = request.videoCompositionInstruction as? CompilationInstruction else {
            fatalError("CompilationCompositor received a non-CompilationInstruction")
        }

        // Reset cached source frame at every clip boundary so a leading
        // .freeze in clip N never displays clip N-1's last source frame.
        if inst.clipIndex != lastClipIndex {
            lastClipIndex = inst.clipIndex
            lastSourceFrame = nil
        }

        let recordTime = (request.compositionTime - inst.clipCompositionStart).seconds
        let isFreeze = currentSegmentIsFreeze(inst: inst, recordTime: recordTime)

        // 1. Base buffer: live source for .play, cached for .freeze, cached
        //    fallback if the live pull returned nil.
        var base: CVPixelBuffer?
        if isFreeze {
            base = lastSourceFrame
        } else if let sf = request.sourceFrame(byTrackID: inst.sourceTrackID) {
            lastSourceFrame = sf
            base = sf
        } else {
            base = lastSourceFrame
        }

        // 2. Output buffer + CG context (flip Y to top-left origin).
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
        // image — strokes stored top-left then pass through directly with
        // flipY: false. (flipY: true would double-flip — see the misuse
        // warning in design § "Drawing capture".)
        cg.translateBy(x: 0, y: CGFloat(h))
        cg.scaleBy(x: 1, y: -1)

        let size = CGSize(width: w, height: h)

        // 3. Base full-frame (only if we have one — otherwise the black fill
        //    remains).
        if let base, let img = makeCGImage(base) {
            cg.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }

        // 4. Webcam PiP, bottom-right at 22% width with 2.2% margin.
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

        // 5. Strokes — synthesize a throwaway Clip carrying the events list
        //    so we can call the shared replay helper unchanged. The Clip's
        //    other fields (sourceIndex, recordingFilename, etc.) are unused
        //    by visibleStrokes(in:atRecordTime:).
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

        // 6. Text bar via CoreText (handles emoji / RTL / CJK correctly,
        //    unlike CGContext's deprecated text APIs).
        drawTextBar(inst.textBarLine, into: cg, size: size)

        request.finish(withComposedVideoFrame: out)
    }

    // MARK: - Helpers

    /// Walks `inst.segments` summing `outDuration`; returns true when the
    /// segment containing `recordTime` is `.freeze`. Returns false if
    /// `recordTime` falls outside the walked range (defensive — the
    /// instruction should cover the clip's full output range).
    private func currentSegmentIsFreeze(inst: CompilationInstruction, recordTime: Double) -> Bool {
        var cursor = 0.0
        for seg in inst.segments {
            let next = cursor + seg.outDuration
            if recordTime < next {
                return seg.kind == .freeze
            }
            cursor = next
        }
        return false
    }

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

        let fontSize = size.height * 0.05
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

    private func makeCGImage(_ buffer: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: buffer)
        return ciContext.createCGImage(ci, from: ci.extent)
    }
}
