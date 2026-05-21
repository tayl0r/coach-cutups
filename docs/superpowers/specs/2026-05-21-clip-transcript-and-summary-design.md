# Clip Transcript + Summary (Apple AI)

**Status:** Design
**Date:** 2026-05-21
**Author:** Taylor (with Claude)

## Summary

After a recording finishes, automatically transcribe the coach's commentary
audio (the microphone track of the clip's `.mov`) using the on-device
`SpeechAnalyzer` / `SpeechTranscriber` API (macOS 26+), then summarize the
transcript into a 1–2 sentence headline using the on-device Foundation Models
framework. Both results are stored as new persistent fields on `Clip` and
surfaced under the inspector's Notes section alongside the existing
user-editable notes. A manual **Transcribe** button in the inspector lets the
user backfill older clips or re-run the pipeline.

Everything is on-device. No network. No API keys.

## Goals

- Hands-off transcripts for new recordings — coach hits stop, transcript and
  summary appear on the clip a few seconds later.
- Manual backfill for clips that pre-date the feature, or that auto-transcription failed on.
- The transcript and summary live on the `Clip` model and persist via the
  normal `ProjectStore` round-trip.
- Existing manual `notes` field remains independently editable.
- The intelligence pipeline is testable end-to-end without depending on
  Apple's actual ML stack.

## Non-goals

- Real-time live transcription while the coach is recording.
- Speaker diarization.
- Multi-language detection (we use the system locale, falling back to `en-US`).
- Translation.
- Editing the transcript through the UI (it is read-only display; the
  underlying string is still mutable by code paths like re-run).
- Transcribing source-video audio. We only transcribe the microphone track of
  the coach's recording.
- Streaming partial transcripts into the UI as they arrive. The transcript is
  written once when the whole file finishes.

## User-visible behavior

### New recording
1. User records commentary as today (R, narrate, R again).
2. `Workspace.addClip(_:)` appends the new clip. Right after, the recording
   path enqueues a transcription job for this clip on the
   `TranscriptionCoordinator` (described below).
3. The clip immediately appears in the sidebar; the inspector's Notes section
   shows the transcript area with a *Transcribing…* placeholder.
4. When the transcript arrives (typically a few seconds for a ~30s clip), it
   replaces the placeholder and is persisted to disk. The placeholder
   changes to *Summarizing…* while the summary runs.
5. When the summary lands, both fields are committed as a single undo step
   covering the whole job (see "Persistence + undo" below).
6. If the user is on a clip while its job completes, the inspector
   live-updates because the coordinator mutates `workspace.project.clips[i]`
   directly and `Workspace` is `@Observable`.

### Existing clips (backfill / re-run)
1. The Notes section of the inspector always shows a **Transcribe** button
   (single title; the transcript content above it is the affordance for
   whether pressing it creates vs. replaces).
2. Clicking the button enqueues the same job. The button is disabled while
   any job involving this clip is in flight; a `ProgressView` plus a small
   caption ("Transcribing…" / "Summarizing…") sits next to it.
3. Re-running on a clip with an existing transcript replaces it; the
   replacement is one undoable step covering both transcript and summary.

### Failure
- Authorization denied (Speech permission): show a one-time alert with a
  Settings deep-link; the manual button stays available to retry.
- Speech-model assets not yet downloaded: the coordinator drives the
  install request explicitly via
  `AssetInventory.assetInstallationRequest(supporting:)` and awaits
  `downloadAndInstall()`. The inspector caption reads "Downloading speech
  model…" while this runs. (Apple's framework does NOT auto-download — the
  app must trigger and await the install.)
- Transcription / summarization error: log via `Logging` and surface
  `error.localizedDescription` inline under the Notes section. The error
  message is tied to the coordinator's per-clip failed-state — see
  "Inspector UI" for the explicit lifetime.

## Data model

Two new fields on `Clip`:

```swift
public struct Clip: Codable, Hashable, Identifiable, Sendable {
    // ...existing fields...
    public var transcript: String        // "" until transcribed
    public var summary: String           // "" until summarized
    // ...
}
```

Both default to `""`. Empty string ⇒ "not yet generated"; we don't use
`Optional` because the user-facing semantics ("not generated yet") and the
encoded representation should both be a single empty string.

