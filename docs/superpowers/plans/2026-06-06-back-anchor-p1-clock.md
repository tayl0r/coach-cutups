# Back-Anchor P1 Clock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a checkbox in the event-picker overlay that auto-tags a flagged `MatchEventRecord` at recording 00:00. The clock derivation back-computes a single offset so the displayed minute reads correctly between recording start and the user-tagged P1 end.

**Spec:** `docs/superpowers/specs/2026-06-06-back-anchor-p1-clock-design.md`

**Working branch:** `back-anchor-p1-clock` (already checked out).

**Canonical test commands:**

- Core package: `swift test --package-path apple/VideoCoachCore`
- App full build: `cd apple && xcodegen generate && cd .. && xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build`

**Commit when each task's verification passes** — no dedicated commit task.

---

## Task 1: Data model + format-version bump + existing test literal updates

**Files:**

- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/MatchEvent.swift`
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/Project.swift`
- Modify: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ProjectTests.swift`

- [ ] **Step 1: `MatchEventRecord` gains `isAutoBackAnchor`.** In `MatchEvent.swift`, add `isAutoBackAnchor: Bool` to `MatchEventRecord`. Update the memberwise initializer to take `isAutoBackAnchor: Bool = false` as the trailing parameter. Existing call sites (`appendStartStop`, `appendHomeGoal`, `appendAwayGoal`, test fixtures in `StartStopRolesTests.swift`) keep compiling via the default.

- [ ] **Step 2: Custom `init(from:)` on `MatchEventRecord`.** Same pattern as `Clip.init(from:)` in `Project.swift` lines 100-122: a private `CodingKeys` enum (`id`, `kind`, `sourceIndex`, `sourceSeconds`, `isAutoBackAnchor`) plus `decodeIfPresent(Bool.self, forKey: .isAutoBackAnchor) ?? false`. Leave the synthesized encoder alone.

- [ ] **Step 3: `AbsoluteMatchEvent` gains `isAutoBackAnchor`.** Add the field, default `false` in the init. Existing 2-arg construction sites (tests, compositor literals) keep compiling.

- [ ] **Step 4: `Project.absoluteMatchEvents` threads the flag.**

```swift
public extension Project {
    var absoluteMatchEvents: [AbsoluteMatchEvent] {
        matchEvents.map {
            .init(
                absSeconds: absSeconds(sourceIndex: $0.sourceIndex,
                                       sourceSeconds: $0.sourceSeconds),
                kind: $0.kind,
                isAutoBackAnchor: $0.isAutoBackAnchor
            )
        }
    }
}
```

- [ ] **Step 5: Bump `Project.currentFormatVersion`.** In `Project.swift`, change `5` → `6`. Add a new line to the version-history comment block (preserving prior bullets):

```
/// - v6: added `isAutoBackAnchor` flag on `MatchEventRecord`
```

- [ ] **Step 6: Update format-version test assertions to 6.** In `ProjectTests.swift`:
  - Line 17: `XCTAssertEqual(decoded.formatVersion, 5)` → `6`
  - Line 123: `XCTAssertEqual(p.formatVersion, 5)` → `6`
  - Line 172: `XCTAssertEqual(reread.formatVersion, 5, "write must bump formatVersion to current (5)")` → `6`, message `"current (6)"`.

  **Do NOT change** `"formatVersion": 1` (line 65), `"formatVersion": 2` (line 150), or `"formatVersion": 4` (line 212) — those are legacy-fixture JSON strings testing backward decoding of historical versions; they must stay pinned.

- [ ] **Step 7: Verify.** `swift test --package-path apple/VideoCoachCore`. All existing tests pass.

---

## Task 2: `setAutoBackAnchorP1` mutation API + tests

**Files:**

- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/MatchEvent.swift`
- Modify: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ScoreboardTests.swift`

- [ ] **Step 1: Add `hasAutoBackAnchorP1` + `setAutoBackAnchorP1` to `Project`.** In `MatchEvent.swift`, add to the existing `public extension Project` block (the one with `appendStartStop`, `appendHomeGoal`, `appendAwayGoal`):

```swift
/// True iff any `matchEvents` entry has `isAutoBackAnchor == true`.
var hasAutoBackAnchorP1: Bool {
    matchEvents.contains { $0.isAutoBackAnchor }
}

