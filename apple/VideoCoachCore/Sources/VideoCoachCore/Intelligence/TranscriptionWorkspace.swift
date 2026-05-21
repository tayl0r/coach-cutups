import Foundation

/// Narrow seam between `TranscriptionCoordinator` and the App-side
/// `Workspace`. Two methods is everything the coordinator needs:
/// the URL to read audio from, and how to apply the AI-generated
/// mutation. The real `Workspace` conforms in the App target;
/// `FakeTranscriptionWorkspace` (tests) holds an in-memory `Project`.
@MainActor
public protocol TranscriptionWorkspace: AnyObject {
    /// Absolute file URL of the recording for `clipID`. Returns nil if
    /// the clip is not in the project, or if no project is open.
    func recordingURL(forClip clipID: Clip.ID) -> URL?

    /// Apply an AI-generated mutation to a clip and persist. No-op if
    /// the clip is gone. MUST NOT push an undo entry.
    func applyAIWrite(id: Clip.ID, _ mutate: (inout Clip) -> Void)
}
