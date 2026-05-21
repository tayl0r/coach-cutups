import Foundation
import VideoCoachCore

/// Real implementation. Currently a stub — Task 8 fills in the Speech
/// + FoundationModels integration. Until that lands, every job lands
/// in the coordinator's `.failed` state, which is the correct behavior
/// on machines where Apple Intelligence is unavailable.
struct AppleClipIntelligence: ClipIntelligence {
    func transcribe(audioURL: URL) async throws -> String {
        throw NSError(
            domain: "AppleClipIntelligence", code: -1,
            userInfo: [NSLocalizedDescriptionKey:
                "Transcription not yet implemented (Task 8)."])
    }

    func summarize(_ transcript: String) async throws -> String {
        throw NSError(
            domain: "AppleClipIntelligence", code: -1,
            userInfo: [NSLocalizedDescriptionKey:
                "Summarization not yet implemented (Task 8)."])
    }
}
