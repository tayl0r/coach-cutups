# Backlog

Deferred items from the scoreboard work (spec → plan → execution → review cycle).
Each entry: what, why deferred, when to revisit.

## Spec / plan corrections (low priority — code is correct, docs lag)

### 1. Spec clock table uses `now ≤ tH1End`; code uses strict `now < tH1End` — RESOLVED
- Spec table updated to strict `<` with a note explaining why (asymmetric to rows 4-5 because of the missing-tag fallback collision). Plan's quoted code block also updated.

### 2. Plan references `CoachCutups.xcodeproj` / scheme `CoachCutups` — RESOLVED
- 12 plan references updated to `apple/VideoCoach.xcodeproj` / scheme `VideoCoach`.

### 3. Plan didn't note `xcodegen generate` is required after creating any new App-target file — RESOLVED
- Plan header now includes a callout block: run `xcodegen generate --spec apple/project.yml` after creating any file under `apple/App/**`. `apple/VideoCoachCore/**` files are SwiftPM-discovered automatically.

## Code follow-ups (not blocking — flag if related work happens)

### 4. `ScoreboardReplayOverlay.Coordinator.clip` is now refreshed on every `updateNSView`
- Fixed in commit `435fed7` (final-review polish).
- Still worth flagging: the coordinator's `clip` capture being stale was a
  latent bug only because `recordingDuration` happens not to change via the
  current undo paths. If clip-level undo ever extends to recording duration,
  audit this overlay (and `StrokeReplayLayer` for the same pattern).

### 5. `MatchEventKind.isHalfTag` has one real call site — RESOLVED
- Inlined the switch at `Workspace.tagMatchEvent`; dropped `isHalfTag` and
  reworked `setHalfTag`'s precondition to switch on `kind` directly. Net win:
  the call site is now exhaustively checked at compile time, so a future
  `MatchEventKind` case can't silently land in the "goal" branch.

### 6. `MatchInspectorPanel` could reuse a "tag with keyboard hint" view helper
- Buttons render `"\(displayName)  G"` etc. — a small `LabeledTagButton` view
  would centralize the formatting. Two call sites today; not worth abstracting.
  Revisit if a third tag-button surface appears.

### 7. `drawText` in `ScoreboardDraw.swift` does an extra context-flip + translate
- Could use `CTM = scale(1, -1)` via `textMatrix` to flip glyphs in place,
  avoiding the saveGState / translate / scale / restore dance. Working code,
  tests pass, the rewrite has a non-zero baseline-math-mistake risk; skipped
  during the final review. Worth visiting next time someone touches the
  function (e.g., when adding a second overlay that needs the same helper —
  extract it then).

### 8. `CompilationInstruction` carries three correlated scoreboard fields — RESOLVED
- Collapsed `scoreboardConfig` / `matchEventsAbs` / `clipStartAbsSeconds` into one nested `ScoreboardContext?`. Compositor's read is now a single optional unwrap; the "if config is nil the other two are ignored" invariant is enforced at the type level. Also removes one wasted per-frame `absNow` add when no scoreboard.
- `make(...)` builder collapsed three params to one (existing test call sites unchanged — they used defaults). Public `export(...)` signature unchanged; `ExportSheet` and the E2E test untouched.

## UX gaps (no spec coverage; surface if users hit them)

### 9. `matchLengthSeconds` UI bound through `* 60 / 60` Stepper — RESOLVED
- Wave 2 replaced `matchLengthSeconds: Int` with `MatchFormat`, and Wave 2
  review added `regulationPeriodMinutes` / `overtimePeriodMinutes` derived
  properties so the Stepper binds directly without `Binding(get:set:)`.

### 10. Stoppage time has no upper cap
- Per spec, deliberately uncapped. If extreme injury delays produce
  `+15:23`-style strings, the new `plusRect` width (`clockW * 1.0`, set in
  commit `435fed7`) is wide enough through `+99:59`. Beyond that, text
  centering will clip. Reasonable for the YAGNI bar.

### 11. No "rapid undo coalescing" for match-event tagging
- Each keypress = one undo entry, matching the existing `editClip` granularity.
  If users complain about Cmd-Z needing 20 presses to unwind a goal storm,
  coalesce consecutive `editMatchEvents` actions within e.g. 500ms.

## Wave 2 deferred (match-inspector revamp)

