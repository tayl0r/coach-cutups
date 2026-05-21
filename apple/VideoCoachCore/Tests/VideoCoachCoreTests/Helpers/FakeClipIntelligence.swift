import Foundation
@testable import VideoCoachCore

/// Test fake. Returns whatever was configured. Records every call.
/// Supports per-call delay so tests can observe in-flight state.
@MainActor
final class FakeClipIntelligence: ClipIntelligence {
    var transcriptToReturn: String = "fake transcript"
    var summaryToReturn: String = "fake summary."
    var transcribeError: Error?
    var summarizeError: Error?
    var transcribeDelaySeconds: Double = 0
    var summarizeDelaySeconds: Double = 0

    private(set) var transcribeCalls: [URL] = []
    private(set) var summarizeCalls: [String] = []

    func transcribe(audioURL: URL) async throws -> String {
        transcribeCalls.append(audioURL)
        if transcribeDelaySeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(transcribeDelaySeconds * 1_000_000_000))
        }
        if let e = transcribeError { throw e }
        return transcriptToReturn
    }

    func summarize(_ transcript: String) async throws -> String {
        summarizeCalls.append(transcript)
        if summarizeDelaySeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(summarizeDelaySeconds * 1_000_000_000))
        }
        if let e = summarizeError { throw e }
        return summaryToReturn
    }
}
