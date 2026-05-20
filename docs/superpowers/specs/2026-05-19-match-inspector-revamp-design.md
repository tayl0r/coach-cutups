# Match Inspector Revamp — Design Spec

**Date:** 2026-05-19
**Status:** Approved through brainstorming
**Worktree:** `.claude/worktrees/scoreboard`

## Goal

Three coupled changes to the scoreboard's inspector experience:

1. **Configurable match format.** `ScoreboardConfig` gains a `MatchFormat` (regulation periods + duration, overtime periods + duration). Soccer is the default but quarters, single-period games, and games with OT are first-class.
2. **Single "start/stop" event kind.** The four soccer-specific half-tag kinds collapse into one `.startStop`. A pure interpreter binds events to format-driven roles at read time. No drift between stored role and chronological order; format changes re-interpret existing data for free.
3. **Inspector-only UX.** `MatchSetupSheet` (modal) is replaced by inline mode-swap inside the inspector panel — settings render where the match panel normally is, keeping source-video playback live. The six tag buttons collapse into a single "Add Event (E)" affordance that expands the inspector into a modal sub-state with three hotkeys (`1` Home Goal, `2` Away Goal, `3` Start/Stop). Bare `1`/`2`/`3`/`4`/`G`/`H` shortcuts are removed; `1`/`2`/`3` return to their zoom bindings unconditionally.

## Architecture summary

- **Data:** `MatchFormat` value added to `ScoreboardConfig`. `MatchEventKind` reduced to three cases (`.startStop`, `.homeGoal`, `.awayGoal`). `Project.formatVersion` bumps 3 → 4; v3 decoder migrates old half-tag kinds to `.startStop`.
- **Interpretation:** new pure function `interpret(events: [AbsoluteMatchEvent], format: MatchFormat) -> [InterpretedEvent]` produces positional roles (`.start(periodIndex:)`, `.end(periodIndex:)`). The clock function `scoreboardState` takes `MatchFormat + [InterpretedEvent]` instead of the old fixed-kind events.
- **UI:** `MatchInspectorPanel` gains two view-state modes (`.events` and `.settings`); `MatchSetupSheet` deleted. Event-tagging UI becomes one button in `.events` mode plus a transient overlay panel that appears while in E-mode. `Project → Match Setup…` menu item now sets the inspector to `.settings` mode rather than presenting a sheet.
- **Keyboard:** `KeyCommandView` gains `e` as a mode-enter key (in `.scanning`/`.recording`, when scoreboard configured). When in E-mode, `1`/`2`/`3` route to event-add closures and `esc` exits without committing. The `four`/`g`/`h` key codes and the `scoreboardConfigured` branch in the `1`/`2`/`3` arm are removed.

## 1. Data model

### `MatchFormat`

In `Sources/VideoCoachCore/Scoreboard.swift`:

```swift
public struct MatchFormat: Codable, Hashable, Sendable {
    public var regulationPeriods: Int            // 2 soccer, 4 NBA/NFL, 1 darts, …
    public var regulationPeriodSeconds: Int      // 45*60 soccer, 12*60 NBA, …
    public var overtimePeriods: Int              // 0 if not applicable
    public var overtimePeriodSeconds: Int

    public init(
        regulationPeriods: Int = 2,
        regulationPeriodSeconds: Int = 45 * 60,
        overtimePeriods: Int = 0,
        overtimePeriodSeconds: Int = 15 * 60
    ) { … }
}

public extension MatchFormat {
    var totalPeriods: Int { regulationPeriods + overtimePeriods }
    var expectedStartStopEvents: Int { 2 * totalPeriods }

    /// True when `periodIndex` falls in the overtime range.
    func isOvertime(periodIndex i: Int) -> Bool { i >= regulationPeriods }

    /// Length of one period at this index (regulation or overtime).
    func periodSeconds(_ i: Int) -> Double {
        Double(isOvertime(periodIndex: i) ? overtimePeriodSeconds : regulationPeriodSeconds)
    }

    /// User-facing label for a period index. `"1H"`/`"2H"` when the
    /// regulation count is exactly 2 (soccer convention); otherwise
    /// `"P1"`/`"P2"`/…; overtime always `"OT1"`/`"OT2"`/….
    func periodName(_ i: Int) -> String {
        if isOvertime(periodIndex: i) {
            return "OT\(i - regulationPeriods + 1)"
        }
        if regulationPeriods == 2 {
            return i == 0 ? "1H" : "2H"
        }
        return "P\(i + 1)"
    }

    /// Label for the inter-period break that follows period `i`. Returns
    /// `"HT"` for soccer's halftime (regulation count == 2, break after
    /// period 0); `"BREAK"` for every other inter-period gap.
    func breakLabel(afterPeriodIndex i: Int) -> String {
        regulationPeriods == 2 && i == 0 ? "HT" : "BREAK"
    }
}
```

