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
- **All three text fields — transcript, summary, and notes — are
  user-editable.** AI populates transcript and summary; the user can edit
  them afterward to refine. Each field has its own focus-snapshot undo
  behavior, identical to how `notes` works today.
- The intelligence pipeline is testable end-to-end without depending on
  Apple's actual ML stack.

## Non-goals

- Real-time live transcription while the coach is recording.
- Speaker diarization.
- Multi-language detection (we use the system locale, falling back to `en-US`).
- Translation.
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
5. When the summary lands, it is written directly to disk. Neither write
   pushes an undo entry — AI-driven writes are not user actions and don't
   participate in the undo stack. The user can edit either field
   afterward (their edits DO go through the standard focus-snapshot undo
   path, same as `notes`).
6. If the user is on a clip while its job completes, the inspector
   live-updates because the coordinator mutates `workspace.project.clips[i]`
   directly and `Workspace` is `@Observable`.

### Existing clips (backfill / re-run)
1. The Notes section of the inspector always shows a **Transcribe** button.
2. Clicking the button enqueues the same job. The button is disabled while
   any job involving this clip is in flight; a `ProgressView` plus a small
   caption ("Transcribing…" / "Summarizing…") sits next to it.
3. Re-running clobbers whatever's in `transcript` and `summary` with the
   fresh AI output. The two text fields above the button show the current
   content, so the user can see what will be replaced. If they want to
   keep prior content, they can edit it elsewhere before clicking
   Transcribe. (No confirm dialog — the visible content + the verb on
   the button are sufficient warning, matching how the rest of the app
   handles destructive-looking buttons.)

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
│     Workspace.applyAIWrite     │     │ struct FakeClipIntelligence     │
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

             let text = try await intelligence.transcribe(audioURL: url)
             workspace.applyAIWrite(id: clipID) { $0.transcript = text }
                 // direct write + saveProject(); NO undo push

             setPhase(.summarizing)

             let summary = try await intelligence.summarize(text)
             workspace.applyAIWrite(id: clipID) { $0.summary = summary }
                 // direct write + saveProject(); NO undo push

             clearInFlight()
           }
```

### Workspace helper

The coordinator uses a single helper on `Workspace`:

```swift
extension Workspace {
    /// Apply an AI-generated mutation directly to a clip. Saves the
    /// project. Does NOT push an undo entry — AI writes are not user
    /// actions and don't participate in the undo stack. Short-circuits
    /// if the clip was deleted between enqueue and write.
    ///
    /// Why no undo push: the inspector's focus-snapshot pattern
    /// (ClipInspector.EditorView) diffs the WHOLE Clip on focus-loss.
    /// If we pushed undo entries from out-of-band AI writes, a
    /// concurrent user edit's focus-loss flush would bundle the AI
    /// write into the user's undo step — cmd-z of (say) a notes edit
    /// would silently revert the AI write. Routing AI writes around
    /// the undo stack avoids this. Users who want different transcript
    /// or summary content can edit the fields directly; those edits DO
    /// go through the standard focus-snapshot undo path.
    func applyAIWrite(id: Clip.ID, _ mutate: (inout Clip) -> Void) {
        guard let i = project.clips.firstIndex(where: { $0.id == id })
        else { return }
        mutate(&project.clips[i])
        try? saveProject()
    }
}
```

If the clip is deleted before its job completes, the helper
short-circuits on `firstIndex(where:) == nil`. The in-flight
transcribe work isn't cancelled (acceptable cost for a rare case);
its result is discarded on the firstIndex check.

**Edge case (accepted):** If the user is actively editing one text
field (notes, transcript, or summary) when the coordinator writes a
different one, the user's focus-loss flush will diff the whole clip,
see two fields changed, and bundle them into one undo step. `cmd-z` of
that edit then also reverts the AI write. Window is small (the user
must type during the few seconds between job-start and summary-land);
recovery is trivial (re-run Transcribe). Project file on disk still
holds the latest values because each AI write saved directly.

## Inspector UI

`ClipInspector.EditorView` gains transcript + summary sub-sections inside
the existing "Notes" `Group`. Layout:

```
Notes
  Summary               ← TextEditor, ~40pt min height (1–2 lines)
  ┌────────────────────┐
  │ (editable)         │
  └────────────────────┘

  Transcript            ← TextEditor, ~120pt min height
  ┌────────────────────┐
  │ (editable)         │
  └────────────────────┘

  [ Transcribe ]  ⠋  Transcribing…   ← Button + ProgressView + step caption

  Your notes            ← existing TextEditor binding to clip.notes
  ┌────────────────────┐
  │ (editable)         │
  └────────────────────┘
