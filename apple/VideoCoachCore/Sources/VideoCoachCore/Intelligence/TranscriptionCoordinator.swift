import Foundation
import Observation

/// Phase-of-job + result state for a single clip's transcription
/// pipeline. File-scope (not nested in `TranscriptionCoordinator`) so
/// `Equatable`'s nonisolated `==` requirement isn't in conflict with
/// the coordinator's `@MainActor` isolation. Payload on `.failed` is a
/// localized message string, not an `Error` — equality is then trivial
/// and the inspector only ever renders the string anyway.
public enum TranscriptionState: Equatable, Sendable {
    case idle
    case transcribing
    case summarizing
    case failed(String)
}

/// Drives the per-recording transcribe-then-summarize pipeline.
///
/// Serial: at most one job runs at a time. Two recordings stopped in
/// quick succession queue rather than race — avoids two concurrent
/// `SpeechAnalyzer` instances and two concurrent `LanguageModelSession`
/// responses.
///
/// Writes results into the workspace via `applyAIWrite`, which saves
/// but never pushes undo. See the spec's "Persistence + undo" section.
@MainActor
@Observable
public final class TranscriptionCoordinator {

    enum Phase { case transcribing, summarizing }

    private let workspace: TranscriptionWorkspace
    private let intelligence: ClipIntelligence

    /// The single in-flight clip ID, if any.
    public private(set) var inFlightClipID: Clip.ID?

    /// Which phase of the in-flight job is currently active. Only
    /// meaningful when `inFlightClipID != nil`.
    private(set) var currentPhase: Phase = .transcribing

    /// The most recent failure: which clip it belonged to, and a
    /// localized message. In-memory only — relaunching the app starts
    /// every clip in `.idle`.
    public private(set) var lastFailure: (clipID: Clip.ID, message: String)?

    /// FIFO queue of clip IDs awaiting their turn behind `inFlightClipID`.
    private var queue: [Clip.ID] = []

    public init(workspace: TranscriptionWorkspace, intelligence: ClipIntelligence) {
        self.workspace = workspace
        self.intelligence = intelligence
    }

    /// Idempotent. If a job for this clip is already running OR already
    /// queued, returns. Otherwise enqueues. The runner advances itself.
    public func enqueue(clipID: Clip.ID) {
        if inFlightClipID == clipID { return }
        if queue.contains(clipID) { return }
        queue.append(clipID)
        runNextIfIdle()
    }

    /// Derived state for the inspector to drive its UI. Reads only the
    /// three @Observable scalars — no per-clip dictionary.
    public func state(for id: Clip.ID) -> TranscriptionState {
        if inFlightClipID == id {
            return currentPhase == .transcribing ? .transcribing : .summarizing
        }
        if let f = lastFailure, f.clipID == id { return .failed(f.message) }
        return .idle
    }

    // MARK: - Runner

    private func runNextIfIdle() {
        guard inFlightClipID == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        inFlightClipID = id
        currentPhase = .transcribing
        // Starting a job on this clip clears its prior failure.
        if lastFailure?.clipID == id { lastFailure = nil }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runJob(clipID: id)
            self.inFlightClipID = nil
            self.runNextIfIdle()
        }
    }

    private func runJob(clipID: Clip.ID) async {
        guard let url = workspace.recordingURL(forClip: clipID) else {
            lastFailure = (clipID, "Recording file is missing or inaccessible.")
            return
        }
        do {
            let text = try await intelligence.transcribe(audioURL: url)
            workspace.applyAIWrite(id: clipID) { $0.transcript = text }

            currentPhase = .summarizing
            let summary = try await intelligence.summarize(text)
            workspace.applyAIWrite(id: clipID) { $0.summary = summary }
        } catch {
            // Log the structured error for debugging; surface the
            // localized message to the UI.
            NSLog("[Transcription] failed for clip \(clipID): \(error)")
            lastFailure = (clipID, error.localizedDescription)
        }
    }
}