### `ScoreboardConfig`

`matchLengthSeconds: Int` removed. Replaced with `format: MatchFormat`. Because `format` is non-optional and v3 files lack the key, `ScoreboardConfig` gains an explicit `Codable` implementation (parallel to `Project.init(from:)`):

```swift
public struct ScoreboardConfig: Codable, Hashable, Sendable {
    public var home: TeamConfig
    public var away: TeamConfig
    public var stadium: String
    public var city: String
    public var format: MatchFormat

    public init(home: TeamConfig, away: TeamConfig, stadium: String, city: String,
                format: MatchFormat = .init()) {
        self.home = home; self.away = away
        self.stadium = stadium; self.city = city
        self.format = format
    }

    private enum CodingKeys: String, CodingKey {
        case home, away, stadium, city, format, matchLengthSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.home = try c.decode(TeamConfig.self, forKey: .home)
        self.away = try c.decode(TeamConfig.self, forKey: .away)
        self.stadium = try c.decode(String.self, forKey: .stadium)
        self.city = try c.decode(String.self, forKey: .city)
        if let f = try c.decodeIfPresent(MatchFormat.self, forKey: .format) {
            self.format = f
        } else if let mls = try c.decodeIfPresent(Int.self, forKey: .matchLengthSeconds) {
            // v3 back-compat: split matchLengthSeconds into two equal regulation
            // periods; identical clock behavior to today for the default 90-min match.
            self.format = MatchFormat(regulationPeriods: 2, regulationPeriodSeconds: mls / 2)
        } else {
            self.format = .init()
        }
    }
}
```

The encoder is synthesized; only `format` is written, never `matchLengthSeconds` (the legacy key drops on first save).

### `MatchEventKind`

Reduced from six cases to three:

```swift
public enum MatchEventKind: String, Codable, Hashable, Sendable {
    case startStop      // single kind for all period boundaries
    case homeGoal
    case awayGoal
}
```

The four named half-tag kinds (`gameStart`, `firstHalfEnd`, `secondHalfBegin`, `gameEnd`) **no longer exist in the source code** after migration. They're handled by the v3 decoder (below) and immediately rewritten as `.startStop`.

### Interpreted events

```swift
public enum PeriodRole: Equatable, Sendable {
    case start(periodIndex: Int)
    case end(periodIndex: Int)
}

public struct InterpretedEvent: Equatable, Sendable {
    public let absSeconds: Double
    public let role: PeriodRole
}

/// Pure interpreter. Sorts start/stop events ascending by absolute time, then
/// assigns positional roles: position 0 → `.start(0)`, 1 → `.end(0)`, 2 →
/// `.start(1)`, 3 → `.end(1)`, etc. The (i//2)-th period is started by even
/// indices and ended by odd indices.
///
/// Events beyond `format.expectedStartStopEvents` are dropped — the cap is
/// enforced at write time too, so this only matters for malformed data.
public func interpret(_ startStops: [AbsoluteMatchEvent], format: MatchFormat) -> [InterpretedEvent]
```