### Format version bump

`Project.currentFormatVersion` rises from **4 → 5**.

Migration is decode-time only, matching the existing pattern in
`Project.init(from:)`. **Verified empirically:** Swift's synthesised
`Decodable` does NOT honour stored-property defaults when a key is absent
— it always calls `decode`, never `decodeIfPresent`. So `Clip` gains an
explicit `init(from:)` that `decodeIfPresent`-defaults `transcript` and
`summary` to `""`. All other existing v4 fields are decoded with
`decode(...)` (they were present in v4 and remain required in v5).
Encoding stays synthesised — the custom decoder only intercepts reads.

```swift
extension Clip {
    private enum CodingKeys: String, CodingKey {
        case id, name, notes, tags, sourceIndex, startSourceSeconds,
             recordingDuration, recordingFilename, events, showPiP,
             sortIndex, createdAt, transcript, summary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id                  = try c.decode(UUID.self,             forKey: .id)
        self.name                = try c.decode(String.self,           forKey: .name)
        self.notes               = try c.decode(String.self,           forKey: .notes)
        self.tags                = try c.decode([String].self,         forKey: .tags)
        self.sourceIndex         = try c.decode(Int.self,              forKey: .sourceIndex)
        self.startSourceSeconds  = try c.decode(Double.self,           forKey: .startSourceSeconds)
        self.recordingDuration   = try c.decode(Double.self,           forKey: .recordingDuration)
        self.recordingFilename   = try c.decode(String.self,           forKey: .recordingFilename)
        self.events              = try c.decode([CommentaryEvent].self, forKey: .events)
        self.showPiP             = try c.decode(Bool.self,             forKey: .showPiP)
        self.sortIndex           = try c.decode(Int.self,              forKey: .sortIndex)
        self.createdAt           = try c.decode(Date.self,             forKey: .createdAt)
        self.transcript          = try c.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        self.summary             = try c.decodeIfPresent(String.self, forKey: .summary)    ?? ""
    }
}
```

(Field names + types must match the current `Clip` declaration in
`Project.swift` at plan-time — the list above is illustrative.)

The `ProjectStore.read` upper-bound guard
(`project.formatVersion > Project.currentFormatVersion`) needs no code
change but its rejection test must be updated to use v6 as the "too new"
case.

A v4 JSON fixture migration test (described in "Testing") locks this
contract in. Future additive `Clip` fields extend this decoder by adding
one `decodeIfPresent` line; the same pattern matches what
`Project.init(from:)` already does for additive `Project` fields.

## Architecture

```
┌────────────────────────────────┐     ┌─────────────────────────────────┐
│ App target                     │     │ VideoCoachCore (Swift Package)  │
│                                │     │                                 │
│ ContentView                    │     │ protocol ClipIntelligence       │
│   ↓                            │     │   transcribe(audioURL:) → String│
│ Workspace.addClip(_:)          │     │   summarize(_:) → String        │
│   ↓ (new)                      │     │                                 │
│ TranscriptionCoordinator       │     │ struct AppleClipIntelligence    │
│   .enqueue(clipID:)            │ ──→ │   import Speech                 │
│   - serial queue               │     │   import FoundationModels       │
│   - writes through             │     │                                 │
│     Workspace.applyClipEdit    │     │ struct FakeClipIntelligence     │
│   - inFlightClipID +           │     │   (test-only, deterministic)    │
│     currentPhase +             │     │                                 │
│     lastFailure                │     └─────────────────────────────────┘
└────────────────────────────────┘
```

### `ClipIntelligence` protocol (Core)

```swift
public protocol ClipIntelligence: Sendable {
    /// Transcribes the audio track of the file at `audioURL`. Returns the
    /// full transcript as a single string. Newlines are preserved between
    /// recognized segments so a future viewer can render with breaks.
    func transcribe(audioURL: URL) async throws -> String

    /// Returns a 1–2 sentence summary of `transcript`. The implementation
    /// is responsible for shaping the prompt; callers pass raw text only.
    func summarize(_ transcript: String) async throws -> String
}
```

Lives at `VideoCoachCore/Sources/VideoCoachCore/Intelligence/ClipIntelligence.swift`.

