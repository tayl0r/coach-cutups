import Foundation
import AVFoundation
import Speech
import FoundationModels
import VideoCoachCore

/// On-device transcription via macOS 26 `SpeechAnalyzer` +
/// `SpeechTranscriber`, summarization via `LanguageModelSession`. Both
/// purely local; no network, no API keys.
struct AppleClipIntelligence: ClipIntelligence {

    // MARK: - Transcription

    func transcribe(audioURL: URL) async throws -> String {
        try await requestSpeechAuthorizationIfNeeded()

        let locale = Self.resolvedLocale()
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .transcription
        )

        // Install per-locale assets on first use. The framework returns
        // `nil` from `assetInstallationRequest(supporting:)` when the
        // locale's assets are already installed — that is its own
        // idempotency mechanism, so no app-level cache is needed.
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await request.downloadAndInstall()
        }

        // We extract audio from the .mov by writing the audio track to a
        // temporary `.caf` file, then feed it through
        // `SpeechAnalyzer.analyzeSequence(from:)`. `AVAudioFile` cannot
        // open `.mov` containers directly (it is built for plain audio
        // files), so the intermediate file is required. The temp file is
        // removed in a `defer` regardless of success.
        let tempURL = try await Self.extractAudioToCAF(from: audioURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let audioFile = try AVAudioFile(forReading: tempURL)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Collect final results concurrently with the analyzer pulling
        // PCM frames off the file. Non-volatile presets only emit final
        // results, but we gate on `isFinal` anyway so the loop is robust
        // if the preset changes.
        async let collected: [String] = {
            var parts: [String] = []
            for try await result in transcriber.results where result.isFinal {
                parts.append(String(result.text.characters))
            }
            return parts
        }()

        _ = try await analyzer.analyzeSequence(from: audioFile)
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        let parts = try await collected
        return parts.joined(separator: " ")
    }

    // MARK: - Summarization

    func summarize(_ transcript: String) async throws -> String {
        // Availability gate. `.available` ⇒ proceed; anything else throws
        // a localized error the inspector surfaces inline.
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw NSError(
                domain: "AppleClipIntelligence", code: -3,
                userInfo: [NSLocalizedDescriptionKey:
                    "On-device language model unavailable: \(String(describing: reason))."])
        }

        let session = LanguageModelSession {
            """
            You are a coaching analyst. Summarize the following coaching
            commentary in one or two short sentences. Focus on the coach's
            main point. Do not invent details. Output plain text only.
            """
        }
        let response = try await session.respond(to: transcript)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private static func resolvedLocale() -> Locale {
        let candidate = Locale.current
        return candidate.identifier.isEmpty ? Locale(identifier: "en-US") : candidate
    }

    private func requestSpeechAuthorizationIfNeeded() async throws {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return }
        let status = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw NSError(
                domain: "AppleClipIntelligence", code: -4,
                userInfo: [NSLocalizedDescriptionKey:
                    "Speech recognition not authorized. Enable it in System Settings → Privacy & Security → Speech Recognition."])
        }
    }

    /// Extracts the first audio track of `sourceURL` into a temporary
    /// `.caf` (linear-PCM) file. Returns the temp URL — caller is
    /// responsible for deleting it.
    private static func extractAudioToCAF(from sourceURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            throw NSError(
                domain: "AppleClipIntelligence", code: -2,
                userInfo: [NSLocalizedDescriptionKey:
                    "Recording has no audio track."])
        }

        // Read as 16-bit interleaved PCM at the track's natural sample
        // rate. `SpeechAnalyzer` accepts a wide range of formats and
        // resamples internally as needed.
        let formatDescriptions = try await audioTrack.load(.formatDescriptions)
        let sampleRate: Double = {
            guard let first = formatDescriptions.first,
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(first) else {
                return 48_000
            }
            return asbd.pointee.mSampleRate > 0 ? asbd.pointee.mSampleRate : 48_000
        }()
        let channelCount: UInt32 = {
            guard let first = formatDescriptions.first,
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(first) else {
                return 1
            }
            let count = asbd.pointee.mChannelsPerFrame
            return count > 0 ? count : 1
        }()

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        reader.add(output)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-transcribe-\(UUID().uuidString).caf")

        let writer = try AVAssetWriter(outputURL: tempURL, fileType: .caf)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false
        writer.add(writerInput)

        guard reader.startReading() else {
            throw reader.error ?? NSError(
                domain: "AppleClipIntelligence", code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Failed to start audio extraction."])
        }
        guard writer.startWriting() else {
            throw writer.error ?? NSError(
                domain: "AppleClipIntelligence", code: -6,
                userInfo: [NSLocalizedDescriptionKey: "Failed to start audio writer."])
        }
        writer.startSession(atSourceTime: .zero)

        // Drive the copy from a detached task with a tight pull loop. We
        // avoid `requestMediaDataWhenReady` so that AVAssetReader /
        // AVAssetWriter (which are not `Sendable`) are not captured by
        // an `@Sendable` callback closure; instead they live entirely
        // inside the task body. The `isReadyForMoreMediaData` poll +
        // short sleep is the documented pattern for offline writers.
        try await Task.detached { [reader, writer, writerInput, output] in
            while let sample = output.copyNextSampleBuffer() {
                while !writerInput.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                if !writerInput.append(sample) {
                    writerInput.markAsFinished()
                    throw writer.error ?? NSError(
                        domain: "AppleClipIntelligence", code: -7,
                        userInfo: [NSLocalizedDescriptionKey:
                            "Failed to append audio sample."])
                }
            }
            writerInput.markAsFinished()
            if let readerError = reader.error { throw readerError }
        }.value

        await writer.finishWriting()
        if writer.status == .failed {
            throw writer.error ?? NSError(
                domain: "AppleClipIntelligence", code: -8,
                userInfo: [NSLocalizedDescriptionKey: "Failed to finalize extracted audio."])
        }

        return tempURL
    }
}
