import Foundation
@testable import VideoCoachCore

/// Test fake. Returns whatever was configured. Records every call.
/// Supports per-call delay so tests can observe in-flight state.
final class FakeClipIntelligence: ClipIntelligence, @unchecked Sendable {
    var transcriptToReturn: String = "fake transcript"
    var summaryToReturn: String = "fake summary."
    var transcribeError: Error?
    var summarizeError: Error?
    var transcribeDelaySeconds: Double = 0
    var summarizeDelaySeconds: Double = 0

    private let lock = NSLock()
    private var _transcribeCalls: [URL] = []
    private var _summarizeCalls: [String] = []

    var transcribeCalls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return _transcribeCalls
    }
    var summarizeCalls: [String] {
        lock.lock(); defer { lock.unlock() }
        return _summarizeCalls
    }

    func transcribe(audioURL: URL) async throws -> String {
        lock.lock(); _transcribeCalls.append(audioURL); lock.unlock()
        if transcribeDelaySeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(transcribeDelaySeconds * 1_000_000_000))
        }
        if let e = transcribeError { throw e }
        return transcriptToReturn
    }

    func summarize(_ transcript: String) async throws -> String {
        lock.lock(); _summarizeCalls.append(transcript); lock.unlock()
        if summarizeDelaySeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(summarizeDelaySeconds * 1_000_000_000))
        }
        if let e = summarizeError { throw e }
        return summaryToReturn
    }
}