/// Toggle the P1 back-anchor flag.
/// - on=true: inserts a flagged `.startStop` at `matchEvents[0]` (front of
///   the array) if one isn't already present. Inserting at index 0 — not
///   appending — ensures that if the user also has a manual `.startStop`
///   at recording `(0, 0)`, the flagged event wins `interpret()`'s positional
///   tie-break and remains `.start(0)`.
/// - on=false: removes every event with `isAutoBackAnchor == true`.
/// Idempotent.
mutating func setAutoBackAnchorP1(_ on: Bool) {
    if on {
        guard !hasAutoBackAnchorP1 else { return }
        matchEvents.insert(.init(
            kind: .startStop,
            sourceIndex: 0,
            sourceSeconds: 0,
            isAutoBackAnchor: true
        ), at: 0)
    } else {
        matchEvents.removeAll { $0.isAutoBackAnchor }
    }
}
```

- [ ] **Step 2: Mutation-API tests.** Add a new XCTestCase class (e.g. `AutoBackAnchorMutatorTests`) at the bottom of `ScoreboardTests.swift`. Mirrors how that file already groups `ScoreboardMutatorTests` alongside the state tests. Cover:

  - `test_setOn_fromEmpty_insertsFlaggedEventAtIndexZero`: empty project + scoreboard. After `setAutoBackAnchorP1(true)`: exactly one event, at index 0, with `isAutoBackAnchor == true`, `kind == .startStop`, `sourceIndex == 0`, `sourceSeconds == 0`.
  - `test_setOn_whenAlreadyOn_isIdempotent`: call twice → still exactly one flagged event.
  - `test_setOff_removesFlaggedEvent`: with one flagged event, `setAutoBackAnchorP1(false)` removes it; existing un-flagged events untouched.

- [ ] **Step 3: Decoder backwards-compat test.** In `ProjectTests.swift`, add a test (near `test_v4ClipMissingTranscriptAndSummary_decodesToEmptyStrings` around line 206):

  - Decode a hand-crafted pre-v6 JSON containing a `matchEvents` entry with no `isAutoBackAnchor` key. Assert the decoded record's flag is `false`.

- [ ] **Step 4: JSON round-trip test for `isAutoBackAnchor == true`.** Also in `ProjectTests.swift`: build a project, call `setAutoBackAnchorP1(true)`, encode, decode, assert the decoded record's flag survives as `true`.

- [ ] **Step 5: Verify.** `swift test --package-path apple/VideoCoachCore`. All pass.

---

## Task 3: Back-anchor offset in `scoreboardState` + tests

**Files:**

- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/ScoreboardState.swift`
- Modify: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ScoreboardTests.swift`

- [ ] **Step 1: Add `p1BackAnchorOffset` helper.** At file scope in `ScoreboardState.swift`:

```swift
/// Back-anchor offset for period 0, in seconds.
///
/// Returns `p0Length − p1EndAbs` when an `isAutoBackAnchor` event exists
/// AND `interp` resolves a `.end(0)` role. Returns 0 otherwise, or when
/// the raw offset would be negative (user tagged P1 end later than one
/// full period — invalid input, clamp to 0 so the clock falls back to a
/// plain count-from-zero rather than displaying negative seconds).
private func p1BackAnchorOffset(
    interp: [InterpretedEvent],
    events: [AbsoluteMatchEvent],
    format: MatchFormat
) -> Double {
    guard events.contains(where: { $0.isAutoBackAnchor }) else { return 0 }
    guard let p1End = interp.first(where: {
        if case .end(let i) = $0.role, i == 0 { return true } else { return false }
    }) else { return 0 }
    let offset = Double(format.regulationPeriodSeconds) - p1End.absSeconds
    return max(0, offset)
}
```

- [ ] **Step 2: Apply the offset in the `.running` arm.** Locate the `else` branch in `scoreboardState(absoluteTime:config:events:)` that today computes `elapsedInPeriod` / `displayedSeconds`:

```swift
} else {
    let elapsedInPeriod = now - currentStartAbs
    let perSec = config.format.periodSeconds(curIdx)
    let backAnchor = curIdx == 0
        ? p1BackAnchorOffset(interp: interp, events: events, format: config.format)
        : 0
    let displayedSeconds = cumulativePriorPeriods + elapsedInPeriod + backAnchor
    if elapsedInPeriod <= perSec {
        clock = .running(seconds: displayedSeconds)
    } else {
        clock = .stoppage(
            baseSeconds: cumulativePriorPeriods + perSec,
            plusSeconds: elapsedInPeriod - perSec
        )
    }
}
```

The stoppage branch deliberately stays raw — when back-anchor is active and `.end(0)` is tagged, the outer `now >= end.absSeconds` branch fires first, so the stoppage line is unreachable for back-anchored P1.

- [ ] **Step 3: Clock-derivation tests.** Add to the back-anchor test class created in Task 2 Step 2 (or a sibling class in the same file). Use a 2×45 (soccer) format throughout unless noted. Build events via `AbsoluteMatchEvent` literals; ensure the flagged event uses `isAutoBackAnchor: true`.

  - `test_backAnchor_flagWithoutP1End_noOffset`: events = `[flagged(absSeconds: 0)]`. At `now = 10·60`, expect `.running(seconds: 10·60)` (no offset, no `.end(0)`).
  - `test_backAnchor_p1EndBeforePeriodLength_appliesOffset`: events = `[flagged(absSeconds: 0), end(absSeconds: 38·60)]`. Assert:
    - `now = 0`: `.running(seconds: 7·60)` (offset = 45−38 min).
    - `now = 19·60`: `.running(seconds: 26·60)`.
    - `now = 38·60`: `.onBreak("HT")`.
    - `now = 38·60 + 1`: `.onBreak("HT")`.
  - `test_backAnchor_p1EndAfterPeriodLength_clampsToZero`: events = `[flagged(absSeconds: 0), end(absSeconds: 50·60)]`. At `now = 0`, expect `.running(seconds: 0)`. Offset clamped to 0.
  - `test_backAnchor_withP2_offsetOnlyAffectsP1`: events = `[flagged(0), end(38·60), p2Start(50·60), p2End(95·60)]`. At `now = 60·60`, expect `.running(seconds: 55·60)`. P2 must NOT receive the offset.
  - `test_interpret_flaggedEventWinsTiebreakAtZero`: in `InterpretTests.swift` (or with the back-anchor cluster — pick wherever is more idiomatic). Build absolute events: `[AbsoluteMatchEvent(absSeconds: 0, kind: .startStop, isAutoBackAnchor: true), AbsoluteMatchEvent(absSeconds: 0, kind: .startStop, isAutoBackAnchor: false)]`. Call `interpret(_:format:)`. Assert BOTH `interp[0].originalIndex == 0` and `interp[0].role == .start(0)`; `interp[1].originalIndex == 1` and `interp[1].role == .end(0)`. Asserting both the role and the originating index proves the tie-break is by input order, not coincidence.

- [ ] **Step 4: Verify.** `swift test --package-path apple/VideoCoachCore`. All tests pass.

---

## Task 4: UI — Toggle + label suffix

**Files:**

- Modify: `apple/App/Views/Scoreboard/MatchInspectorPanel.swift`

- [ ] **Step 1: Add the Toggle to `eventPickerOverlay`.** Insertion point: just before the closing brace of the outer `VStack` (after the existing `if startStopAtCap` block, ~line 93). Use:

```swift
Divider()
Toggle("Back-anchor P1 from end", isOn: Binding(
    get: { workspace.project.hasAutoBackAnchorP1 },
    set: { newValue in
        workspace.mutateMatchEvents { p in
            p.setAutoBackAnchorP1(newValue)
        }
    }
))
.help("Auto-tags P1 start at 00:00. Clock reads correct minute once you tag end of P1.")
.disabled(workspace.project.scoreboard == nil ||
          (startStopAtCap && !workspace.project.hasAutoBackAnchorP1))
