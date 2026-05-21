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