### `AppleClipIntelligence` (Core, real)

A struct that implements the protocol using:

- **Transcription:** `SpeechAnalyzer` with a `SpeechTranscriber` module
  configured for the system locale (with `en-US` fallback). Before starting
  the analyzer, the implementation calls
  `AssetInventory.assetInstallationRequest(supporting: [transcriber])`; if
  the returned request is non-nil, it awaits `downloadAndInstall()` (Apple
  returns `nil` when the locale's assets are already installed — this is
  the framework's idempotency mechanism, so no app-level cache is needed).
  Audio is then fed from the clip's `.mov` into the analyzer; results are
  collected from the analyzer's async-sequence `results` (each element has
  `text: AttributedString` + `isFinal: Bool`) and joined into a single
  `String`.

  > **NEEDS EYEBALL CONFIRMATION IN XCODE:** the exact audio-feeding path
  > from a `.mov` URL is unclear from published docs. The two candidates
  > are (a) `AVAudioFile(forReading: movURL)` driving
  > `SpeechAnalyzer.start(inputAudioFile:finishAfterFile:)`, or (b) an
  > `AVAssetReader` feeding an `AsyncStream<AnalyzerInput>` into
  > `SpeechAnalyzer.start(inputSequence:)`. Confirm against the macOS 26
  > SDK headers at plan-stage; both shapes are mentioned in Apple's
  > examples, and `.mov` audio is plain LPCM so either should work.

- **Summarization:** `LanguageModelSession` from `FoundationModels`,
  constructed with a result-builder instructions closure (Apple's API
  takes a `@InstructionsBuilder` closure, not a plain `instructions:`
  String). The fixed instructions: *"You are a coaching analyst.
  Summarize the following commentary in one or two short sentences,
  focusing on the coach's main point."* The transcript is passed as the
  user message via `respond(to:)`; the response's `.content` String is
  trimmed and returned.

Availability is checked once on first use via
`SystemLanguageModel.default.availability` (enum: `.available` /
`.unavailable(UnavailableReason)`). When unavailable, the summarize call
throws and the coordinator surfaces the underlying error to the inspector
(see "Risks").

Lives at
`VideoCoachCore/Sources/VideoCoachCore/Intelligence/AppleClipIntelligence.swift`.

### `FakeClipIntelligence` (test-only)

A simple struct that returns predetermined strings (or throws predetermined
errors) so coordinator tests are deterministic and run without Apple's ML
stack. Lives in `VideoCoachCore/Tests/VideoCoachCoreTests/Helpers/`.

### `TranscriptionCoordinator` (App target)

```swift
@MainActor
@Observable
final class TranscriptionCoordinator {
    enum Phase { case transcribing, summarizing }
    enum State { case idle, transcribing, summarizing, failed(Error) }

    /// The single in-flight clip ID, if any. The job queue is serial: at
    /// most one job runs at a time, so a single optional is enough.
    private(set) var inFlightClipID: Clip.ID?

    /// Which phase of the in-flight job is currently active. Only
    /// meaningful when `inFlightClipID != nil`.
    private(set) var currentPhase: Phase = .transcribing

    /// The most recent failure: which clip it belonged to, and the error.
    /// Cleared when a new job starts on that same clip; left untouched
    /// when a job on a different clip succeeds. In-memory only — app
    /// relaunch starts every clip in `.idle`.
    private(set) var lastFailure: (clipID: Clip.ID, error: Error)?

    init(workspace: Workspace, intelligence: ClipIntelligence)

    /// Idempotent. If a job for this clip is already running, returns.
    /// If a different clip is running, this one is enqueued.
    func enqueue(clipID: Clip.ID)

    /// Derived state for the inspector. SwiftUI invalidates only views
    /// that read this through the three observable scalar properties.
    func state(for id: Clip.ID) -> State {
        if inFlightClipID == id {
            return currentPhase == .transcribing ? .transcribing : .summarizing
        }
        if let f = lastFailure, f.clipID == id { return .failed(f.error) }
        return .idle
    }
}
```

