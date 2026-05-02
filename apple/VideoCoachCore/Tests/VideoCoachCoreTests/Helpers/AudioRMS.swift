import AVFoundation
import CoreMedia
import Foundation

enum AudioRMSError: Error {
    case startReadingFailed(Swift.Error?)
}

/// Reads PCM samples through `AVAssetReader` and computes RMS amplitude. Used
/// by the Phase 9.0 spike to confirm an `AVMutableAudioMix` actually attenuated
/// the source audio under an HEVC export preset.
enum AudioRMS {
    static func measure(track: AVAssetTrack, in asset: AVAsset) async throws -> Double {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else {
            throw AudioRMSError.startReadingFailed(reader.error)
        }
        var sumSq = 0.0
        var count = 0.0
        while let buf = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buf) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(
                block,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &dataPointer
            )
            guard let p = dataPointer else { continue }
            let floats = UnsafeBufferPointer<Float32>(
                start: UnsafeRawPointer(p).assumingMemoryBound(to: Float32.self),
                count: length / MemoryLayout<Float32>.size
            )
            for s in floats {
                sumSq += Double(s) * Double(s)
                count += 1
            }
        }
        return sqrt(sumSq / max(1, count))
    }
}
