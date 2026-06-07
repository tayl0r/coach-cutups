# Back-Anchor P1 Clock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a checkbox in the event-picker overlay that auto-tags a flagged `MatchEventRecord` at recording 00:00. The clock derivation back-computes a single offset so the displayed minute reads correctly between recording start and the user-tagged P1 end.

**Spec:** `docs/superpowers/specs/2026-06-06-back-anchor-p1-clock-design.md`

**Working branch:** `back-anchor-p1-clock` (already checked out).

**Canonical test commands:**

- Core package: `swift test --package-path apple/VideoCoachCore`
- App full build: `cd apple && xcodegen generate && cd .. && xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build`

---

## Task 1: Add `isAutoBackAnchor` to data model

**Files:**

- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/MatchEvent.swift`
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/Project.swift`

- [ ] **Step 1:** In `MatchEvent.swift`, add `isAutoBackAnchor: Bool` to `MatchEventRecord`. Update the memberwise initializer to take `isAutoBackAnchor: Bool = false` as the trailing parameter. Existing call sites that construct without it (test fixtures in `StartStopRolesTests.swift`, the `appendStartStop` / `appendHomeGoal` / `appendAwayGoal` helpers) keep compiling via the default.

- [ ] **Step 2:** In `MatchEvent.swift`, add a custom `init(from:)` to `MatchEventRecord` that defaults the missing `isAutoBackAnchor` key to `false`. Use the same pattern as `Clip.init(from:)` in `Project.swift` lines 100-122: a private `CodingKeys` enum + `decodeIfPresent ?? false` for the new field. Leave the synthesized encoder alone.

- [ ] **Step 3:** In `MatchEvent.swift`, add `isAutoBackAnchor: Bool` to `AbsoluteMatchEvent`. Update its initializer to take `isAutoBackAnchor: Bool = false` as the trailing parameter. Existing test/helper construction sites with the 2-arg form keep compiling.

- [ ] **Step 4:** In `MatchEvent.swift`, modify `Project.absoluteMatchEvents` to thread the flag:

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

- [ ] **Step 5:** In `Project.swift`, bump `currentFormatVersion` from `5` to `6` and add a new bullet to the version-history comment:

```
/// - v6: added `isAutoBackAnchor` flag on `MatchEventRecord`
```

- [ ] **Step 6:** Run `swift test --package-path apple/VideoCoachCore`. Expect ProjectTests to fail on hard-coded `5` literals (Task 2 fixes those). All other tests should still pass; if any other test breaks, stop and report.

---

## Task 2: Update existing format-version test literals

**Files:**

- Modify: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ProjectTests.swift`

- [ ] **Step 1:** In `ProjectTests.swift`, change the hardcoded `5` to `6`:
  - Line 17: `XCTAssertEqual(decoded.formatVersion, 5)` → `6`
  - Line 123: `XCTAssertEqual(p.formatVersion, 5)` → `6`
  - Line 172: `XCTAssertEqual(reread.formatVersion, 5, "write must bump formatVersion to current (5)")` → `6` (also update the message: `"current (6)"`).

- [ ] **Step 2:** Re-grep to confirm nothing else pins to literal `5` for formatVersion:

```bash
grep -rn "formatVersion.*5" apple/VideoCoachCore/Tests/ apple/App/
```

`ProjectStoreTests.swift` line 47 uses a `futureVersion` variable — leave it alone. Anything else that hardcodes `5` needs the same bump.

- [ ] **Step 3:** Run `swift test --package-path apple/VideoCoachCore`. All tests pass.

---

## Task 3: Add `setAutoBackAnchorP1` mutation API + tests

**Files:**

- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/MatchEvent.swift`
- Create: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/AutoBackAnchorTests.swift`

- [ ] **Step 1:** In `MatchEvent.swift`, add to the existing `public extension Project` block (the one that already houses `appendStartStop`, `appendHomeGoal`, `appendAwayGoal`):

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

- [ ] **Step 2:** Create `apple/VideoCoachCore/Tests/VideoCoachCoreTests/AutoBackAnchorTests.swift`. Cover:

  - `test_setOn_fromEmpty_insertsFlaggedEventAtIndexZero`: empty matchEvents → `setAutoBackAnchorP1(true)` produces exactly one event at index 0 with `isAutoBackAnchor == true`, `kind == .startStop`, `sourceIndex == 0`, `sourceSeconds == 0`.
  - `test_setOn_whenAlreadyOn_isIdempotent`: call twice → still exactly one flagged event.
  - `test_setOff_removesFlaggedEvent`: with one flagged event, `setAutoBackAnchorP1(false)` removes it; existing un-flagged events are untouched.
  - `test_setOn_withPreexistingManualEvent_insertsBeforeIt`: add a manual `.startStop` first, then `setAutoBackAnchorP1(true)`. Assert `matchEvents[0].isAutoBackAnchor == true` and `matchEvents[1]` is the manual one.
  - `test_hasAutoBackAnchorP1_reflectsState`: false before, true after on, false after off.

- [ ] **Step 3:** Run `swift test --package-path apple/VideoCoachCore --filter AutoBackAnchorTests`. All pass.

---

## Task 4: Implement back-anchor offset in `scoreboardState`

**Files:**

- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/ScoreboardState.swift`

