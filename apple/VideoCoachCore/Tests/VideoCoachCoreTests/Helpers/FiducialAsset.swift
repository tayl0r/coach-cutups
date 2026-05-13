import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
@testable import VideoCoachCore

/// Synthesizes a test source video with two independent verification
/// channels that survive H.264 compression cleanly:
///
///  1. **Spatial fiducials** — 5 large saturated-color squares at fixed
///     source coordinates. After compression each square's center pixel
///     still lands within ±0.1 of its true RGB, so a sampled probe can be
///     classified by max-channel pattern with a wide tolerance margin.
///     Use to verify zoom / pan / crop math by predicting where a known
///     source point ends up in the viewport and sampling there.
///
///  2. **Frame-number barcode** — a row of 12 black/white squares along
///     the bottom of the frame encoding the source-frame index in binary
///     (MSB-first). Each square is ~80px wide at 1280-wide source, vastly
///     larger than the chroma subsampling block, so each bit decodes as a
///     hard 0 or 1. Use to verify pause / resume / FF / RW timing —
///     sampling the barcode at any compositionTime tells you exactly which
///     source frame the compositor ended up emitting.
///
/// Replaces `PositionEncodedAsset`'s every-pixel-encodes-time-and-position
/// scheme, which was unreliable because H.264 BT.709 limited-range YCbCr
/// adds a ~5% bias to every channel and chroma subsampling further smears
/// the color gradient. Fiducials trade pixel-density for robustness.
enum FiducialAsset {
    enum Error: Swift.Error {
        case writerStartFailed
        case writerFinishFailed(Swift.Error?)
        case appendFailed(String)
    }

    // MARK: - Fiducials

    enum Fiducial: Int, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight, center

        /// Center of the fiducial in normalized source coordinates
        /// (each component 0...1). Chosen so:
        ///   - none overlap the bottom-20% barcode strip
        ///   - all are visible at the default identity zoom
        ///   - center stays inside the visible window for any clamped pan
        ///     at scale ≤ 4 (panX, panY ∈ [-0.375, 0.375])
        var sourcePoint: CGPoint {
            switch self {
            case .topLeft:     return CGPoint(x: 0.15, y: 0.15)
            case .topRight:    return CGPoint(x: 0.85, y: 0.15)
            case .bottomLeft:  return CGPoint(x: 0.15, y: 0.60)
            case .bottomRight: return CGPoint(x: 0.85, y: 0.60)
            case .center:      return CGPoint(x: 0.50, y: 0.40)
            }
        }

