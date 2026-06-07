# Back-Anchor P1 Clock From P1 End

**Status:** Design
**Date:** 2026-06-06
**Author:** Taylor (with Claude)

## Summary

When a recording missed the actual kickoff, the user has no way to make the
match-clock display the right minute on playback. They can tag the moment the
first-period whistle blew (end of P1), but the current model treats the first
`startStop` event as the period-1 *start* — so the clock counts up from 00:00
at recording start, lagging real game time by however much was missed.

Add a checkbox in the event-picker overlay (the modal opened with **E** /
*Add Event*). When checked, the system inserts a real `MatchEventRecord`
flagged as the auto-back-anchor at recording time 00:00 (sourceIndex 0,
sourceSeconds 0). Once the user separately tags the end of P1, the clock
back-computes a single offset so that recording time 00:00 reads
`p0Length − endOfP1Abs` and recording time `endOfP1Abs` reads exactly
`p0Length`, transitioning to the inter-period break the same instant the
whistle blew.

P2+ periods are untouched: the user tags real start/stop events as before.

## Goals

- Display a correct match clock on recordings that missed the actual kickoff.
- Single new control: one checkbox in the event-picker overlay.
- Single new persisted field: `MatchEventRecord.isAutoBackAnchor: Bool`.
- Clock derivation change is confined to one branch of
  `scoreboardState(absoluteTime:config:events:)` and stays a pure function.
- Backwards compatible: pre-v6 project files load unchanged.

## Non-goals

- Back-anchoring any period other than P1.
- Auto-detecting the end-of-P1 moment (the user still tags it).
- Stretching/compressing the clock if the tagged P1 end doesn't land at
  exactly one period length from kickoff. The clock runs at 1s/s wall time;
  we only shift its zero point.
- A separate `Project`- or `ScoreboardConfig`-level back-anchor toggle
  orthogonal to the flagged event. The event flag is the single source of
  truth.
- A mode flag that changes UI labelling beyond a single events-list label
  variant ("P1 Start (auto)").

## User-visible behavior

### Event picker overlay

The overlay (`MatchInspectorPanel.eventPickerOverlay`) gains a checkbox
beneath the existing three event buttons:

```
1  Home Goal
2  Away Goal
3  Start/Stop
─────────────────
☐ Back-anchor P1 from end
  Auto-tags P1 start at 00:00. Clock reads correct
  minute once you tag end of P1.
```

- **Disabled** when no scoreboard is configured (same condition as the
  three event buttons).
- **Disabled** when the start/stop cap is already reached.
- **Checked state** is derived: checked iff any event in
  `project.matchEvents` has `isAutoBackAnchor == true`.

Toggling the checkbox does not dismiss the picker (unlike the event
buttons, which dismiss on tap). The user typically wants to flip the
checkbox and then click **3 Start/Stop** to tag the end-of-P1 moment.

### Effect on `matchEvents`

- **Check** → append a `MatchEventRecord(kind: .startStop, sourceIndex: 0,
  sourceSeconds: 0, isAutoBackAnchor: true)` to `project.matchEvents`.
- **Uncheck** → remove every event with `isAutoBackAnchor == true`. (Invariant
  guarantees at most one.)