- [ ] **Step 1:** At file scope (above or below `scoreboardState`), add the helper:

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

- [ ] **Step 2:** Locate the `.running` arm in `scoreboardState(absoluteTime:config:events:)` — the `else` branch that today computes `elapsedInPeriod` / `displayedSeconds`. Add the back-anchor offset:

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

The stoppage branch stays raw (uses `elapsedInPeriod`, not the displayed value). When back-anchor is active and `.end(0)` is tagged, the outer `if let end = curEnd, now >= end.absSeconds` branch fires first at `now == T`, so the stoppage line is unreachable for back-anchored P1 — correct.

- [ ] **Step 3:** Run `swift test --package-path apple/VideoCoachCore`. Existing ScoreboardTests should still pass (no-back-anchor path is unchanged).

---

## Task 5: Add `scoreboardState` back-anchor tests

**Files:**

- Modify: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ScoreboardTests.swift` (or add a new `BackAnchorClockTests.swift` — pick whichever fits the existing test conventions).

- [ ] **Step 1:** Add the following test cases. Use a 2×45 (soccer) format throughout unless noted.

  - `test_backAnchor_flagWithoutP1End_noOffset`: events = `[flagged(absSeconds: 0)]`. At `now = 10·60`, clock shows `10:00` running, no offset. (No `.end(0)`, so offset is 0.)
  - `test_backAnchor_p1EndBeforePeriodLength_appliesOffset`: events = `[flagged(absSeconds: 0), end(absSeconds: 38·60)]`. Assert:
    - `now = 0`: clock is `.running(seconds: 7·60)` (offset = 45 − 38 = 7 min).
    - `now = 19·60`: clock is `.running(seconds: 26·60)` (7 + 19).
    - `now = 38·60`: clock is `.onBreak("HT")` (break fires at the tagged end).
    - `now = 38·60 + 1`: still `.onBreak("HT")`.
  - `test_backAnchor_p1EndAfterPeriodLength_clampsToZero`: events = `[flagged(absSeconds: 0), end(absSeconds: 50·60)]`. Assert at `now = 0`, clock is `.running(seconds: 0)` — offset clamped, falls back to count-from-zero.
  - `test_backAnchor_withP2_offsetOnlyAffectsP1`: events = `[flagged(0), end(38·60), p2Start(50·60), p2End(95·60)]`. At `now = 60·60` (inside P2), clock is `.running(seconds: 45·60 + 10·60)` = `55:00`. Offset must NOT apply to P2.
  - `test_backAnchor_tiebreakAgainstManualAtZero`: events = `[flagged(absSeconds: 0), manualStartStop(absSeconds: 0)]` (the flagged one first in input order, which is what `setAutoBackAnchorP1` produces by inserting at index 0). Run through `interpret()` and assert `interp[0].role == .start(0)` for the flagged event and `interp[1].role == .end(0)` for the manual event. This is the explicit tie-break guarantee.

- [ ] **Step 2:** Run `swift test --package-path apple/VideoCoachCore --filter ScoreboardTests` (or your new file). All pass.

- [ ] **Step 3:** Run the full core test suite to ensure no regression: `swift test --package-path apple/VideoCoachCore`. All pass.

---

## Task 6: Wire up the UI — Toggle in event picker overlay + label suffix

**Files:**

- Modify: `apple/App/Views/Scoreboard/MatchInspectorPanel.swift`

- [ ] **Step 1:** In `eventPickerOverlay` (around line 71), add the toggle below the existing three event buttons and the `if startStopAtCap` caption. Insertion point: just before the closing brace of the outer `VStack`. Use:

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

The disabled condition lets the user *uncheck* while at cap (so they can free a slot) but blocks *checking* when at cap.

- [ ] **Step 2:** In `roleLabel(for:roles:format:)` (around line 241), append "(auto)" to the start label when the record's flag is set:

```swift
case .start(let i):
    let suffix = rec.isAutoBackAnchor ? " (auto)" : ""
    return "\(format.periodName(i)) Start\(suffix)"