        /// Solid color drawn at the fiducial's location. Each fiducial uses
        /// a different primary-or-secondary color so a single sampled probe
        /// can be unambiguously classified by which channels are high vs
        /// low — see `classify(rgb:)`.
        var rgb: (r: UInt8, g: UInt8, b: UInt8) {
            switch self {
            case .topLeft:     return (0xFF, 0x00, 0x00)  // RED
            case .topRight:    return (0x00, 0xFF, 0x00)  // GREEN
            case .bottomLeft:  return (0xFF, 0xFF, 0x00)  // YELLOW
            case .bottomRight: return (0xFF, 0x00, 0xFF)  // MAGENTA
            case .center:      return (0x00, 0x00, 0xFF)  // BLUE
            }
        }
    }

    /// Side length of each fiducial square in normalized source units.
    /// 12% of frame width is large enough that, after a 4× zoom, the
    /// fiducial still occupies ~48% of the viewport — plenty of room for
    /// a 4% sample probe to fall safely inside.
    static let fiducialSize: Double = 0.12

    /// Background color filling the non-fiducial, non-barcode region of
    /// each frame. Mid-gray gives every primary color the maximum possible
    /// channel-distance from the background, which keeps the classify()
    /// thresholds wide and robust against H.264 noise.
    static let backgroundRGB: (r: UInt8, g: UInt8, b: UInt8) = (0x80, 0x80, 0x80)

    // MARK: - Frame-number barcode

    /// Number of bits in the bottom-row barcode. 12 bits = 4096 frames =
    /// 136 seconds at 30fps, enough for any realistic test clip without
    /// bumping the per-bit width below the chroma-subsampling-safe size.
    static let barcodeBits: Int = 12

    /// Barcode strip occupies the bottom-LEFT quadrant of each frame. Bit
    /// i (MSB first, i=0 is the most significant) is a square centered at:
    ///   x = barcodeXOriginNorm + (i + 0.5) * (barcodeWidthNorm / barcodeBits)
    ///   y = barcodeCenterYNorm
    /// drawn black for bit=0 or white for bit=1. The X range stops at 0.70
    /// to stay clear of the bottom-right webcam PiP overlay used by
    /// `ClipPreviewBuilder` (PiP occupies viewport-x ∈ [~0.78, ~0.99]).
    /// Bits in the PiP region would be replaced by webcam pixels and
    /// decode garbage, so we keep the whole strip out of that zone.
    static let barcodeYRangeNorm: ClosedRange<Double> = 0.80...0.95
    static let barcodeXOriginNorm: Double = 0.04
    static let barcodeWidthNorm: Double = 0.66    // bits live in x ∈ [0.04, 0.70]
    static let barcodeCenterYNorm: Double = 0.875

    /// X-center in normalized source coordinates of the i-th bit's square.
    /// Used both at write-time (place the rect) and at decode-time (sample
    /// the rect's center).
    static func barcodeBitCenterX(_ bitIndex: Int) -> Double {
        let bitWidth = barcodeWidthNorm / Double(barcodeBits)
        return barcodeXOriginNorm + (Double(bitIndex) + 0.5) * bitWidth
    }

    // MARK: - Decode helpers

    /// Sample the barcode at the four corners of a tiny probe centered on
    /// each bit's square, and decode the resulting bits into the frame
    /// index. Returns nil if any bit was ambiguous (gray-ish — typically
    /// happens if the barcode is occluded by a zoom-out-of-bounds black
    /// border or if you fed it a frame from a non-FiducialAsset source).
    static func decodeFrameNumber(in cgImage: CGImage) -> Int? {
        var value = 0
        let probe: Double = 0.005   // 0.5% wide × 0.5% tall
        for i in 0..<barcodeBits {
            let cx = barcodeBitCenterX(i)
            let cy = barcodeCenterYNorm
            let rect = CGRect(
                x: cx - probe / 2, y: cy - probe / 2,
                width: probe, height: probe
            )
            let avg = PixelSampling.averageRGB(in: cgImage, normalizedRect: rect)
            let lum = (avg.r + avg.g + avg.b) / 3.0
            // 0.30 / 0.70 thresholds with a wide gray dead-band: we'd rather
            // surface "ambiguous" than silently decode a wrong frame.
            if lum > 0.70 {
                value = (value << 1) | 1   // bit = 1 (white)
            } else if lum < 0.30 {
                value = value << 1           // bit = 0 (black)
            } else {
                return nil
            }
        }
        return value
    }

    /// Classify a sampled RGB triple as which Fiducial color it matches,
    /// or nil if the sample is gray-ish background or doesn't match any
    /// fiducial pattern. Channel thresholds are deliberately wide (0.35 /
    /// 0.65) to absorb H.264 + BT.709 channel bias.
    static func classify(rgb: PixelSampling.AvgRGB) -> Fiducial? {
        let hi: (Double) -> Bool = { $0 > 0.65 }
        let lo: (Double) -> Bool = { $0 < 0.35 }
        switch (hi(rgb.r), lo(rgb.r), hi(rgb.g), lo(rgb.g), hi(rgb.b), lo(rgb.b)) {
        case (true, false, false, true, false, true):   return .topLeft     // RED
        case (false, true, true, false, false, true):   return .topRight    // GREEN
        case (true, false, true, false, false, true):   return .bottomLeft  // YELLOW
        case (true, false, false, true, true, false):   return .bottomRight // MAGENTA
        case (false, true, false, true, true, false):   return .center      // BLUE
        default: return nil
        }
    }

    /// Predicted normalized viewport position of `fiducial` after the
    /// given Zoom is applied to the source. Inverse of
    /// `Zoom.sourcePoint(atViewPosition:)` — viewport-x =
    /// 0.5 + (sourceX - (0.5 + panX)) * scale.
    static func expectedViewportPoint(of fiducial: Fiducial, after zoom: Zoom) -> CGPoint {
        let s = fiducial.sourcePoint
        return CGPoint(
            x: 0.5 + (Double(s.x) - (0.5 + zoom.panX)) * zoom.scale,
            y: 0.5 + (Double(s.y) - (0.5 + zoom.panY)) * zoom.scale
        )
    }

    // MARK: - Asset write

    static func write(
        to url: URL,
        duration: Double,
        width: Int = 1280,
        height: Int = 720,
        fps: Int = 30
    ) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attrs
        )
        guard writer.canAdd(input) else { throw Error.appendFailed("cannot add video input") }
        writer.add(input)
        guard writer.startWriting() else { throw Error.writerStartFailed }
        writer.startSession(atSourceTime: .zero)

        let timescale: CMTimeScale = 600
        let frameCount = max(1, Int((duration * Double(fps)).rounded()))
        let frameDuration = CMTime(
            value: CMTimeValue(timescale / CMTimeScale(fps)),
            timescale: timescale
        )

        // Static layout (background + fiducials) is identical across every
        // frame — render it once into a template and reuse. Only the
        // barcode squares change per frame, and there are at most 12 of
        // them per frame to redraw.
        let template = renderStaticTemplate(width: width, height: height)
        let bytesPerRow = width * 4

        let semaphore = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "FiducialAsset.video")
        var nextFrame = 0
        var driveError: Swift.Error?
        input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData {
                if nextFrame >= frameCount {
                    input.markAsFinished()
                    semaphore.signal()
                    return
                }
                let pts = CMTimeMultiply(frameDuration, multiplier: Int32(nextFrame))
                do {
                    let buffer = try Self.makeFrameBuffer(
                        pool: adaptor.pixelBufferPool,
                        width: width,
                        height: height,
                        bytesPerRow: bytesPerRow,
                        template: template,
                        frameNumber: nextFrame
                    )
                    if !adaptor.append(buffer, withPresentationTime: pts) {
                        throw Error.appendFailed("append failed at \(pts.seconds)")
                    }
                } catch {
                    driveError = error
                    input.markAsFinished()
                    semaphore.signal()
                    return
                }
                nextFrame += 1
            }
        }
        semaphore.wait()
        if let driveError { throw driveError }

        let finishSem = DispatchSemaphore(value: 0)
        writer.finishWriting { finishSem.signal() }
        finishSem.wait()
        if writer.status != .completed { throw Error.writerFinishFailed(writer.error) }
    }

    // MARK: - Frame rendering

    /// Render the time-invariant portion of every frame: gray background,
    /// 5 fiducial squares. Returns the row-major BGRA pixel buffer.
    private static func renderStaticTemplate(width: Int, height: Int) -> [UInt8] {
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: height * bytesPerRow)
        // Fill background.
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bytesPerRow + x * 4
                bytes[i]     = backgroundRGB.b
                bytes[i + 1] = backgroundRGB.g
                bytes[i + 2] = backgroundRGB.r
                bytes[i + 3] = 0xFF
            }
        }
        // Stamp each fiducial.
        for f in Fiducial.allCases {
            let s = f.sourcePoint
            let halfNorm = fiducialSize / 2
            let x0 = max(0, Int((Double(s.x) - halfNorm) * Double(width)))
            let x1 = min(width, Int((Double(s.x) + halfNorm) * Double(width)))
            let y0 = max(0, Int((Double(s.y) - halfNorm) * Double(height)))
            let y1 = min(height, Int((Double(s.y) + halfNorm) * Double(height)))
            let rgb = f.rgb
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = y * bytesPerRow + x * 4
                    bytes[i]     = rgb.b
                    bytes[i + 1] = rgb.g
                    bytes[i + 2] = rgb.r
                    bytes[i + 3] = 0xFF
                }
            }
        }
        return bytes
    }

    /// Allocate a pixel buffer, copy in the static template, then stamp
    /// the per-frame barcode squares on top.
    private static func makeFrameBuffer(
        pool: CVPixelBufferPool?,
        width: Int,
        height: Int,
        bytesPerRow templateBytesPerRow: Int,
        template: [UInt8],
        frameNumber: Int
    ) throws -> CVPixelBuffer {
        var maybe: CVPixelBuffer?
        let status: CVReturn
        if let pool {
            status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &maybe)
        } else {
            status = CVPixelBufferCreate(
                kCFAllocatorDefault, width, height,
                kCVPixelFormatType_32BGRA, nil, &maybe
            )
        }
        guard status == kCVReturnSuccess, let buffer = maybe else {
            throw Error.appendFailed("pixel buffer alloc failed: \(status)")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw Error.appendFailed("base address nil")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let w = CVPixelBufferGetWidth(buffer)

        // Copy the static template row-by-row (CVPixelBuffer's bytesPerRow
        // can include padding beyond width*4).
        template.withUnsafeBytes { src in
            for y in 0..<h {
                let srcRow = src.baseAddress!.advanced(by: y * templateBytesPerRow)
                let dstRow = base.advanced(by: y * bytesPerRow)
                memcpy(dstRow, srcRow, templateBytesPerRow)
            }
        }

        // Stamp the barcode. White (1) and black (0) squares sized
        // generously so chroma subsampling can't smudge adjacent bits.
        let bitWidthNorm = barcodeWidthNorm / Double(barcodeBits)
        // Inset the per-bit drawing slightly so neighboring bits never
        // share an edge — gives the H.264 encoder less to interpolate.
        let drawHalfNorm = (bitWidthNorm / 2) * 0.85
        let yLo = max(0, Int(barcodeYRangeNorm.lowerBound * Double(h)))
        let yHi = min(h, Int(barcodeYRangeNorm.upperBound * Double(h)))
        for i in 0..<barcodeBits {
            let bit = (frameNumber >> (barcodeBits - 1 - i)) & 1
            let cx = barcodeBitCenterX(i)
            let xLo = max(0, Int((cx - drawHalfNorm) * Double(w)))
            let xHi = min(w, Int((cx + drawHalfNorm) * Double(w)))
            let lum: UInt8 = bit == 1 ? 0xFF : 0x00
            for y in yLo..<yHi {
                let row = base.advanced(by: y * bytesPerRow)
                    .assumingMemoryBound(to: UInt8.self)
                for x in xLo..<xHi {
                    row[x * 4]     = lum
                    row[x * 4 + 1] = lum
                    row[x * 4 + 2] = lum
                    row[x * 4 + 3] = 0xFF
                }
            }
        }
        return buffer
    }
}