- A single serial async `Task` chain. Two recordings stopped in quick
  succession queue rather than race; this avoids two concurrent
  `SpeechAnalyzer` instances and two concurrent `LanguageModelSession`
  responses, and is the simplest correct semantics for a single-user app.
- Each job: (1) resolve `Workspace.recordingURL(for: clip.recordingFilename)`
  (guarding nil), (2) call `transcribe`, (3) save the transcript to disk
  without pushing undo, (4) call `summarize`, (5) push a single combined
  undo step covering both fields and save.
- Coordinator is `@Observable`. `ClipInspector` reads it via
  `@Environment` (injected from `VideoCoachApp`); SwiftUI's targeted
  invalidation re-renders the inspector when any of the three scalars
  change.
- Per-clip "is this clip working" / "did this clip fail" lookups are
  derived from `inFlightClipID` and `lastFailure` — no per-clip
  dictionary, so progress on clip A does not invalidate views observing
  clip B.

Lives at `apple/App/Intelligence/TranscriptionCoordinator.swift`.

### Wiring

- `VideoCoachApp` owns the single `TranscriptionCoordinator` instance and
  injects `AppleClipIntelligence` into it on launch. The coordinator is
  passed into the SwiftUI environment.
- `ContentView` reads the coordinator from the environment and passes
  `enqueue(clipID:)` and `state(for:)` down to the inspector.
- The recording-completion path (currently calls `workspace.addClip(_:)`
  from ContentView after stopping the capture session) gains one line:
  `transcription.enqueue(clipID: clip.id)`.

## Recording-finish pipeline (step by step)

```
ContentView.stopRecording()
  └─ CaptureSessionController.stopRecording()  → recording duration
  └─ (existing) build Clip { transcript: "", summary: "" }
  └─ workspace.addClip(clip)                     → saves project.json
  └─ transcription.enqueue(clipID: clip.id)      ← NEW
        └─ Task {
             guard let url = workspace.recordingURL(for: clip.recordingFilename)
             else { fail(.missingRecording); return }
             setInFlight(clipID, phase: .transcribing)

             let before = currentClipSnapshot(clipID)
             let text = try await intelligence.transcribe(audioURL: url)
             workspace.applyTranscriptDirect(id: clipID, transcript: text)
                 // mutates clip.transcript, calls saveProject() — NO undo push

             setPhase(.summarizing)

             let summary = try await intelligence.summarize(text)
             let after = currentClipSnapshot(clipID, mutate: { $0.summary = summary })
             workspace.applyClipEdit(id: clipID, before: before, after: after)
                 // single undo step covering transcript + summary, saves

             clearInFlight()
           }
```

### Workspace helpers

The coordinator uses two thin helpers on `Workspace`. Both follow the
established convention of every existing `commitClipEdit` caller
(ClipInspector PiP toggle, focus-loss flush): `commitClipEdit` itself
does NOT save — the caller calls `saveProject()` explicitly after.

```swift
extension Workspace {
    /// Apply a transcript directly to a clip without pushing an undo
    /// entry. Saves the project. Used by the coordinator after the
    /// transcript step so the result is durable even if the summary
    /// step fails or the app quits.
    func applyTranscriptDirect(id: Clip.ID, transcript: String) {
        guard let i = project.clips.firstIndex(where: { $0.id == id })
        else { return }
        project.clips[i].transcript = transcript
        try? saveProject()
    }

    /// Generic snapshot/mutate/commit helper that mirrors the existing
    /// `mutateMatchEvents` idiom. Calls `commitClipEdit(before:after:)`
    /// then `saveProject()`. Used by the coordinator for the combined
    /// transcript+summary undo step at job completion.
    func applyClipEdit(id: Clip.ID, before: Clip, after: Clip) {
        guard let i = project.clips.firstIndex(where: { $0.id == id })
        else { return }
        guard before != after else { return }
        project.clips[i] = after
        commitClipEdit(id: id, before: before, after: after)
        try? saveProject()
    }
}
```

If the clip is deleted before its job completes, both helpers
short-circuit on `firstIndex(where:) == nil`. The in-flight transcribe
work isn't cancelled (acceptable cost for a rare case); its result is
discarded on the firstIndex check.

## Inspector UI

`ClipInspector.EditorView` gains an "Intelligence" panel inside the
existing "Notes" `Group`. Layout:

