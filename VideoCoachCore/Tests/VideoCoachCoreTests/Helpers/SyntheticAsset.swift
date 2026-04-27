import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Generates tiny on-disk QuickTime assets for AVFoundation integration tests.
/// All writes are real `AVAssetWriter` invocations — produces actual playable
/// files at temp paths the caller is responsible for cleaning up.
enum SyntheticAsset {
    enum Error: Swift.Error {
        case writerStartFailed
        case writerFinishFailed(Swift.Error?)
        case pixelBufferAllocationFailed(CVReturn)
        case appendFailed(String)
    }

    /// Write a 1-second-by-default solid-color BGRA video at 30fps to `url`.
    /// When `hasAudio` is true, adds an audio track of equal duration. By default
    /// the audio track is silent; pass `audioFrequency` to generate a sine tone
    /// (mono PCM-encoded-as-AAC at 44.1kHz) at the given amplitude (0.0–1.0).
    /// `videoColor` is BGRA channels; the default is mid-grey.
    static func write(
        to url: URL,
        duration: Double = 1.0,
        hasAudio: Bool,
        width: Int = 64,
        height: Int = 64,
        videoColor: (r: UInt8, g: UInt8, b: UInt8) = (0x80, 0x80, 0x80),
        audioFrequency: Double? = nil,
        audioAmplitude: Double = 1.0
    ) throws {
        try writeAsset(
            to: url,
            duration: duration,
            hasVideo: true,
            hasAudio: hasAudio,
            width: width,
            height: height,
            videoColor: videoColor,
            audioFrequency: audioFrequency,
            audioAmplitude: audioAmplitude
        )
    }

    /// Write an audio-only `.m4a` (silent 44.1kHz mono AAC) of `duration` seconds to `url`.
    static func writeAudioOnly(to url: URL, duration: Double = 1.0) throws {
        try writeAsset(
            to: url,
            duration: duration,
            hasVideo: false,
            hasAudio: true,
            width: 64,
            height: 64,
            videoColor: (0x80, 0x80, 0x80),
            audioFrequency: nil,
            audioAmplitude: 1.0
        )
    }

    // MARK: -

    private static func writeAsset(
        to url: URL,
        duration: Double,
        hasVideo: Bool,
        hasAudio: Bool,
        width: Int,
        height: Int,
        videoColor: (r: UInt8, g: UInt8, b: UInt8),
        audioFrequency: Double?,
        audioAmplitude: Double
    ) throws {
        precondition(hasVideo || hasAudio, "must request at least one track")

        let fileType: AVFileType = hasVideo ? .mov : .m4a
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)

        let videoInput: AVAssetWriterInput?
        let pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
        if hasVideo {
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
            videoInput = input
            pixelAdaptor = adaptor
        } else {
            videoInput = nil
            pixelAdaptor = nil
        }

