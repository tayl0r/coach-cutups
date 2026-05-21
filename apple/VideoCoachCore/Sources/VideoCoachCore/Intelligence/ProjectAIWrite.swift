import Foundation

public extension Project {
    /// Apply an AI-generated mutation to a single clip in place.
    /// No-op if the clip ID isn't found (deleted between enqueue and write).
    /// Pure data — Workspace's matching wrapper handles persistence;
    /// neither this nor the wrapper push undo. See the spec's
    /// "Persistence + undo" section for the rationale.
    mutating func applyAIWrite(id: Clip.ID, _ mutate: (inout Clip) -> Void) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        mutate(&clips[i])
    }
}