```
Notes
  Summary               ← Text, .footnote.italic, .secondary, single line
  "Coach praises the through-ball; criticizes the off-ball run."

  Transcript            ← scrollable Text in a 1px border, ~100pt min height
  "okay so right here you see the through-ball really opens up the line…"

  [ Transcribe ]  ⠋  Transcribing…   ← Button + ProgressView + step caption

  Your notes            ← existing TextEditor binding to clip.notes
  ┌────────────────────┐
  │ (editable)         │
  └────────────────────┘
```

- All sub-sections live inside the existing single `Group { Text("Notes")…}`
  block in `ClipInspector.swift`. No new top-level inspector section.
- Empty transcript ⇒ summary and transcript areas show "—" (a single em
  dash, .secondary).
- The button title is always **"Transcribe"**. The transcript content
  above it is the affordance for whether pressing it creates vs.
  replaces — no title-flipping logic.
- The button is disabled while a job involving this clip is in flight.
- A small `ProgressView` and a step caption (`.caption.secondary`) sit
  next to the button while in flight, reading either "Transcribing…",
  "Summarizing…", or "Downloading speech model…" (first-run only).
- On `.failed`, the button re-enables and an inline error appears below
  it: `.callout.foregroundStyle(.red)` with `error.localizedDescription`.

### Inline error lifetime

The error string is derived from the coordinator's `lastFailure` state.
It is shown only while `lastFailure.clipID == clip.id`. Re-enqueuing
moves the clip into `inFlightClipID`, which clears the displayed error
on this clip's row (the `lastFailure` record is cleared at the moment
the new run on this same clip starts). A successful run on a different
clip leaves the failed clip's error visible (re-selecting that clip
re-displays it). Coordinator failed-state is in-memory only — relaunching
the app starts every clip in `.idle`. The full error (with stack /
context) is also written via `Logging`.

## Persistence + undo

- **One undo step per job.** A complete auto-transcribe-then-summarize
  pipeline produces exactly one `.editClip` undo entry whose `before` is
  the pre-job clip and `after` has both `transcript` and `summary`
  populated. `cmd-z` rewinds the entire AI action in one step, matching
  user intuition ("undo the AI thing that just happened").
- **Transcript persists immediately.** The transcript text is written to
  disk via `Workspace.applyTranscriptDirect` as soon as the transcribe
  step finishes — this is durable but does NOT push an undo entry. If the
  app crashes or the summary step fails, the transcript is preserved.
- **Summary-step failure produces a transcript-only undo step.** If the
  summarize step throws, the coordinator pushes a single
  `.editClip(before: pre-job, after: post-transcript)` step covering
  just the transcript change, then surfaces the summary error to the UI.
  This keeps the "every auto-transcribe job is at most one undo step"
  invariant.
- **`commitClipEdit` does not save.** Matching the existing convention in
  ClipInspector (PiP toggle, focus-loss flush, `mutateMatchEvents`), the
  workspace helpers above call `saveProject()` themselves. Spec readers:
  do not assume `commitClipEdit` persists — read
  `Workspace.commitClipEdit` directly to confirm.
- **Re-running** on a clip with an existing transcript produces ONE undo
  step covering the replacement of both fields. `cmd-z` rolls back both
  to their prior values in one step.

## Deployment target bump

- `apple/project.yml`: `deploymentTarget.macOS` and `MACOSX_DEPLOYMENT_TARGET`
  both move from `"14.0"` to `"26.0"`. `LSMinimumSystemVersion` likewise.
- `apple/VideoCoachCore/Package.swift`: `platforms: [.macOS(.v26)]`.
- Add `App/Intelligence/TranscriptionCoordinator.swift` to the
  `VideoCoachTests.sources` list in `project.yml`, matching the existing
  `RecordingController.swift` include pattern so the unit-test target
  can import the coordinator.
- Regenerate the project via `xcodegen generate` per CLAUDE.md.

Justification: the new Speech APIs (`SpeechAnalyzer` / `SpeechTranscriber`)
and the Foundation Models framework are both macOS 26-only. The previous
gating value (macOS 14) was inherited from initial scaffolding, not from
any specific OS feature dependency we currently use. The app is a
single-developer macOS coaching tool; running on a current OS is
reasonable.