The interpreter takes only the start/stop subset of events. Goal events bypass it (they don't have periods to assign to).

### `Project` mutations

Replace `setHalfTag` and `placeStartStop` (introduced earlier in the brainstorm and never built) with a single mutator that appends a start/stop record with no role baked in:

```swift
public extension Project {
    /// Append a start/stop record. No-op if the configured format's
    /// `expectedStartStopEvents` cap is already reached. Caller is the chokepoint
    /// at `Workspace.mutateMatchEvents` so undo + observation still flow through.
    mutating func appendStartStop(sourceIndex: Int, sourceSeconds: Double) {
        guard let cap = scoreboard?.format.expectedStartStopEvents else { return }
        let count = matchEvents.lazy.filter({ $0.kind == .startStop }).count
        guard count < cap else { return }
        matchEvents.append(.init(kind: .startStop, sourceIndex: sourceIndex, sourceSeconds: sourceSeconds))
    }
}
```

`appendGoal` stays unchanged. No re-normalization pass is needed (the interpreter derives roles every read; the stored data is format-agnostic).

### Persistence migration (v3 → v4)

`Project.currentFormatVersion` bumps to 4. `ProjectStore.read` widens to accept `[1, 4]`. The custom `Project.init(from:)` decoder handles v3 conversion:

```swift
// In the decoded matchEvents array (CodingKey: .matchEvents), records may
// arrive with v3 kinds. Rewrite them to .startStop.
let raw = try c.decodeIfPresent([RawMatchEventRecord].self, forKey: .matchEvents) ?? []
self.matchEvents = raw.map { rec in
    let kind: MatchEventKind
    switch rec.rawKind {
    case "homeGoal":           kind = .homeGoal
    case "awayGoal":           kind = .awayGoal
    // v3 half-tag kinds all collapse to .startStop; the interpreter
    // re-derives roles from chronological order.
    case "gameStart", "firstHalfEnd", "secondHalfBegin", "gameEnd",
         "startStop":
        kind = .startStop
    default:
        // Unknown kinds (future versions) — drop. Defensive.
        return nil
    }
    return MatchEventRecord(id: rec.id, kind: kind, sourceIndex: rec.sourceIndex, sourceSeconds: rec.sourceSeconds)
}.compactMap { $0 }
```

(`RawMatchEventRecord` is a private decode-only struct that lets the kind through as a raw string. Implementation detail.)

`ScoreboardConfig.format` back-compat lives in `ScoreboardConfig.init(from:)` above (v3 files synthesize `format` from `matchLengthSeconds`). v3 projects with the default 90-min match decode as 2 × 45-min regulation periods — identical clock behavior to today.

## 2. Clock semantics (revised)

`scoreboardState` signature changes:

```swift
public func scoreboardState(
    absoluteTime now: Double,
    config: ScoreboardConfig,    // carries .format and .home/.away/.stadium/.city
    events: [AbsoluteMatchEvent]
) -> ScoreboardState?
```

Internally:
1. Validate team names non-empty (else nil).
2. Split events into `startStops` and `goals`.
3. `interp = interpret(startStops, format: config.format)`.
4. If no `.start(0)` event exists in `interp`, return nil (pre-kickoff).
5. If `now < interp[start(0)].absSeconds`, return nil.
6. Walk `interp` to determine current clock state (see table below).
7. Count goals within the game span (between first period start and last expected period end, or `+∞` if not yet placed).

### Clock state derivation

The interpreter produces an alternating sequence of `.start(0)`, `.end(0)`, `.start(1)`, `.end(1)`, … of length up to `format.expectedStartStopEvents`. Walk these in order; for each pair we know if the period is "in progress" (start placed, no end), "complete" (both placed), or "not yet started" (neither placed).

For the **current period** (the highest-indexed `.start` with `absSeconds ≤ now`):

- if its matching `.end` is missing or `now < .end.absSeconds`:
  - `elapsedInPeriod = now - startAbs`
  - `cumulativePriorPeriods = sum(format.periodSeconds(j) for j in 0..<currentIndex)`
  - `displayedSeconds = cumulativePriorPeriods + elapsedInPeriod`
  - if `elapsedInPeriod ≤ format.periodSeconds(currentIndex)` → `.running(seconds: displayedSeconds)`
  - else → `.stoppage(baseSeconds: cumulativePriorPeriods + format.periodSeconds(currentIndex), plusSeconds: elapsedInPeriod - format.periodSeconds(currentIndex))`
    (When the matching `.end` is missing entirely, `elapsedInPeriod` grows unboundedly and stoppage's `plusSeconds` tracks real time — intended "user hasn't tagged FT yet" experience; consistent with §6's uncapped-stoppage non-goal.)

- else (period ended, in break between this and next):
  - if this is the last expected period → `.fulltime`
  - else → `.onBreak(label: format.breakLabel(afterPeriodIndex: currentIndex))`
    - `breakLabel(afterPeriodIndex:)` returns `"HT"` when `regulationPeriods == 2 && i == 0`, otherwise `"BREAK"`. Same rule lives in one place; `formatClock` stays dumb.

### `ClockDisplay`

```swift
public enum ClockDisplay: Equatable, Sendable {
    case running(seconds: Double)
    case stoppage(baseSeconds: Double, plusSeconds: Double)
    case onBreak(label: String)  // e.g. "HT" (soccer halftime) or "BREAK" (any other inter-period gap)
    case fulltime
}
```

`formatClock` returns `ClockLabels`:
- `.onBreak(label)` → `(label, "")`
- `.fulltime` → `("FT", "")`
- `.running` / `.stoppage` — same MM:SS / +M:SS formatting as today

### Score window

`homeScore` = count of `.homeGoal` records whose `absSeconds` falls in `[firstPeriodStartAbs, lastEndAbs]`. `awayScore` analogous.

`lastEndAbs` semantics — must be derived per **role of the last interpreted event**, not its raw timestamp:

- if `interp.count == format.expectedStartStopEvents` AND `interp.last.role` is `.end(_)` → `lastEndAbs = interp.last.absSeconds` (game is fully tagged; ignore goals tagged after FT)
- otherwise (any other state — final period in progress, or fewer events than expected, or last event is a `.start`) → `lastEndAbs = .infinity` (continue counting goals; the user just hasn't tagged FT yet)

The naive `interp.last?.absSeconds ?? .infinity` is wrong because `interp.last` may be a `.start` event — using that as the sentinel would silently exclude goals scored after the final period's start when the matching end isn't placed yet (e.g., a goal at 88:00 wouldn't appear in the scoreboard until the user tags FT).

## 3. Inspector UX

### Two modes

`MatchInspectorPanel` becomes a router with two view states. Both pieces of mode state live on `ContentView` as `@State` — matching the existing pattern for `appMode`, `selectedTagFilter`, and today's `showMatchSetup`:

```swift
// In ContentView (replacing `@State private var showMatchSetup: Bool = false`):
enum InspectorMode { case events, settings }
@State private var inspectorMode: InspectorMode = .events
@State private var eventModeActive: Bool = false
```

The panel takes both as `@Binding`s; `KeyCommandView` takes `eventModeActive` as a plain `Bool` (it reads but never writes — same precedent as `hasTagFilter`, `scoreboardConfigured` today). The menu's focused-value closure flips `inspectorMode` from inside ContentView (it captures ContentView's own `@State` setter — same precedent as today's `openMatchSetupHandler`).

**`Workspace` gains no UI-mode methods or properties.** It stays project-data + persistent-handle only (matches the existing convention — every Workspace property today is `project`, an I/O handle, or ephemeral state with a non-UI reason to live there). UI mode toggles are pure view state; they belong on ContentView.

**Events mode** (the default):
- Header: `"MATCH"` + small `"Edit"` button (right-aligned) that flips to settings mode.
- Live score line (when scoreboard is configured): `"ARS  0 – 0  BUR    0:07"`. When pre-kickoff: `"ARS – BUR"` muted.
- Single primary action: `"Add Event  E"` button (full-width, prominent).
- Below: events list. Each row shows `timestamp + role string + seek + delete`. The role string is derived: goals render as `"Home Goal"` / `"Away Goal"` directly from kind; start/stop records render via the interpreter (`interpret(...)` produces `PeriodRole` for each, which the panel renders as e.g. `"1H Start"`, `"OT1 End"` via `MatchFormat.periodName(_:)` + role direction). Over-cap start/stop rows (interpreter returns no role) render as plain `"Start/Stop"`; the settings-mode banner is the only place that flags the capacity mismatch.

When the user presses `E` (or clicks the button), an **event picker overlay** appears below the button (in-panel, not a popover). The overlay shows three buttons stacked or in a row:
- `"1  Home Goal"`
- `"2  Away Goal"`
- `"3  Start/Stop"` — disabled (greyed) when `expectedStartStopEvents` cap is reached, with helper text `"Game tagged. Delete a start/stop event to add another."`

The overlay disables the rest of the inspector content (greyed out) for the duration of E-mode. Pressing `1`/`2`/`3` or clicking the corresponding button commits the event and exits E-mode. Pressing `Esc` exits without committing. Clicking the "Add Event" button again also exits. (Other keypresses fall through to existing handlers — they don't dismiss the mode.)

**Settings mode**:
- Renders the same form `MatchSetupSheet` had today, but inline in the panel.
- Header changes to `"MATCH SETTINGS"` + `"Done"` button (right-aligned) that commits and returns to events mode.
- Form fields: team name + 2 colors (each team), stadium + city, **and the new format controls**:
  - `Regulation periods: [stepper, 1…10]`
  - `Period length: [stepper, 1…180 min]`
  - `Overtime periods: [stepper, 0…10]`
  - `OT period length: [stepper, 1…60 min]` — disabled when overtime periods is 0
- Editing format values doesn't trigger any data migration (interpreter re-runs on every read; existing start/stop events get re-interpreted under the new format). If the new cap is *less* than existing start/stop event count, the events list will simply show all events but the clock only consults the first `cap` chronologically — UI shows a banner: `"3 start/stop events exceed format capacity; delete or expand the format."` (single line, low-priority warning, not blocking).
- Cancel button on settings? No — there's no transactional commit. Field edits flow into `workspace.project.scoreboard` via a `@Bindable` proxy as the user types. `"Done"` is just "I'm finished editing; show me the match panel again."
- **Persistence.** Per-keystroke disk I/O is wrong; deferring to "next save from another path" can lose settings to a crash. Save fires on:
  - The `"Done"` button (also resets focus to flush any in-flight `TextField` edit before saving).
  - The settings sub-view's `.onDisappear` (safety net for mode-flip / navigate-away while a field still has focus — mirrors `ClipInspector.swift`'s focus-loss save pattern).
  - That's it. No save on every keystroke; no save on every Stepper tick (the in-memory write is enough for the live score line to update; `saveProject()` only needs to run when the user is finished editing).
- **Decision: settings edits are NOT undoable separately.** They're rare, one-time setup actions. Wrapping them in `editScoreboardConfig` snapshots would clutter the undo stack with typing noise. (Same reasoning the Codable settings sheet skipped undo today.)

### `MatchSetupSheet` deleted

The modal sheet, its `.sheet(...)` modifier in `ContentView`, and `ContentView.showMatchSetup` `@State` all go. The `@FocusedValue` bridge in `ClipCommands.swift` is **kept and renamed** (`openMatchSetup` → `openMatchSettings`); only the closure body changes. Specifically:

- In `ClipCommands.swift`: rename `OpenMatchSetupKey` → `OpenMatchSettingsKey`, accessor `openMatchSetup` → `openMatchSettings`, `ProjectCommands` button reads `openMatchSettings`. Wiring structure unchanged.
- In `ContentView`: replace `openMatchSetupHandler` with `openMatchSettingsHandler` whose closure body is `{ inspectorMode = .settings }` (capturing ContentView's own `@State` setter — same pattern as today's `showMatchSetup = true`). `.focusedValue(\.openMatchSettings, openMatchSettingsHandler)`.
- The inspector panel ships an `"Edit"` button in the events-mode header for click-driven access (writes through its `@Binding`).

### Keyboard wiring (replaces the current `KeyCommandView` event arm)

In `KeyCommandView.swift`:

**Remove:**
- `KeyCode.four`, `KeyCode.g`, `KeyCode.h` constants.
- `scoreboardConfigured: Bool` field, `onTagHalf`, `onTagGoal` closures, their `KeyCatchingView` mirrors, and `apply(to:)` propagation.
- The `KeyCode.four` arm of the `1`/`2`/`3`/`4` case (returns it to plain `1`/`2`/`3`).
- The `KeyCode.g`/`KeyCode.h` case entirely.
- The conditional inside `KeyCode.one`/`two`/`three` that branches on `scoreboardConfigured` — keys `1`/`2`/`3` go back to unconditional zoom controls.

**Add:**
- `KeyCode.e: UInt16 = 0x0E` (kVK_ANSI_E).
- New fields on the representable, matching the existing named-closure pattern (no enum, no dispatch switch):
  - `eventModeActive: Bool`
  - `onEnterEventMode: () -> Void`
  - `onExitEventMode: () -> Void`
  - `onTagHomeGoal: () -> Void`
  - `onTagAwayGoal: () -> Void`
  - `onTagStartStop: () -> Void`
- A new switch arm:
  ```swift
  case KeyCode.e:
      guard event.hasNoSignificantModifiers,
            self.appMode == .scanning || self.appMode == .recording,
            !self.eventModeActive else { return event }
      self.onEnterEventMode(); return nil
  ```
- And replace the `1`/`2`/`3` arm such that, **when `eventModeActive` is true**, those keys route to the event-tag closures instead of zoom:
  ```swift
  case KeyCode.one, KeyCode.two, KeyCode.three:
      guard event.hasNoSignificantModifiers else { return event }
      if self.eventModeActive {
          switch event.keyCode {
          case KeyCode.one:   self.onTagHomeGoal()
          case KeyCode.two:   self.onTagAwayGoal()
          case KeyCode.three: self.onTagStartStop()
          default:            return event
          }
          return nil
      }
      // Existing zoom logic (unchanged).
      …
  case KeyCode.escape:
      // Existing cascade; insert eventMode-active branch before the existing cases:
      if self.eventModeActive {
          self.onExitEventMode(); return nil
      }
      …
  ```

`ContentView` owns `eventModeActive: Bool` as `@State` (see "Two modes" above), passes it as a plain `Bool` to `KeyCommandView` (read-only) and as a `@Binding` to `MatchInspectorPanel` (the "Add Event" button toggles it). The five tag closures wire directly to `workspace` data mutators; the mode flip happens in ContentView, not Workspace:

```swift
onEnterEventMode: { eventModeActive = true },
onExitEventMode:  { eventModeActive = false },
onTagHomeGoal:    { workspace.tagEvent(.homeGoal); eventModeActive = false },
onTagAwayGoal:    { workspace.tagEvent(.awayGoal); eventModeActive = false },
onTagStartStop:   { workspace.tagStartStop();      eventModeActive = false },
```

`Workspace` gains exactly two data mutators (no UI methods):
```swift
@MainActor func tagEvent(_ kind: MatchEventKind)   // .homeGoal / .awayGoal → appendGoal via mutateMatchEvents
@MainActor func tagStartStop()                     // → appendStartStop via mutateMatchEvents
```

`Workspace.tagMatchEvent(_:)` (the old dispatcher) is removed; the two new methods replace it.

### State-ownership table

| Property | Owner | Type | Read by | Written by |
|---|---|---|---|---|
| `inspectorMode` | `ContentView` | `@State` | `MatchInspectorPanel` (via `@Binding`) | Panel's Edit/Done buttons (binding); menu's focused-value closure |
| `eventModeActive` | `ContentView` | `@State` | `KeyCommandView` (plain `Bool`); `MatchInspectorPanel` (binding for the overlay + greyed-out rest) | `handleTagEvent` switch in ContentView; panel's "Add Event" button (binding) |
| `tagEvent` / `tagStartStop` | `Workspace` | method | called only from ContentView's closures | — |

## 4. Persistence

- `Project.formatVersion`: 3 → 4. `ProjectStore.read` accepts `[1, 4]`. `Project.currentFormatVersion` constant updates.
- `Project.init(from:)`: v3 `matchEvents` records with named half-tag kinds rewrite to `.startStop` on decode (see Section 1). v3 `ScoreboardConfig` records without a `format` field but with `matchLengthSeconds` synthesize a `format` defaulting to 2 regulation periods of half the matchLength.
- `ProjectStore.write` continues to set `formatVersion = Project.currentFormatVersion` unconditionally.

## 5. Testing strategy

- **`MatchFormat` helper tests** — `expectedStartStopEvents`, `periodName(...)`, `isOvertime(...)`, `periodSeconds(...)` for soccer / 4-period / 1-period / 2+OT configurations.
- **`interpret(...)` unit tests** — empty input; one event; alternating start/stop; out-of-order; over-cap; format with regulation+overtime mix.
- **`scoreboardState` integration tests** (port from existing): pre-kickoff nil; period 0 running; period 0 stoppage; halftime (soccer); break (4-period); period 1 running through cumulative-time; FT after last period (soccer; soccer+OT; 4-period); goals counted in span; goals outside span ignored.
- **`Project.init(from:)` v3 → v4 migration test** — inline JSON with old `gameStart`/`firstHalfEnd`/etc. records and `matchLengthSeconds: 5400`; assert post-decode all `.startStop`, `format.regulationPeriods == 2`, `format.regulationPeriodSeconds == 2700`.
- **`Project.appendStartStop` cap test** — append 4 events with default soccer format; 5th is no-op.
- **Export pixel-anchor test** — keep the existing one; it doesn't probe format-dependent labels so still passes after the migration.
- **No UI snapshot tests** — UI tasks remain visual-only.

## 6. Non-goals (YAGNI)

- Per-period score deltas (e.g., "1H ARS 1–0 BUR" inset). Score is cumulative only.
- Auto-detection of period transitions (e.g., flagging that the user forgot to tag P1 end). Stays manual.
- Configurable display labels (e.g., "1H"/"2H" vs "P1"/"P2" vs custom). `periodName(_:)` rule is fixed.
- Stoppage cap. As today, stoppage time counts uncapped.
- Per-period stat tracking (possession, shots, etc.).
- Animation/transitions when the score changes.
- Undo for `ScoreboardConfig` field edits (settings mode writes through directly; setup is a one-time action; undo would clutter the stack with typing noise).
- Cancel button on settings mode (no transactional commit; `"Done"` just exits the mode).
- Multi-clip event tagging in one E-mode session (auto-exit after one event is by design).

## 7. Decisions log

| Decision | Chosen | Rejected | Why |
|---|---|---|---|
| Stored half-tag kind | Single `.startStop`, derive role on read | Encode role in kind via associated-value enum and re-label on write | Variable-arity format makes derive-on-read the honest model; format changes (rare but real) re-interpret existing data for free instead of needing a relabel-on-format-save pass |
| Period count + duration | Configurable via `MatchFormat` | Hardcoded soccer (current) | User explicitly asked for quarters / 1-period / OT support |
| OT period count + duration | Separate from regulation count + duration | One periods/duration with OT as just "more periods" | Real games have different period durations for OT (e.g., NBA: 12-min regulation, 5-min OT). Separate fields keep that natural |
| OT label scheme | `OT1` / `OT2` / … fixed | User-configurable | Adds config surface for negligible gain |
| Regulation label scheme | `1H`/`2H` when count == 2, else `P1`/`P2`/… | Always `P1`/`P2`/… | Soccer's "1H"/"2H" is iconic and the existing default; degrading to generic `P1`/`P2` for the most common case would feel like a regression |
| Inspector mode-swap vs sheet | In-panel mode-swap | Modal sheet (current) | User explicitly wants source-video interaction to stay live during settings edit |
| Event-add UX | Modal E-key + on-screen overlay | Always-visible 6-button grid (current) | User explicitly chose modal: smaller default footprint, one primary action |
| Auto-exit after event | Yes | Stay open until Esc | Predictable; one-shot modal feel; rapid-fire is `E,1,E,1` (six keys for three goals — acceptable) |
| Direct hotkeys for events | Removed | Keep as aliases | Single source of truth; releases `1`/`2`/`3` back to zoom controls; lowers accidental-tag risk |
| `formatClock` knows the format | No; `ClockDisplay` carries semantic enum cases | Pass format into `formatClock` | Keeps the formatter pure; semantic decisions land in `scoreboardState` where context already exists |
| Settings field edits | Through-binding writes; no transactional commit | `Cancel` / `Save` buttons with snapshot | Settings are one-time setup; transactional UI adds modal complexity without benefit |
| Settings field edits + undo | Not separately undoable | `editScoreboardConfig(before:after:)` UndoAction | Typing noise would dominate the undo stack |
| Over-cap interpretation | Drop events beyond `expectedStartStopEvents` at interpretation time | Persist all but visually mark extras | Cap is enforced at write too; over-cap data only arises from external edits or format shrink, both rare |
| Format-shrink UX | Show a "events exceed capacity" banner; don't auto-delete | Auto-delete extras | Surprising data loss; banner is a one-line warning the user can act on |
