import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Writes a synthetic side-by-side split-color video to disk. Used by zoom
/// rendering tests to verify a horizontal pan/zoom actually shifted the
/// viewport-x: at identity zoom viewport-left is `leftColor`, after a positive
/// panX with scale > 1 the same viewport-left sample maps to source-right and
/// flips to `rightColor`.
enum SplitColorAsset {
    enum Error: Swift.Error {
        case writerStartFailed
        case writerFinishFailed(Swift.Error?)
        case appendFailed(String)
    }

    static func write(
        to url: URL,
        duration: Double = 1.0,
        width: Int = 1280,
        height: Int = 720,
        leftColor: (r: UInt8, g: UInt8, b: UInt8),
        rightColor: (r: UInt8, g: UInt8, b: UInt8)
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
        guard writer.canAdd(input) else {
            throw Error.appendFailed("cannot add video input")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw Error.writerStartFailed
        }
        writer.startSession(atSourceTime: .zero)

        let timescale: CMTimeScale = 600
        let fps = 30
        let frameCount = max(1, Int((duration * Double(fps)).rounded()))
        let frameDuration = CMTime(
            value: CMTimeValue(timescale / CMTimeScale(fps)),
            timescale: timescale
        )

        let semaphore = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "SplitColorAsset.video")
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
                    let buffer = try Self.makeSplitBuffer(
                        pool: adaptor.pixelBufferPool,
                        width: width,
                        height: height,
                        leftColor: leftColor,
                        rightColor: rightColor
                    )
                    if !adaptor.append(buffer, withPresentationTime: pts) {
                        throw Error.appendFailed("pixel buffer append failed at \(pts.seconds)")
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
        if writer.status != .completed {
            throw Error.writerFinishFailed(writer.error)
        }
    }

    private static func makeSplitBuffer(
        pool: CVPixelBufferPool?,
        width: Int,
        height: Int,
        leftColor: (r: UInt8, g: UInt8, b: UInt8),
        rightColor: (r: UInt8, g: UInt8, b: UInt8)
    ) throws -> CVPixelBuffer {
        var maybe: CVPixelBuffer?
        let status: CVReturn
        if let pool {
            status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &maybe)
        } else {
            status = CVPixelBufferCreate(
                kCFAllocatorDefault, width, height,
                kCVPixelFormatType_32BGRA,
                nil,
                &maybe
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
        let mid = w / 2
        for y in 0..<h {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let c = x < mid ? leftColor : rightColor
                let i = x * 4
                row[i]     = c.b
                row[i + 1] = c.g
                row[i + 2] = c.r
                row[i + 3] = 0xFF
            }
        }
        return buffer
    }
}