## Privacy, entitlements, Info.plist

- Add `NSSpeechRecognitionUsageDescription` to `apple/project.yml`
  Info.plist block: "Video Coach transcribes your recorded commentary
  on-device so you can review and search what you said." Required by the
  Speech framework even though processing is local. **Verified:** the new
  `SpeechAnalyzer` API still gates on
  `SFSpeechRecognizer.requestAuthorization(_:)` and the same Info.plist
  key.
- Speech authorization is requested lazily on first transcribe attempt.
  Denial surfaces as the underlying error through the standard failure
  path described above.
- No network usage — `com.apple.security.network.client` is **not** added
  to the entitlements file. Verified against current
  `apple/App/VideoCoach.entitlements`.
- **Verified:** the Foundation Models framework requires no special
  entitlement; gating is via `SystemLanguageModel.default.availability`
  at runtime, not at entitlement time.

## Speech model assets

`SpeechTranscriber` uses on-device locale-specific model packs. **Apple's
framework does not auto-download** — the app must call
`AssetInventory.assetInstallationRequest(supporting: [transcriber])` and,
if the returned request is non-nil, await `downloadAndInstall()`. When
the locale's assets are already installed, the request returns `nil` —
that's the API's idempotency mechanism (so no app-level cache is needed).

We don't pre-download at app launch. Reasons:
1. Adds startup cost for users who may never record.
2. `AppleClipIntelligence.transcribe` already runs the install-request
   path, so the first-run UX is "Transcribing…" with a "Downloading speech
   model…" caption swap during the install.

If we later observe install latency creating noticeable UX friction, a
one-time download prompt at first launch is a clean follow-up (added as a
non-blocking task).

## Testing

### Core (unit, headless via `swift test --package-path apple/VideoCoachCore`)

- `FakeClipIntelligence` returns canned transcript/summary strings and lets
  tests assert ordering, error-path handling, and idempotency without
  touching real Speech APIs.
- **v4 JSON fixture migration test.** Add to
  `ProjectTests.swift`: embed a hand-written v4 JSON string containing a
  fully-populated `Clip` with **no** `transcript` and **no** `summary`
  keys, decode through `Project.init(from:)`, assert:
  `clip.transcript == ""` and `clip.summary == ""`. This fixture is the
  canonical regression test for additive `Clip`-field migrations going
  forward.
- `Clip` Codable: explicit decode/encode round-trip test for the two new
  fields with Unicode content (em dashes, smart quotes, multi-line
  transcripts).
- `ProjectStoreTests.swift`: bump the "too new" rejection test to use
  v6 (was v5).

### App target (existing `VideoCoachTests` target)

- `TranscriptionCoordinatorTests` using `FakeClipIntelligence`:
  - happy path: enqueue → transcript landed and saved → summary landed →
    single combined undo step → state `.idle`
  - transcript-step failure leaves transcript empty, state `.failed`, no
    undo step pushed, no save fired
  - summarize-step failure: transcript persisted via direct write, single
    transcript-only undo step pushed, state `.failed`
  - re-enqueue while a job is in flight is a no-op
  - two enqueued clips run serially, not concurrently (assertion via a
    fake that records overlap)
  - deleting a clip mid-job: helpers short-circuit cleanly with no
    spurious save
  - cmd-z after a successful auto-transcribe job rolls back BOTH fields
    in one step
- `WorkspaceIntelligenceEditTests`: `applyTranscriptDirect` and
  `applyClipEdit` produce the expected undo / persistence behavior;
  round-trip via `undo()` / `redo()` restores prior values.

### Smoke (manual)

After build, record a short clip and confirm:
1. Sidebar gets the clip immediately.
2. Inspector shows "Transcribing…" caption next to the button, then real
   transcript text.
3. Caption switches to "Summarizing…", then the summary line appears.
4. Re-launching the app and re-opening the project preserves both fields.
5. Manual button re-runs on an existing clip.
6. A single `cmd-z` after a re-run rolls back BOTH transcript and summary.

## Risks & open considerations

