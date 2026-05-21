import Foundation

/// Pure-logic seam for the on-device transcription + summarization
/// pipeline. The real implementation (`AppleClipIntelligence`) lives
/// in the App target because it imports `Speech` and `FoundationModels`
/// (frameworks that don't link in headless `swift test`). The test fake
/// in this package returns canned strings so coordinator tests are
/// deterministic and run headlessly.
public protocol ClipIntelligence: Sendable {
    /// Transcribes the audio track of the file at `audioURL`. Returns the
    /// full transcript as a single string. Newlines are preserved between
    /// recognized segments so a future viewer can render with breaks.
    func transcribe(audioURL: URL) async throws -> String

    /// Returns a 1–2 sentence summary of `transcript`. The implementation
    /// is responsible for shaping the prompt; callers pass raw text only.
    func summarize(_ transcript: String) async throws -> String
}