        let audioInput: AVAssetWriterInput?
        if hasAudio {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: 64_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw Error.appendFailed("cannot add audio input")
            }
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }

        guard writer.startWriting() else {
            throw Error.writerStartFailed
        }
        writer.startSession(atSourceTime: .zero)

        // Drive video and audio writes concurrently. The encoders backpressure
        // each other (an HD H.264 encoder fills its buffer fast and blocks
        // isReadyForMoreMediaData until other tracks consume time), so writing
        // them sequentially can deadlock at higher resolutions.
        let videoFinished = DispatchSemaphore(value: 0)
        let audioFinished = DispatchSemaphore(value: 0)
        var videoError: Swift.Error?
        var audioError: Swift.Error?

        if let videoInput, let pixelAdaptor {
            let queue = DispatchQueue(label: "SyntheticAsset.video")
            let timescale: CMTimeScale = 600
            let fps = 30
            let frameCount = max(1, Int((duration * Double(fps)).rounded()))
            let frameDuration = CMTime(
                value: CMTimeValue(timescale / CMTimeScale(fps)),
                timescale: timescale
            )
            let state = VideoState(frameCount: frameCount, frameDuration: frameDuration)
            videoInput.requestMediaDataWhenReady(on: queue) {
                do {
                    try Self.driveVideo(
                        state: state,
                        input: videoInput,
                        adaptor: pixelAdaptor,
                        width: width,
                        height: height,
                        videoColor: videoColor,
                        finished: videoFinished
                    )
                } catch {
                    videoError = error
                    videoInput.markAsFinished()
                    videoFinished.signal()
                }
            }
        } else {
            videoFinished.signal()
        }

        if let audioInput {
            let queue = DispatchQueue(label: "SyntheticAsset.audio")
            let sampleRate: Double = 44_100
            let totalFrames = Int((duration * sampleRate).rounded())
            let state = AudioState(totalFrames: totalFrames, sampleRate: sampleRate)
            audioInput.requestMediaDataWhenReady(on: queue) {
                do {
                    try Self.driveAudio(
                        state: state,
                        input: audioInput,
                        frequency: audioFrequency,
                        amplitude: audioAmplitude,
                        finished: audioFinished
                    )
                } catch {
                    audioError = error
                    audioInput.markAsFinished()
                    audioFinished.signal()
                }
            }
        } else {
            audioFinished.signal()
        }

        videoFinished.wait()
        audioFinished.wait()
        if let videoError { throw videoError }
        if let audioError { throw audioError }

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        if writer.status != .completed {
            throw Error.writerFinishFailed(writer.error)
        }
    }

    /// Per-track state carried across `requestMediaDataWhenReady` invocations.
    private final class VideoState {
        var nextFrame = 0
        var done = false
        let frameCount: Int
        let frameDuration: CMTime
        init(frameCount: Int, frameDuration: CMTime) {
            self.frameCount = frameCount
            self.frameDuration = frameDuration
        }
    }

    private final class AudioState {
        var emittedFrames = 0
        var done = false
        let totalFrames: Int
        let sampleRate: Double
        init(totalFrames: Int, sampleRate: Double) {
            self.totalFrames = totalFrames
            self.sampleRate = sampleRate
        }
    }

    private static func driveVideo(
        state: VideoState,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        width: Int,
        height: Int,
        videoColor: (r: UInt8, g: UInt8, b: UInt8),
        finished: DispatchSemaphore
    ) throws {
        if state.done { return }
        // Append while AVFoundation will accept more frames; return when it
        // says no — the system reinvokes us when it's ready again.
        while input.isReadyForMoreMediaData {
            if state.nextFrame >= state.frameCount {
                state.done = true
                input.markAsFinished()
                finished.signal()
                return
            }
            let pts = CMTimeMultiply(state.frameDuration, multiplier: Int32(state.nextFrame))
            let pixelBuffer = try makeSolidBGRABuffer(
                pool: adaptor.pixelBufferPool,
                width: width,
                height: height,
                videoColor: videoColor
            )
            if !adaptor.append(pixelBuffer, withPresentationTime: pts) {
                throw Error.appendFailed("pixel buffer append failed at \(pts.seconds)")
            }
            state.nextFrame += 1
        }
    }

    private static func makeSolidBGRABuffer(
        pool: CVPixelBufferPool?,
        width: Int,
        height: Int,
        videoColor: (r: UInt8, g: UInt8, b: UInt8)
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
            throw Error.pixelBufferAllocationFailed(status)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let h = CVPixelBufferGetHeight(buffer)
            let w = CVPixelBufferGetWidth(buffer)
            // Fast path: monochromatic byte fill (all four BGRA channels equal).
            if videoColor.r == videoColor.g, videoColor.g == videoColor.b {
                memset(base, Int32(videoColor.r), bytesPerRow * h)
            } else {
                // Per-pixel BGRA fill row-by-row. Channel order: B, G, R, A.
                let b = videoColor.b
                let g = videoColor.g
                let r = videoColor.r
                for y in 0..<h {
                    let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<w {
                        let i = x * 4
                        row[i] = b
                        row[i + 1] = g
                        row[i + 2] = r
                        row[i + 3] = 0xFF
                    }
                }
            }
        }
        return buffer
    }

    private static func driveAudio(
        state: AudioState,
        input: AVAssetWriterInput,
        frequency: Double?,
        amplitude: Double,
        finished: DispatchSemaphore
    ) throws {
        if state.done { return }
        let chunkFrames = 1_024
        let timescale = CMTimeScale(state.sampleRate)
        let format = try makeAudioFormatDescription(sampleRate: state.sampleRate)
        while input.isReadyForMoreMediaData {
            if state.emittedFrames >= state.totalFrames {
                state.done = true
                input.markAsFinished()
                finished.signal()
                return
            }
            let frames = min(chunkFrames, state.totalFrames - state.emittedFrames)
            let byteCount = frames * 2
            var blockBuffer: CMBlockBuffer?
            let blockStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount,
                flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &blockBuffer
            )
            guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
                throw Error.appendFailed("block buffer alloc failed: \(blockStatus)")
            }

            if let frequency {
                var samples = [Int16](repeating: 0, count: frames)
                let twoPiF = 2.0 * .pi * frequency
                let scale = amplitude * 32_767.0
                for i in 0..<frames {
                    let n = Double(state.emittedFrames + i)
                    let v = scale * sin(twoPiF * n / state.sampleRate)
                    samples[i] = Int16(max(-32_768.0, min(32_767.0, v)))
                }
                let copyStatus = samples.withUnsafeBytes { rawBuf -> OSStatus in
                    guard let baseAddress = rawBuf.baseAddress else { return -1 }
                    return CMBlockBufferReplaceDataBytes(
                        with: baseAddress,
                        blockBuffer: blockBuffer,
                        offsetIntoDestination: 0,
                        dataLength: byteCount
                    )
                }
                guard copyStatus == kCMBlockBufferNoErr else {
                    throw Error.appendFailed("block buffer copy failed: \(copyStatus)")
                }
            } else {
                let fillStatus = CMBlockBufferFillDataBytes(
                    with: 0,
                    blockBuffer: blockBuffer,
                    offsetIntoDestination: 0,
                    dataLength: byteCount
                )
                guard fillStatus == kCMBlockBufferNoErr else {
                    throw Error.appendFailed("block buffer fill failed: \(fillStatus)")
                }
            }

            let pts = CMTime(value: CMTimeValue(state.emittedFrames), timescale: timescale)
            var sampleBuffer: CMSampleBuffer?
            let sampleStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: format,
                sampleCount: frames,
                presentationTimeStamp: pts,
                packetDescriptions: nil,
                sampleBufferOut: &sampleBuffer
            )
            guard sampleStatus == noErr, let sampleBuffer else {
                throw Error.appendFailed("sample buffer create failed: \(sampleStatus)")
            }
            if !input.append(sampleBuffer) {
                throw Error.appendFailed("audio append failed at \(pts.seconds)")
            }
            state.emittedFrames += frames
        }
    }

    private static func makeAudioFormatDescription(sampleRate: Double) throws -> CMAudioFormatDescription {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard formatStatus == noErr, let format else {
            throw Error.appendFailed("audio format description failed: \(formatStatus)")
        }
        return format
    }
}