```

- All sub-sections live inside the existing single `Group { Text("Notes")…}`
  block in `ClipInspector.swift`. No new top-level inspector section.
- Summary, transcript, and notes are **three independent `TextEditor`s**
  with identical interaction semantics. Each binds directly to its
  field on `clip` (Summary → `clip.summary`, Transcript →
  `clip.transcript`, Your notes → `clip.notes`). Each gets its own
  focus-snapshot pattern in `EditorView` (matching the existing
  `nameSnapshot` / `tagsSnapshot` / `notesSnapshot` triple — now five
  snapshots total).
- Empty placeholder text on the summary/transcript editors: "—" in
  `.secondary`, replaced as soon as the user types or AI populates.
- The button title is always **"Transcribe"**. The transcript content
  above it is the affordance for whether pressing it creates vs.
  replaces — no title-flipping logic.
- The button is disabled while a job involving this clip is in flight.
- A small `ProgressView` and a step caption (`.caption.secondary`) sit
  next to the button while in flight, reading either "Transcribing…",
  "Summarizing…", or "Downloading speech model…" (first-run only).
- On `.failed`, the button re-enables and an inline error appears below
  it: `.callout.foregroundStyle(.red)` with `error.localizedDescription`.
- **Live-update during AI write:** if the user is NOT focused in the
  transcript / summary field while the AI writes, the TextEditor
  re-renders with the new value (binding reads through `@Observable`).
  If the user IS focused there at the moment the AI writes, the
  TextEditor's internal cursor state is preserved by SwiftUI's binding
  semantics — but the field text updates to the new value as soon as
  SwiftUI re-evaluates the body. This is acceptable: the user is
  almost certainly typing into `notes`, not into a field the AI is
  about to fill, and the rare-case behavior (AI clobbers in-progress
  user typing in transcript or summary) is the same "re-run if
  clobbered" pattern as elsewhere.

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

- **AI writes never push undo entries.** Every write from the
  coordinator (auto-on-record-finish or manual via the Transcribe
  button) goes through `Workspace.applyAIWrite`, which mutates and saves
  but does NOT call `commitClipEdit`. Rationale: see the "Why no undo
  push" comment block on the helper. cmd-z on AI-populated content is
  not provided; if the user dislikes the AI output, they edit the
  fields directly (those edits ARE undoable).
- **Each AI write is its own atomic save.** Transcript persists when
  transcribe finishes; summary persists when summarize finishes. A
  crash between the two preserves the transcript.
- **User edits to transcript / summary / notes go through the existing
  focus-snapshot path.** EditorView snapshots each field on focus-gain;
  on focus-loss it computes the whole-clip diff and calls
  `commitClipEdit` if `before != after`. This is the SAME mechanism
  `notes` uses today; transcript and summary join it with their own
  snapshot variables.
- **`commitClipEdit` does not save.** Matching the existing convention
  in ClipInspector (PiP toggle, focus-loss flush, `mutateMatchEvents`),
  every existing caller follows up with `try? saveProject()`. The
  EditorView's existing flush already does this; the new field
  snapshots reuse the same flush helper.

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
  - happy path: enqueue → transcript landed and saved → summary landed
    and saved → state `.idle` → NO undo entries pushed
  - transcript-step failure leaves both fields empty, state `.failed`,
    no save fired
  - summarize-step failure: transcript persisted via direct write,
    state `.failed`, no undo entries pushed
  - re-enqueue while a job is in flight is a no-op
  - two enqueued clips run serially, not concurrently (assertion via a
    fake that records overlap)
  - deleting a clip mid-job: helper short-circuits cleanly with no
    spurious save
- `WorkspaceIntelligenceEditTests`: `applyAIWrite` mutates and saves
  without pushing undo; short-circuits on missing clip ID.
- `InspectorEditFieldTests`: each of transcript / summary / notes
  produces its own focus-loss undo step that round-trips through
  `undo()` / `redo()`.

### Smoke (manual)

After build, record a short clip and confirm:
1. Sidebar gets the clip immediately.
2. Inspector shows "Transcribing…" caption next to the button, then real
   transcript text.
3. Caption switches to "Summarizing…", then the summary appears.
4. Re-launching the app and re-opening the project preserves both fields.
5. Manual button re-runs on an existing clip and clobbers prior content.
6. Editing the transcript or summary field manually, then blurring,
   then `cmd-z` reverts that edit (but not the AI write itself — AI
   writes are not in the undo stack).

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

4. **Recording deletion during transcribe.** The `applyAIWrite` helper
   short-circuits if the clip ID no longer exists. The in-flight
   transcription is not cancelled; its work completes and is discarded
   on write.

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

## Out of scope (deferred to backlog if revisited)

- Live partial-transcript streaming into the inspector while recording.
- Searching clips by transcript content (would be a separate spec — index
  + sidebar filter UI).
- Editable transcripts.
- Translating non-English transcripts.
- Background asset pre-download on app launch.
- Cancelling an in-flight job when a clip is deleted (the current
  short-circuit on write is sufficient).
