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
    /// When `hasAudio` is true, adds a silent 44.1kHz mono AAC audio track of equal duration.
    static func write(to url: URL, duration: Double = 1.0, hasAudio: Bool) throws {
        try writeAsset(to: url, duration: duration, hasVideo: true, hasAudio: hasAudio)
    }

    /// Write an audio-only `.m4a` (silent 44.1kHz mono AAC) of `duration` seconds to `url`.
    static func writeAudioOnly(to url: URL, duration: Double = 1.0) throws {
        try writeAsset(to: url, duration: duration, hasVideo: false, hasAudio: true)
    }

    // MARK: -

    private static func writeAsset(
        to url: URL,
        duration: Double,
        hasVideo: Bool,
        hasAudio: Bool
    ) throws {
        precondition(hasVideo || hasAudio, "must request at least one track")

        let fileType: AVFileType = hasVideo ? .mov : .m4a
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)

        let videoInput: AVAssetWriterInput?
        let pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
        if hasVideo {
            let width = 64, height = 64
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

        if let videoInput, let pixelAdaptor {
            try writeVideoFrames(input: videoInput, adaptor: pixelAdaptor, duration: duration)
        }
        if let audioInput {
            try writeSilentAudio(input: audioInput, duration: duration)
        }

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        if writer.status != .completed {
            throw Error.writerFinishFailed(writer.error)
        }
    }

    private static func writeVideoFrames(
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        duration: Double
    ) throws {
        let timescale: CMTimeScale = 600
        let fps = 30
        let frameCount = max(1, Int((duration * Double(fps)).rounded()))
        let frameDuration = CMTime(value: CMTimeValue(timescale / CMTimeScale(fps)), timescale: timescale)
        var pts = CMTime.zero

        for _ in 0..<frameCount {
            // Block until the writer is ready — synchronous test write, not real-time.
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.001)
            }
            let pixelBuffer = try makeSolidBGRABuffer(pool: adaptor.pixelBufferPool)
            if !adaptor.append(pixelBuffer, withPresentationTime: pts) {
                throw Error.appendFailed("pixel buffer append failed at \(pts.seconds)")
            }
            pts = CMTimeAdd(pts, frameDuration)
        }
        input.markAsFinished()
    }

    private static func makeSolidBGRABuffer(pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        var maybe: CVPixelBuffer?
        let status: CVReturn
        if let pool {
            status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &maybe)
        } else {
            status = CVPixelBufferCreate(
                kCFAllocatorDefault, 64, 64,
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
            let height = CVPixelBufferGetHeight(buffer)
            // Solid mid-grey BGRA = (0x80, 0x80, 0x80, 0xFF). Single memset works for grey.
            memset(base, 0x80, bytesPerRow * height)
        }
        return buffer
    }

    private static func writeSilentAudio(
        input: AVAssetWriterInput,
        duration: Double
    ) throws {
        let sampleRate: Double = 44_100
        let totalFrames = Int((duration * sampleRate).rounded())
        let chunkFrames = 1_024
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

        var emitted = 0
        var pts = CMTime.zero
        let timescale = CMTimeScale(sampleRate)
        while emitted < totalFrames {
            let frames = min(chunkFrames, totalFrames - emitted)
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
            // Fill with silence (zeroes).
            let fillStatus = CMBlockBufferFillDataBytes(
                with: 0,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
            guard fillStatus == kCMBlockBufferNoErr else {
                throw Error.appendFailed("block buffer fill failed: \(fillStatus)")
            }

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
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.001)
            }
            if !input.append(sampleBuffer) {
                throw Error.appendFailed("audio append failed at \(pts.seconds)")
            }
            emitted += frames
            pts = CMTime(value: CMTimeValue(emitted), timescale: timescale)
        }
        input.markAsFinished()
    }
}