```

The disabled condition lets the user *uncheck* even at cap (so they can free a slot) but blocks *checking* at cap.

- [ ] **Step 2: Append "(auto)" to the role label for flagged starts.** In `roleLabel(for:roles:format:)` (around line 241):

```swift
case .start(let i):
    let suffix = rec.isAutoBackAnchor ? " (auto)" : ""
    return "\(format.periodName(i)) Start\(suffix)"
case .end(let i):
    return "\(format.periodName(i)) End"
```

- [ ] **Step 3: Rebuild the app.**

```bash
cd apple && xcodegen generate && cd ..
xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build
```

Build must succeed. Stop and report any compile error.

---

## Task 5: Quick post-build smoke check

**Files:** none.

- [ ] **Step 1:** Launch the freshly built app. Open the **E** picker overlay. Confirm the **Back-anchor P1 from end** toggle appears beneath the three event buttons and is enabled (assuming a scoreboard is configured).

That's the self-test boundary. The user drives the full behavioural test themselves — recording, scrub, clock reads — per the manual-verification list in the spec (Testing → UI section).

---

## Out of scope

- Back-anchoring P2 or any other period.
- Auto-detecting end of P1.
- Stretching/compressing the clock when the tagged P1 end isn't at one period length.
- A separate warning UI for invalid back-anchor states. The clock display itself shows the symptom; symmetric with how plausible-but-wrong manual tags are already silently accepted today.
- A compositor/render-path test for the back-anchored clock. Existing `scoreboardState` unit tests cover the logic; the compositor pulls from the same pure function. Adding render-pixel test wiring is out of proportion for this change.
- Custom event-picker dismissal behaviour for the toggle (it stays open by design — the picker only dismisses on the three event buttons today).