case .end(let i):
    return "\(format.periodName(i)) End"
```

- [ ] **Step 3:** Rebuild the app:

```bash
cd apple && xcodegen generate && cd ..
xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build
```

Build succeeds. Stop and report any compile errors.

---

## Task 7: Manual verification in-app

**Files:** none (manual check only).

Run the freshly built app. The user expects to test this themselves; this task is a self-test pass to catch obvious issues before review.

- [ ] **Step 1:** Open or create a project. Configure a scoreboard with two 45-minute periods.

- [ ] **Step 2:** Add a source video (any recent recording). Press **E**. Confirm the **Back-anchor P1 from end** toggle is visible beneath the three event buttons. Confirm it is enabled.

- [ ] **Step 3:** Tick the toggle. Confirm:
  - The picker stays open (does not auto-dismiss).
  - The events list shows a new row "P1 Start (auto)" at 00:00:00.

- [ ] **Step 4:** Scrub to ~5 minutes into the video. Press **E** → **3 Start/Stop**. Confirm the events list shows "P1 End" at that timestamp.

- [ ] **Step 5:** Scrub the timeline. Confirm the clock display:
  - Reads `40:00` at recording 00:00 (`45 − 5 = 40`).
  - Increments 1s/s with playback.
  - Reads `45:00` at the tagged P1 end moment.
  - Transitions to `HT` immediately after.

- [ ] **Step 6:** Press **E**, untick the back-anchor checkbox. Confirm "P1 Start (auto)" vanishes from the events list. Confirm the clock now treats the user-tagged "Start/Stop" as P1 start (counts from 0 at the tagged moment).

- [ ] **Step 7:** Untick and re-tick. Tag P1 end at ~50 minutes (beyond the 45-min period). Confirm the clock counts from 00:00 at recording start (offset clamped to 0).

---

## Task 8: Commit

**Files:** N/A (git only).

- [ ] **Step 1:** Stage and commit. Suggested message:

```
feat: back-anchor P1 clock from end-of-period-1 tag

Adds a checkbox in the event-picker overlay. When ticked, the system
inserts a flagged MatchEventRecord at recording 00:00 (the auto P1
start). Once the user tags end of P1, scoreboardState back-computes a
single offset so the clock reads the correct minute at recording
start, climbing 1s/s to exactly p0Length at the tagged whistle.

Affects only period 1; P2+ unchanged.

Bumps Project formatVersion to 6 (additive: one optional Bool on
MatchEventRecord, decoder defaults to false for pre-v6 files).
```

---

## Out of scope

- Back-anchoring P2 or any other period.
- Auto-detecting end of P1.
- Stretching/compressing the clock when the tagged P1 end isn't at one period length.
- Surfacing a separate warning UI for invalid back-anchor states. The clock display itself shows the symptom; symmetric with how plausible-but-wrong manual tags are silently accepted today.
- Custom event-picker dismissal behaviour for the toggle (it stays open by design — the picker only dismisses on the three event buttons today).