1. **Foundation Models availability.** On a machine where Apple
   Intelligence is not enabled (or the device is ineligible),
   `SystemLanguageModel.default.availability` reports `.unavailable(...)`.
   Behavior: the summarize call throws Apple's error; the coordinator
   stores it in `lastFailure` after the transcript has landed (so the
   user still gets the transcript). The inspector renders
   `error.localizedDescription` inline. No special-case UI until we see
   this error in the wild and have evidence one is needed.

2. **Speech model first-run download.** Documented in "Speech model
   assets" above. Acceptable for v1; the caption swap to "Downloading
   speech model…" communicates the longer wait.

3. **Long recordings.** A 30-minute recording produces a long transcript
   that may exceed the Foundation Models context window. If Apple throws,
   we land in `lastFailure` with the transcript preserved and the
   underlying error surfaced via `localizedDescription`. No truncation
   heuristics in v1; revisit only if real recordings hit this.

4. **Recording deletion during transcribe.** The `applyClipEdit` /
   `applyTranscriptDirect` helpers short-circuit if the clip ID no longer
   exists. The in-flight transcription is not cancelled; its work
   completes and is discarded on write.

5. **Apple API surface needs eyeball confirmation in Xcode at plan-stage.**
   Web docs + WWDC sessions confirmed the existence and macOS 26 gating
   of `SpeechAnalyzer`, `SpeechTranscriber`,
   `SystemLanguageModel.default.availability`, `LanguageModelSession`,
   `SFSpeechRecognizer.requestAuthorization`, and the
   `NSSpeechRecognitionUsageDescription` key. The following details
   could not be confirmed from public docs and must be verified against
   the macOS 26 SDK headers in Xcode before / during plan execution:
   - Exact audio-feeding path for `SpeechAnalyzer` from a `.mov` URL
     (`AVAudioFile` vs. `AVAssetReader` + `AsyncStream<AnalyzerInput>`).
   - Exact thrown error type for context-window overflow on
     `LanguageModelSession.respond(to:)`.
   - Exact context-window token limit (widely reported as ~4096 but
     unconfirmed in Apple's primary docs).
   None of these affect the design's shape — only the implementation
   details of `AppleClipIntelligence`. If any turns out to differ
   significantly, the implementation choice changes but the surrounding
   architecture does not.

## Open question for the human (deferred from adversarial review)

**Should auto-transcript writes participate in the undo stack at all?**

The current spec (with the "one undo step per job" fix from S3) still
puts the combined transcript+summary write on the undo stack as a single
`.editClip` step. There remains a subtle interaction with the inspector's
focus-snapshot pattern:

> If the user has the notes field focused (a focus-gain snapshot was
> taken), and the coordinator writes `clip.transcript` while focus is
> still held, then the user's focus-loss flush computes
> `before = snapshot (old transcript + old notes)` vs.
> `after = clip (new transcript + new notes)`. The diff captures BOTH
> changes; cmd-z of the notes edit silently undoes the transcript too.

The window is narrow (the user must be actively typing into notes during
the few seconds between job-start and summary-land) but real.

**Options:**

- **(b) Carve auto-writes out of the undo stack entirely.** Auto-job
  writes use `applyTranscriptDirect` for both fields (no undo push).
  Manual button re-runs still use `applyClipEdit` (one undo step).
  Slight inconsistency between auto and manual flows; matches the
  user mental model where the *first* AI run feels like "the app
  populated this for me" (not a user action), but a *re-run* feels
  like a deliberate manual edit.
- **(d) Accept the bug.** Rare window; user can re-run transcribe if it
  gets clobbered.
- **(a) Field-by-field diff in the focus-loss flush.** Most robust but
  adds complexity to `UndoAction` / `commitClipEdit`. The deliberation
  agent flagged this as substantial complexity for a rare bug.

Recommended for user input. The deliberation agent declined to pick
without your call.

## Out of scope (deferred to backlog if revisited)

- Live partial-transcript streaming into the inspector while recording.
- Searching clips by transcript content (would be a separate spec — index
  + sidebar filter UI).
- Editable transcripts.
- Translating non-English transcripts.
- Background asset pre-download on app launch.
- Cancelling an in-flight job when a clip is deleted (the current
  short-circuit on write is sufficient).
