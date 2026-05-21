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

        let transcriber = SpeechTranscriber(
            locale: Locale.current,
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
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }

        // Availability gate. `.available` ⇒ proceed; anything else throws
        // a localized error the inspector surfaces inline.
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw IntelligenceError.modelUnavailable(String(describing: reason))
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

    private func requestSpeechAuthorizationIfNeeded() async throws {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return }
        let status = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw IntelligenceError.notAuthorized
        }
    }

    /// Extracts the first audio track of `sourceURL` into a temporary
    /// `.caf` (linear-PCM) file. Returns the temp URL — caller is
    /// responsible for deleting it.
    private static func extractAudioToCAF(from sourceURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            throw IntelligenceError.noAudioTrack
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

        do {
            let writer = try AVAssetWriter(outputURL: tempURL, fileType: .caf)
            let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
            writerInput.expectsMediaDataInRealTime = false
            writer.add(writerInput)

            guard reader.startReading() else {
                throw reader.error ?? IntelligenceError.extractionFailed("Failed to start audio extraction.")
            }
            guard writer.startWriting() else {
                throw writer.error ?? IntelligenceError.extractionFailed("Failed to start audio writer.")
            }
            writer.startSession(atSourceTime: .zero)

            // Drive the copy from a detached task with a tight pull loop. We
            // avoid `requestMediaDataWhenReady` so that AVAssetReader /
            // AVAssetWriter (which are not `Sendable`) are not captured by
            // an `@Sendable` callback closure; instead they live entirely
            // inside the task body. The `isReadyForMoreMediaData` poll +
            // short sleep is the documented pattern for offline writers.
            //
            // Detached so the busy copy loop runs off MainActor. Cancellation is
            // NOT wired: nothing currently cancels the outer transcribe Task, so
            // routing cancellation in (e.g. via withTaskCancellationHandler) earns
            // nothing today. Revisit if/when the coordinator gains cancel().
            try await Task.detached { [reader, writer, writerInput, output] in
                while let sample = output.copyNextSampleBuffer() {
                    while !writerInput.isReadyForMoreMediaData {
                        Thread.sleep(forTimeInterval: 0.005)
                    }
                    if !writerInput.append(sample) {
                        writerInput.markAsFinished()
                        throw writer.error ?? IntelligenceError.extractionFailed("Failed to append audio sample.")
                    }
                }
                writerInput.markAsFinished()
                if let readerError = reader.error { throw readerError }
            }.value

            await writer.finishWriting()
            if writer.status == .failed {
                throw writer.error ?? IntelligenceError.extractionFailed("Failed to finalize extracted audio.")
            }

            return tempURL
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }
}

private enum IntelligenceError: LocalizedError {
    case noAudioTrack
    case modelUnavailable(String)
    case notAuthorized
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "Recording has no audio track."
        case .modelUnavailable(let reason):
            return "On-device language model unavailable: \(reason)."
        case .notAuthorized:
            return "Speech recognition not authorized. Enable it in System Settings → Privacy & Security → Speech Recognition."
        case .extractionFailed(let detail):
            return "Couldn't extract audio for transcription: \(detail)."
        }
    }
}