### 12. Always-visible event picker vs `eventModeActive` toggle
- Wave 2 ships an `E`-triggered overlay (`eventModeActive`) with three buttons
  (1/2/3 → Home Goal / Away Goal / Start-Stop). Adversarial review raised the
  question: if the only ways to fire those events are the keyboard `1/2/3`
  or clicking the buttons, why have the toggle at all? A permanently-visible
  compact row would remove `eventModeActive` from the inspector entirely
  (the keyboard still needs the mode flag to disambiguate from zoom).
- Deferred because: this is a UX call, not a code call. The toggle gives the
  user explicit visual cue that "1/2/3 is now in event-tag mode, not zoom" —
  helpful when the cursor is over the source video and zoom is the muscle-
  memory default. If we make the picker permanent, we need a different way
  to signal that.
- Revisit if a user reports the toggle feels noisy/redundant.

## Clip transcript + summary (Apple AI)

### 13. Audit `swiftLanguageModes: [.v5]` in `VideoCoachCore/Package.swift`
- **Why deferred:** Bumping to Swift 6 mode surfaced a real
  `AVAssetExportSession`-is-not-`Sendable` issue in `CompilationExporter.swift`
  (`Task.detached` captures non-Sendable `AVAssetExportSession`). Fix requires
  `nonisolated(unsafe)` wrappers or a Sendable shim — non-trivial complexity
  for an audit that wasn't part of this feature's scope.
- **When to revisit:** When other work touches `CompilationExporter` or when
  Swift toolchain updates make the Sendable annotation cheaper to satisfy.
  Inline comment on the pin explains the constraint.

### 14. `DeviceWiringModifier.body` chained `.onChange` modifier split
- **Why deferred:** The Swift 6.2 / macOS 26 toolchain can't type-check the
  four-modifier chain in one go. Stepped `let stepOne / stepTwo / stepThree`
  workaround documented inline. Collapsing to a single chain still triggers
  the type-checker timeout under this SDK.
- **When to revisit:** Whenever the SDK or compiler resolves the inference
  budget regression. Test by trying the collapsed form and rebuilding.

### 15. Verify `SpeechAnalyzer` authorization flow on macOS 26
- **Why deferred:** `AppleClipIntelligence.requestSpeechAuthorizationIfNeeded`
  uses the legacy `SFSpeechRecognizer.requestAuthorization` API. Public docs
  at implementation time did not confirm whether `SpeechAnalyzer` shares this
  auth gate or has its own. Conservative: keep the SF guard; worst case it's
  an extra check that no-ops.
- **When to revisit:** First manual smoke test. If granting Speech permission
  doesn't propagate to `SpeechAnalyzer`, the guard might need replacement.

### 16. Test coverage: `.transcribing` → `.summarizing` phase transition
- **Why deferred:** `TranscriptionCoordinator` correctly sets `currentPhase`
  after the transcript write, but no test asserts the in-flight state
  transitions visible to the inspector. The code path is short and correct;
  a refactor that moved the phase assignment would produce an obvious UI bug.
- **When to revisit:** When touching coordinator state machine or adding new
  pipeline phases. Add a test using `FakeClipIntelligence.transcribeDelaySeconds`
  + `summarizeDelaySeconds` to observe both intermediate states.

### 17. Cmd-z while focused on transcript/summary field reverts AI write too
- **Why deferred:** Explicit spec decision (see "Edge case (accepted)" in
  the design spec). If the user is typing in transcript or summary while an
  AI write lands, the focus-loss flush bundles the AI write into the user's
  undo step. Window is small (active typing during the few seconds between
  job-start and summary-land); recovery is one Transcribe-button click. The
  fix (per-field diff in the focus-loss flush) was judged worse than the
  original.
- **When to revisit:** If users actually report this in practice. Inline
  comment on `Workspace.applyAIWrite` documents the rationale.

### 18. No "queued" state in the inspector
- **Why deferred:** When a second clip is enqueued behind an in-flight job,
  `coordinator.state(for: queuedClip.id)` returns `.idle` — same as
  never-transcribed. The inspector shows the Transcribe button as enabled.
  Minor UX gap; user could re-click and would see the request silently
  deduplicate.
- **When to revisit:** If two-recordings-in-quick-succession becomes a common
  workflow. Trivial fix: add a `.queued` case and surface it in the button label.

### 19. First-run speech model download UX
- **Why deferred:** Apple's `AssetInventory.assetInstallationRequest` blocks
  transparently inside `transcribe()`. First-run UX is "Transcribing…
  (longer than usual)" with no explicit progress. Spec accepted this; if it's
  painful in practice, add a "Downloading speech model…" caption swap.
- **When to revisit:** First manual smoke test on a fresh machine.