- If the user manually deletes the flagged event from the events list, the
  checkbox auto-unchecks (it's derived state).

### Events list

The flagged event renders in the chronological events list like any other,
with the label **"P1 Start (auto)"** (instead of the bare "P1 Start" used
for a user-tagged P1 start). Same seek/delete affordances as every other row.

### Clock display

- **Flag absent**: zero behavioral change from today.
- **Flag present, no `.end(0)` tagged yet**: the clock counts up from 00:00
  at recording start as it would for any normal P1 start at 00:00.
  No offset to apply.
- **Flag present AND `.end(0)` tagged at recording time `T`**:
  - At recording time `t ∈ [0, T]`: clock displays `t + (p0Length − T)`.
  - At `t = 0`: clock displays `p0Length − T` (e.g. `45:00 − 38:00 = 7:00`).
  - At `t = T`: clock displays `p0Length` exactly, then transitions to
    `BREAK`/`HT` the same way it does today.
- **Flag present, `T > p0Length`** (invalid — user tagged P1 end later than
  one full period from recording start): the offset is clamped to 0
  (clock counts from 00:00 normally) and the events panel surfaces a
  one-line warning.

P2 onward: untouched. The user-tagged P2 start/end events drive P2's clock
using the existing positional interpretation.

## Architecture & data model

### `MatchEventRecord` gains one field

`apple/VideoCoachCore/Sources/VideoCoachCore/MatchEvent.swift`:

```swift
public struct MatchEventRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: MatchEventKind
    public var sourceIndex: Int
    public var sourceSeconds: Double
    public var isAutoBackAnchor: Bool

    public init(
        id: UUID = UUID(),
        kind: MatchEventKind,
        sourceIndex: Int,
        sourceSeconds: Double,
        isAutoBackAnchor: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.sourceIndex = sourceIndex
        self.sourceSeconds = sourceSeconds
        self.isAutoBackAnchor = isAutoBackAnchor
    }
}
```

**Invariant** (enforced at the only mutation sites — see below): at most one
event has `isAutoBackAnchor == true`, and if present it must satisfy
`kind == .startStop && sourceIndex == 0 && sourceSeconds == 0`.

### Decoder

A custom `init(from:)` defaults the missing key to `false`, mirroring the
`Clip`/`Project` decoders already in the repo:

```swift
private enum CodingKeys: String, CodingKey {
    case id, kind, sourceIndex, sourceSeconds, isAutoBackAnchor
}

public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id            = try c.decode(UUID.self,        forKey: .id)
    self.kind          = try c.decode(MatchEventKind.self, forKey: .kind)
    self.sourceIndex   = try c.decode(Int.self,         forKey: .sourceIndex)
    self.sourceSeconds = try c.decode(Double.self,      forKey: .sourceSeconds)
    self.isAutoBackAnchor = try c.decodeIfPresent(Bool.self, forKey: .isAutoBackAnchor) ?? false
}
```

The synthesized encoder is fine.

### `AbsoluteMatchEvent` plumbs the flag

`scoreboardState(absoluteTime:config:events:)` already accepts
`[AbsoluteMatchEvent]`. We extend that struct with the same flag so the
canonical clock-deriving function can see it without taking a separate
`[MatchEventRecord]` argument:

```swift
public struct AbsoluteMatchEvent: Equatable, Hashable, Sendable {
    public let absSeconds: Double
    public let kind: MatchEventKind
    public let isAutoBackAnchor: Bool

    public init(absSeconds: Double, kind: MatchEventKind, isAutoBackAnchor: Bool = false) {
        self.absSeconds = absSeconds
        self.kind = kind
        self.isAutoBackAnchor = isAutoBackAnchor
    }
}
```

Default `isAutoBackAnchor: false` keeps any existing callers compiling.
`Project.absoluteMatchEvents` carries the flag through.

### `Project` gains two mutation helpers

`apple/VideoCoachCore/Sources/VideoCoachCore/MatchEvent.swift` extension:

```swift
public extension Project {
    /// True iff any `matchEvents` entry has `isAutoBackAnchor == true`.
    var hasAutoBackAnchorP1: Bool {
        matchEvents.contains { $0.isAutoBackAnchor }
    }

    /// Toggle the P1 back-anchor flag.
    /// - on=true: appends a flagged `.startStop` at (sourceIndex 0, sourceSeconds 0)
    ///   if one isn't already present, and one wouldn't exceed the cap.
    /// - on=false: removes every event with `isAutoBackAnchor == true`.
    /// The single-flag invariant is preserved by the existence check on insert.
    mutating func setAutoBackAnchorP1(_ on: Bool) {
        if on {
            guard !hasAutoBackAnchorP1 else { return }
            guard let cap = scoreboard?.format.expectedStartStopEvents else { return }
            let count = matchEvents.lazy.filter { $0.kind == .startStop }.count
            guard count < cap else { return }
            matchEvents.append(.init(
                kind: .startStop,
                sourceIndex: 0,
                sourceSeconds: 0,
                isAutoBackAnchor: true
            ))
        } else {
            matchEvents.removeAll { $0.isAutoBackAnchor }
        }
    }
}
```

`appendStartStop`, `appendHomeGoal`, `appendAwayGoal` are unchanged. The
existing `appendStartStop` cap check naturally honours the flagged event
(it's a regular `.startStop` for cap purposes).

### `Project.currentFormatVersion` → 6

New version line in the comment block:

```swift
/// - v6: added `isAutoBackAnchor` flag on `MatchEventRecord`
static let currentFormatVersion: Int = 6
```

Migration at load: none required — the decoder defaults the absent flag.
`ProjectStore` write path stamps the new `currentFormatVersion` on any
re-save, same as past version bumps.

## Clock derivation

`apple/VideoCoachCore/Sources/VideoCoachCore/ScoreboardState.swift`.
Modified function: `scoreboardState(absoluteTime:config:events:)`. Only the
`.running` branch's `displayedSeconds` changes.

### New file-scope helper

```swift
/// Back-anchor offset for period 0, in seconds.
///
/// Returns `p0Length − p1EndAbs` (always ≥ 0) when:
///   - `events` contains an entry with `isAutoBackAnchor == true`, AND
///   - `interp` resolves a `.end(0)` role.
/// Returns 0 otherwise, or when the raw offset would be negative
/// (user tagged P1 end later than one full period from recording start —
/// invalid input; UI surfaces a warning).
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

### Modified `.running` arm

In the existing `else` branch of `scoreboardState`:

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

Stoppage uses raw `elapsedInPeriod` (unchanged). With a valid back-anchor,
P1 transitions to `BREAK`/`HT` at the user-tagged end before stoppage can
trigger; the stoppage branch only matters when the user hasn't tagged the
end yet (or no back-anchor is set), which is correct fallback behaviour.

### Period transitions, breaks, fulltime, goals

All unchanged. The `.onBreak` / `.fulltime` decision is driven by interp's
`.end` roles, which see the flagged event as a normal `.start(0)`. Goal
window bounds (`firstStartAbs`, `lastEndAbs`) also unchanged — the flagged
event at `absSeconds = 0` is `firstStartAbs`, which means goals at any
recording time count, which is what we want.

## UI

### Checkbox in the event-picker overlay

`apple/App/Views/Scoreboard/MatchInspectorPanel.swift`, in
`eventPickerOverlay` (around line 71). After the three event buttons and
before the cap-warning text:

```swift
Divider()
Toggle(isOn: Binding(
    get: { workspace.project.hasAutoBackAnchorP1 },
    set: { newValue in
        workspace.mutateMatchEvents { p in
            p.setAutoBackAnchorP1(newValue)
        }
    }
)) {
    VStack(alignment: .leading, spacing: 1) {
        Text("Back-anchor P1 from end")
        Text("Auto-tags P1 start at 00:00. Clock reads correct minute once you tag end of P1.")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}
.disabled(workspace.project.scoreboard == nil || (startStopAtCap && !workspace.project.hasAutoBackAnchorP1))
```

The disabled condition lets the user *uncheck* even when at cap (so they can
free a slot), but blocks *checking* when at cap.

`workspace.mutateMatchEvents { ... }` is the existing mutation helper used
by the delete button in this same panel; it both updates the project and
schedules a save through the undo controller. Reusing it keeps the
back-anchor toggle in lockstep with the rest of event editing.

### Events-list label

`MatchInspectorPanel.roleLabel(for:roles:format:)` already routes through
the period role. Extend the `.start(let i)` branch to look up the record's
`isAutoBackAnchor` flag and append "(auto)" when set:

```swift
case .start(let i):
    let suffix = rec.isAutoBackAnchor ? " (auto)" : ""
    return "\(format.periodName(i)) Start\(suffix)"
case .end(let i):
    return "\(format.periodName(i)) End"
```

### Invalid-state warning

When `hasAutoBackAnchorP1 == true` AND the user-tagged P1 end exists AND
its `absSeconds > regulationPeriodSeconds(0)`, the events panel shows a
one-line caption beneath the events list:

> ⚠️ P1 end is later than one period length. Back-anchor offset disabled.

This piggy-backs on the existing overcapacity-warning render pattern in
`settingsModeView` (line 176-182) — same `.font(.caption).foregroundStyle(.orange)`.

## Persistence + format version

- `Project.currentFormatVersion` → 6.
- `MatchEventRecord` gets a custom `init(from:)` defaulting the new field
  to `false` for pre-v6 files.
- `ProjectStore` read-side upper-bound guard already exists and will accept
  v6 once the constant bumps.
- Save path stamps `currentFormatVersion` on any save, so pre-v6 files
  that get opened and re-saved become v6 (no destructive rewrite — just a
  field added to one of the existing event records if the user enables
  back-anchor).

## Testing

Pure-logic tests live under
`apple/VideoCoachCore/Tests/VideoCoachCoreTests/`, run with
`swift test --package-path apple/VideoCoachCore`.

### `scoreboardState` clock derivation

New cases in `ScoreboardStateTests.swift`:

1. **No back-anchor, baseline unchanged.** Existing behaviour test.
2. **Back-anchor flag set, no `.end(0)` yet.** Clock counts from 00:00 at
   recording start. Asserts no offset is applied.
3. **Back-anchor flag set, `.end(0)` at `T = 38·60`, `p0Length = 45·60`.**
   - At recording `t = 0`: clock = `7:00`.
   - At recording `t = 19·60` (halfway): clock = `26:00`.
   - At recording `t = 38·60`: clock transitions to `.onBreak("HT")`.
   - At recording `t = 38·60 + 1`: still `.onBreak`.
4. **Back-anchor flag set, `.end(0)` at `T = 50·60` (T > p0Length).**
   Offset clamps to 0. Clock at `t = 0` shows `0:00`, behaves as a
   normal start at 00:00.
5. **Back-anchor + P2.** P2 start/end tagged at real abs times. P2 clock
   counts from `p0Length` onward, independent of the back-anchor offset.

### `Project` mutation API

New tests in `ProjectTests.swift` (or a new
`AutoBackAnchorTests.swift`):

1. `setAutoBackAnchorP1(true)` from empty: appends one flagged
   `.startStop` at `(0, 0)`.
2. `setAutoBackAnchorP1(true)` when already on: no-op (one flagged event
   total).
3. `setAutoBackAnchorP1(false)`: removes the flagged event.
4. `setAutoBackAnchorP1(true)` at cap: no-op (cap check denies it).
5. `setAutoBackAnchorP1(true)` with no scoreboard: no-op.

### Decoder backwards compat

`PersistenceTests.swift` (or wherever decoding round-trips live): a v5
project JSON (no `isAutoBackAnchor` keys) decodes cleanly, all events get
`isAutoBackAnchor == false`.

### UI

No UI tests added — the existing panel has no UI test scaffolding. Manual
verification:

1. Create a new project with a scoreboard configured.
2. Press **E**, tick the checkbox. Confirm events list shows "P1 Start
   (auto)" at 00:00:00.
3. Press **E**, click **3 Start/Stop**. Confirm events list shows "P1 End"
   at the current playhead.
4. Scrub: confirm the clock reads `45:00 − T` at recording start, `45:00`
   at the tagged moment, then `HT`.
5. Untick the checkbox. Confirm the auto event vanishes from the list and
   the clock resumes the baseline (counts from the user-tagged P1 end as
   `.start(0)`).
6. Re-tick. Tag a P1 end at `T = 50:00` (longer than the 45-min period).
   Confirm the invalid-state warning appears and the clock counts from
   00:00 (offset disabled).

## Migration / rollout

- Single PR.
- `formatVersion` bump to 6.
- Pre-v6 projects load with all flags false; behaviour identical to today.
- A v6 project opened by a hypothetical older client would fail the
  read-side upper-bound check — same as every prior bump.

## Risks

- **The back-anchor offset is only correct when `T < p0Length`.** If the
  user mis-tags the P1 end (e.g. tags a goal restart instead), the
  resulting clock is silently misaligned. We surface a warning when `T >
  p0Length`, but if `T` is *within* the valid range but still wrong, the
  clock will appear plausible. Acceptable: this is no worse than any
  user mis-tag in the existing model.
- **Two flagged events simultaneously** would break the single-anchor
  invariant. Prevented at the only insert site (`setAutoBackAnchorP1`).
  No further guard on `appendStartStop` because that helper never sets the
  flag — the only path to set it is the explicit toggle.
- **User toggles back-anchor on with pre-existing manual start/stop
  events at the front.** The auto event sorts to position 0 (absSeconds 0,
  earliest), so it becomes `.start(0)` in interp; the previously-first
  user event becomes `.end(0)`. If the user had a manual P1 start tagged
  later than 00:00, that tag now plays the role of P1 end. The user can
  observe the role labels in the events list and fix by deleting the
  stale tag. No automatic cleanup; this would be too invasive for a
  rarely-hit corner case.
