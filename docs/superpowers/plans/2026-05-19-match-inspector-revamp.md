# Match Inspector Revamp Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generalize the scoreboard to support configurable match formats (regulation + OT periods of any count), collapse 4 half-tag kinds into one `.startStop` interpreted at read time, and replace the modal Match Setup sheet with an inline inspector mode-swap. Add a modal E-key event-add overlay with 3 hotkeys; remove the bare `1/2/3/4/G/H` event shortcuts.

**Architecture:** Pure data layer (`MatchFormat`, `.startStop` events, `interpret()` function) lands first as additive code with tests. Clock semantics rewrite uses the new types via `config.format` while keeping the old kind-based event lookup. New `Workspace` API (`tagEvent` / `tagStartStop`) lands alongside the old `tagMatchEvent`. UI rewrite (KeyCommandView + ContentView + ClipCommands + MatchInspectorPanel) is one atomic task — the intermediate half-migrated state isn't a usable checkpoint. Finally, the breaking kind reduction (drop 4 named half-tag cases; `scoreboardState` rewritten to walk `interpret()`) lands once nothing calls the old API.

**Tech Stack:** Swift, SwiftUI, AppKit (NSViewRepresentable + CALayer), AVFoundation, XCTest.

**Spec:** `docs/superpowers/specs/2026-05-19-match-inspector-revamp-design.md` — read it before starting.

**Codebase reference points:**

- `apple/VideoCoachCore/Sources/VideoCoachCore/Scoreboard.swift` — current data types + clock function
- `apple/VideoCoachCore/Sources/VideoCoachCore/Project.swift` — Project + custom init(from:) + currentFormatVersion (currently 3)
- `apple/VideoCoachCore/Sources/VideoCoachCore/ProjectStore.swift` — read guard + write
- `apple/VideoCoachCore/Sources/VideoCoachCore/CompilationInstruction.swift` — ScoreboardContext nested struct
- `apple/VideoCoachCore/Sources/VideoCoachCore/CompilationExporter.swift` — export signature; planner helper
- `apple/App/Models/Workspace.swift` — mutateMatchEvents, tagMatchEvent (to be removed), undo arms
- `apple/App/Views/Scoreboard/{MatchInspectorPanel, MatchSetupSheet, ScoreboardOverlayView, ScoreboardReplayOverlay}.swift`
- `apple/App/Views/KeyCommandView.swift` — keyboard wiring (E-mode lives here)
- `apple/App/Views/ClipCommands.swift` — OpenMatchSetupKey focused-value bridge (to be renamed)
- `apple/App/ContentView.swift` — showMatchSetup state + ZStack mounts
- `apple/App/VideoCoachApp.swift` — Scene-level .commands

**Test command (core):** `swift test --package-path apple/VideoCoachCore`
**Build command (app):** `cd apple && xcodegen generate && cd .. && xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build`

**Note for app-target files:** the `.xcodeproj` is gitignored and regenerated from `apple/project.yml`. After creating any new file under `apple/App/**`, run `xcodegen generate` before `xcodebuild`. Core package files are discovered by SwiftPM automatically.

---

## File map

### Create
- `apple/VideoCoachCore/Tests/VideoCoachCoreTests/MatchFormatTests.swift` — Task 1
- `apple/VideoCoachCore/Tests/VideoCoachCoreTests/InterpretTests.swift` — Task 2

### Modify
- `apple/VideoCoachCore/Sources/VideoCoachCore/Scoreboard.swift` — Tasks 1, 2, 3, 4, 5, 8
- `apple/VideoCoachCore/Sources/VideoCoachCore/Project.swift` — Tasks 5, 8
- `apple/VideoCoachCore/Sources/VideoCoachCore/ProjectStore.swift` — Task 8
- `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ScoreboardTests.swift` — Tasks 3, 4, 5, 8
- `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ProjectTests.swift` — Tasks 4, 8
- `apple/VideoCoachCore/Tests/VideoCoachCoreTests/CompilationExporterE2ETests.swift` — Task 8 (`.gameStart` → `.startStop`)
- `apple/VideoCoachCore/Tests/VideoCoachCoreTests/CompilationPlannerScoreboardTests.swift` — Task 8 (`setHalfTag(.gameStart)` → `appendStartStop`; assertion kind → `.startStop`)
- `apple/App/Models/Workspace.swift` — Tasks 5, 8
- `apple/App/Views/KeyCommandView.swift` — Task 6
- `apple/App/Views/ClipCommands.swift` — Task 6 (rename OpenMatchSetup → OpenMatchSettings)
- `apple/App/ContentView.swift` — Task 6 (state ownership rewrite, top-level `InspectorMode`, KeyCommandView wiring)
- `apple/App/Views/Scoreboard/MatchInspectorPanel.swift` — Task 6 (full rewrite)
- `apple/App/Views/Scoreboard/MatchSetupSheet.swift` — Task 4 (interim compile-fix), Task 7 (delete)

### Delete
- `apple/App/Views/Scoreboard/MatchSetupSheet.swift` — Task 7

---

## Task 1: `MatchFormat` type + helpers

Additive — no behavior change anywhere.

**Files:**
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/Scoreboard.swift` (append)
- Create: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/MatchFormatTests.swift`

- [ ] **Step 1: Write failing tests**

`apple/VideoCoachCore/Tests/VideoCoachCoreTests/MatchFormatTests.swift`:
```swift
import XCTest
@testable import VideoCoachCore

final class MatchFormatTests: XCTestCase {
    func test_defaults_soccer() {
        let f = MatchFormat()
        XCTAssertEqual(f.regulationPeriods, 2)
        XCTAssertEqual(f.regulationPeriodSeconds, 45 * 60)
        XCTAssertEqual(f.overtimePeriods, 0)
        XCTAssertEqual(f.totalPeriods, 2)
        XCTAssertEqual(f.expectedStartStopEvents, 4)
    }

    func test_soccer_periodSeconds() {
        let f = MatchFormat()
        XCTAssertEqual(f.periodSeconds(0), 2700)
        XCTAssertEqual(f.periodSeconds(1), 2700)
    }

    func test_quarters_basketball() {
        let f = MatchFormat(regulationPeriods: 4, regulationPeriodSeconds: 12 * 60)
        XCTAssertEqual(f.totalPeriods, 4)
        XCTAssertEqual(f.expectedStartStopEvents, 8)
        XCTAssertEqual(f.periodSeconds(2), 720)
    }

    func test_with_overtime() {
        let f = MatchFormat(regulationPeriods: 2, regulationPeriodSeconds: 45*60,
                            overtimePeriods: 1, overtimePeriodSeconds: 15*60)
        XCTAssertEqual(f.totalPeriods, 3)
        XCTAssertEqual(f.expectedStartStopEvents, 6)
        XCTAssertFalse(f.isOvertime(periodIndex: 0))
        XCTAssertFalse(f.isOvertime(periodIndex: 1))
        XCTAssertTrue(f.isOvertime(periodIndex: 2))
        XCTAssertEqual(f.periodSeconds(2), 900)
    }

    func test_periodName_soccer() {
        let f = MatchFormat()
        XCTAssertEqual(f.periodName(0), "1H")
        XCTAssertEqual(f.periodName(1), "2H")
    }

    func test_periodName_quarters() {
        let f = MatchFormat(regulationPeriods: 4, regulationPeriodSeconds: 12*60)
        XCTAssertEqual(f.periodName(0), "P1")
        XCTAssertEqual(f.periodName(3), "P4")
    }

    func test_periodName_singlePeriod() {
        let f = MatchFormat(regulationPeriods: 1, regulationPeriodSeconds: 60*60)
        XCTAssertEqual(f.periodName(0), "P1")
    }

    func test_periodName_overtime() {
        let f = MatchFormat(regulationPeriods: 2, regulationPeriodSeconds: 45*60,
                            overtimePeriods: 2, overtimePeriodSeconds: 15*60)
        XCTAssertEqual(f.periodName(2), "OT1")
        XCTAssertEqual(f.periodName(3), "OT2")
    }

    func test_breakLabel_soccer() {
        let f = MatchFormat()
        XCTAssertEqual(f.breakLabel(afterPeriodIndex: 0), "HT")
    }

    func test_breakLabel_quarters() {
        let f = MatchFormat(regulationPeriods: 4, regulationPeriodSeconds: 12*60)
        XCTAssertEqual(f.breakLabel(afterPeriodIndex: 0), "BREAK")
        XCTAssertEqual(f.breakLabel(afterPeriodIndex: 1), "BREAK")
        XCTAssertEqual(f.breakLabel(afterPeriodIndex: 2), "BREAK")
    }

    func test_codable_roundtrip() throws {
        let f = MatchFormat(regulationPeriods: 4, regulationPeriodSeconds: 720,
                            overtimePeriods: 1, overtimePeriodSeconds: 300)
        let data = try JSONEncoder().encode(f)
        let decoded = try JSONDecoder().decode(MatchFormat.self, from: data)
        XCTAssertEqual(decoded, f)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path apple/VideoCoachCore --filter MatchFormatTests`
Expected: FAIL — `MatchFormat` not defined.

- [ ] **Step 3: Add `MatchFormat` to `Scoreboard.swift`**

Append (above the existing `ScoreboardConfig` declaration so it's available as a default):

```swift
public struct MatchFormat: Codable, Hashable, Sendable {
    public var regulationPeriods: Int
    public var regulationPeriodSeconds: Int
    public var overtimePeriods: Int
    public var overtimePeriodSeconds: Int

    public init(
        regulationPeriods: Int = 2,
        regulationPeriodSeconds: Int = 45 * 60,
        overtimePeriods: Int = 0,
        overtimePeriodSeconds: Int = 15 * 60
    ) {
        self.regulationPeriods = regulationPeriods
        self.regulationPeriodSeconds = regulationPeriodSeconds
        self.overtimePeriods = overtimePeriods
        self.overtimePeriodSeconds = overtimePeriodSeconds
    }
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

    /// User-facing label for a period index. "1H"/"2H" for the soccer
    /// special case (regulationPeriods == 2); otherwise "P1"/"P2"/…;
    /// overtime always "OT1"/"OT2"/….
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
    /// "HT" for soccer's halftime; "BREAK" for every other inter-period gap.
    func breakLabel(afterPeriodIndex i: Int) -> String {
        regulationPeriods == 2 && i == 0 ? "HT" : "BREAK"
    }
}
```

- [ ] **Step 4: Run tests; verify all pass**

Run: `swift test --package-path apple/VideoCoachCore`
Expected: ALL PASS.

- [ ] **Step 5: Commit**

```bash
git add apple/VideoCoachCore/Sources/VideoCoachCore/Scoreboard.swift apple/VideoCoachCore/Tests/VideoCoachCoreTests/MatchFormatTests.swift
git commit -m "feat(core): MatchFormat value type + helpers"
```

---

## Task 2: `PeriodRole` + `InterpretedEvent` + `interpret(_:format:)`

Additive — no consumers yet.

**Files:**
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/Scoreboard.swift` (append)
- Create: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/InterpretTests.swift`

- [ ] **Step 1: Write failing tests**

`apple/VideoCoachCore/Tests/VideoCoachCoreTests/InterpretTests.swift`:
```swift
import XCTest
@testable import VideoCoachCore

final class InterpretTests: XCTestCase {
    // Tests use .gameStart as a placeholder kind because that's what currently
    // exists in MatchEventKind. The interpreter is kind-agnostic — it positions
    // by chronological order regardless of which discriminator it sees. Task 8
    // sweeps these to .startStop after the enum reduction.
    private func startStop(_ s: Double) -> AbsoluteMatchEvent {
        AbsoluteMatchEvent(absSeconds: s, kind: .gameStart)
    }

    func test_empty_input() {
        XCTAssertEqual(interpret([], format: MatchFormat()), [])
    }

    func test_one_event_soccer() {
        let result = interpret([startStop(10)], format: MatchFormat())
        XCTAssertEqual(result, [InterpretedEvent(absSeconds: 10, role: .start(periodIndex: 0))])
    }

    func test_alternating_soccer() {
        let events = [10, 100, 200, 300].map { startStop(Double($0)) }
        let result = interpret(events, format: MatchFormat())
        XCTAssertEqual(result, [
            .init(absSeconds: 10,  role: .start(periodIndex: 0)),
            .init(absSeconds: 100, role: .end(periodIndex: 0)),
            .init(absSeconds: 200, role: .start(periodIndex: 1)),
            .init(absSeconds: 300, role: .end(periodIndex: 1)),
        ])
    }

    func test_out_of_order_input_sorts_by_abs_time() {
        let events = [300, 10, 200, 100].map { startStop(Double($0)) }
        let result = interpret(events, format: MatchFormat())
        XCTAssertEqual(result.map { $0.absSeconds }, [10, 100, 200, 300])
        XCTAssertEqual(result.map { $0.role }, [
            .start(periodIndex: 0), .end(periodIndex: 0),
            .start(periodIndex: 1), .end(periodIndex: 1),
        ])
    }

    func test_over_cap_events_dropped() {
        let events = (1...5).map { startStop(Double($0 * 10)) }
        let result = interpret(events, format: MatchFormat())
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result.last?.absSeconds, 40)
    }

    func test_format_with_overtime() {
        let format = MatchFormat(regulationPeriods: 2, regulationPeriodSeconds: 45*60,
                                 overtimePeriods: 1, overtimePeriodSeconds: 15*60)
        let events = (1...6).map { startStop(Double($0 * 100)) }
        let result = interpret(events, format: format)
        XCTAssertEqual(result.count, 6)
        XCTAssertEqual(result.map { $0.role }, [
            .start(periodIndex: 0), .end(periodIndex: 0),
            .start(periodIndex: 1), .end(periodIndex: 1),
            .start(periodIndex: 2), .end(periodIndex: 2),
        ])
        XCTAssertTrue(format.isOvertime(periodIndex: 2))
    }

    func test_singlePeriod_format() {
        let format = MatchFormat(regulationPeriods: 1, regulationPeriodSeconds: 60*60)
        let events = [startStop(10), startStop(100)]
        let result = interpret(events, format: format)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].role, .start(periodIndex: 0))
        XCTAssertEqual(result[1].role, .end(periodIndex: 0))
    }

    func test_identical_timestamps_stable_order() {
        let events = [startStop(50), startStop(50), startStop(100)]
        let result = interpret(events, format: MatchFormat())
        XCTAssertEqual(result.map { $0.absSeconds }, [50, 50, 100])
        XCTAssertEqual(result.map { $0.role }, [
            .start(periodIndex: 0), .end(periodIndex: 0), .start(periodIndex: 1),
        ])
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path apple/VideoCoachCore --filter InterpretTests`
Expected: FAIL — `PeriodRole`, `InterpretedEvent`, `interpret` not defined.

- [ ] **Step 3: Add types + function to `Scoreboard.swift`**

Append:

```swift
public enum PeriodRole: Equatable, Hashable, Sendable {
    case start(periodIndex: Int)
    case end(periodIndex: Int)
}

public struct InterpretedEvent: Equatable, Hashable, Sendable {
    public let absSeconds: Double
    public let role: PeriodRole

    public init(absSeconds: Double, role: PeriodRole) {
        self.absSeconds = absSeconds
        self.role = role
    }
}

/// Pure interpreter. Sorts start/stop events ascending by absolute time, then
/// assigns positional roles: position 0 → .start(0), 1 → .end(0), 2 →
/// .start(1), 3 → .end(1), etc. The (i/2)-th period is started by even
/// indices and ended by odd indices. Events beyond
/// `format.expectedStartStopEvents` are dropped.
public func interpret(
    _ startStops: [AbsoluteMatchEvent],
    format: MatchFormat
) -> [InterpretedEvent] {
    let sorted = startStops.enumerated()
        .sorted { lhs, rhs in
            if lhs.element.absSeconds != rhs.element.absSeconds {
                return lhs.element.absSeconds < rhs.element.absSeconds
            }
            return lhs.offset < rhs.offset
        }
        .map { $0.element }

    let cap = format.expectedStartStopEvents
    let capped = sorted.prefix(cap)
    return capped.enumerated().map { (i, event) in
        let periodIndex = i / 2
        let role: PeriodRole = (i % 2 == 0) ? .start(periodIndex: periodIndex)
                                            : .end(periodIndex: periodIndex)
        return InterpretedEvent(absSeconds: event.absSeconds, role: role)
    }
}
```

- [ ] **Step 4: Run tests; verify all pass**

Run: `swift test --package-path apple/VideoCoachCore`
Expected: ALL PASS.

- [ ] **Step 5: Commit**

```bash
git add apple/VideoCoachCore/Sources/VideoCoachCore/Scoreboard.swift apple/VideoCoachCore/Tests/VideoCoachCoreTests/InterpretTests.swift
git commit -m "feat(core): PeriodRole + InterpretedEvent + interpret() pure function"
```

---

## Task 3: `ClockDisplay.onBreak` replaces `.halftime`

Atomic enum-case rename + emitter update. No new behavior — pure refactor. Single edit step (no red-step dance for a pure rename — the compiler enforces correctness).

**Files:**
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/Scoreboard.swift`
- Modify: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ScoreboardTests.swift`

- [ ] **Step 1: Atomic rename — source + tests in one edit**

**In `Scoreboard.swift`:**

Change `ClockDisplay`:
```swift
public enum ClockDisplay: Equatable, Sendable {
    case running(seconds: Double)
    case stoppage(baseSeconds: Double, plusSeconds: Double)
    case onBreak(label: String)   // e.g. "HT" for soccer halftime, "BREAK" for other inter-period gaps
    case fulltime
}
```

In `formatClock(_:)`, change:
```swift
case .halftime: return .init(main: "HT", trailing: "")
```
to:
```swift
case .onBreak(let label): return .init(main: label, trailing: "")
```

In `scoreboardState(absoluteTime:config:events:)`, change `clock = .halftime` to:
```swift
// "HT" is the only break this version of the clock can emit (always 2 halves).
// Task 8 generalizes via format.breakLabel(afterPeriodIndex:).
clock = .onBreak(label: "HT")
```

**In `ScoreboardTests.swift`:**

Grep for `.halftime`:
```
grep -- -n "\.halftime" apple/VideoCoachCore/Tests/VideoCoachCoreTests/ScoreboardTests.swift
```
Replace each occurrence with `.onBreak(label: "HT")`.

Update `test_halftime_fulltime` in `FormatClockTests`:
```swift
func test_halftime_fulltime() {
    XCTAssertEqual(formatClock(.onBreak(label: "HT")), ClockLabels(main: "HT", trailing: ""))
    XCTAssertEqual(formatClock(.onBreak(label: "BREAK")), ClockLabels(main: "BREAK", trailing: ""))
    XCTAssertEqual(formatClock(.fulltime), ClockLabels(main: "FT", trailing: ""))
}
```

- [ ] **Step 2: Run tests; verify all pass**

Run: `swift test --package-path apple/VideoCoachCore`
Expected: ALL PASS.

- [ ] **Step 3: Commit**

```bash
git add apple/VideoCoachCore/Sources/VideoCoachCore/Scoreboard.swift apple/VideoCoachCore/Tests/VideoCoachCoreTests/ScoreboardTests.swift
git commit -m "refactor(core): ClockDisplay.onBreak(label:) replaces .halftime"
```

---

## Task 4: `ScoreboardConfig.format` field with v3 back-compat decoder

Adds `format: MatchFormat` to `ScoreboardConfig`, removes `matchLengthSeconds`, adds custom `init(from:)` that synthesizes `format` from a v3 file's `matchLengthSeconds`. Updates `scoreboardState` to derive `halfLen` / `matchLen` from `config.format`. Patches the existing `MatchSetupSheet.swift` Stepper so the sheet keeps compiling until Task 7 deletes the file.

**Files:**
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/Scoreboard.swift`
- Modify: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ScoreboardTests.swift`
- Modify: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ProjectTests.swift`
- Modify: `apple/App/Views/Scoreboard/MatchSetupSheet.swift` (interim)

- [ ] **Step 1: Write failing tests for the back-compat decoder**

Append to `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ProjectTests.swift`:

```swift
    func test_scoreboardConfig_decodesV3_matchLengthSeconds_intoFormat() throws {
        let json = """
        {
          "home": {"name": "ARS", "primaryColor": {"r":1,"g":0,"b":0,"a":1}, "secondaryColor": {"r":1,"g":0,"b":0,"a":1}},
          "away": {"name": "BUR", "primaryColor": {"r":0,"g":0,"b":1,"a":1}, "secondaryColor": {"r":0,"g":0,"b":1,"a":1}},
          "stadium": "EMIRATES",
          "city": "LONDON",
          "matchLengthSeconds": 5400
        }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(ScoreboardConfig.self, from: json)
        XCTAssertEqual(cfg.format.regulationPeriods, 2)
        XCTAssertEqual(cfg.format.regulationPeriodSeconds, 2700)
        XCTAssertEqual(cfg.format.overtimePeriods, 0)
    }

    func test_scoreboardConfig_decodesV4_formatField() throws {
        let json = """
        {
          "home": {"name": "ARS", "primaryColor": {"r":1,"g":0,"b":0,"a":1}, "secondaryColor": {"r":1,"g":0,"b":0,"a":1}},
          "away": {"name": "BUR", "primaryColor": {"r":0,"g":0,"b":1,"a":1}, "secondaryColor": {"r":0,"g":0,"b":1,"a":1}},
          "stadium": "EMIRATES",
          "city": "LONDON",
          "format": {
            "regulationPeriods": 4,
            "regulationPeriodSeconds": 720,
            "overtimePeriods": 0,
            "overtimePeriodSeconds": 300
          }
        }
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(ScoreboardConfig.self, from: json)
        XCTAssertEqual(cfg.format.regulationPeriods, 4)
        XCTAssertEqual(cfg.format.regulationPeriodSeconds, 720)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path apple/VideoCoachCore --filter ProjectTests`
Expected: FAIL — `cfg.format` not a member.

- [ ] **Step 3: Replace `ScoreboardConfig` in `Scoreboard.swift`**

Replace the existing struct with:

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
            // v3 back-compat: split matchLengthSeconds into two equal regulation periods.
            self.format = MatchFormat(regulationPeriods: 2, regulationPeriodSeconds: mls / 2)
        } else {
            self.format = .init()
        }
    }
}
```

- [ ] **Step 4: Update `scoreboardState` to use `config.format`**

In `scoreboardState(absoluteTime:config:events:)`, change:
```swift
let halfLen = Double(config.matchLengthSeconds) / 2.0
let matchLen = Double(config.matchLengthSeconds)
```
to:
```swift
// This version still assumes the soccer 2-period model. Task 8 generalizes
// the loop to walk per-period via `config.format.periodSeconds(i)`.
let halfLen = Double(config.format.regulationPeriodSeconds)
let matchLen = Double(config.format.regulationPeriods * config.format.regulationPeriodSeconds)
```

- [ ] **Step 5: Update test fixtures** that construct `ScoreboardConfig` with `matchLengthSeconds`

In `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ScoreboardTests.swift`, the `cfg(matchLen:...)` helper:
```swift
private func cfg(matchLen: Int = 90 * 60, homeName: String = "H", awayName: String = "A") -> ScoreboardConfig {
    ScoreboardConfig(
        home: TeamConfig(name: homeName, primaryColor: .red, secondaryColor: .red),
        away: TeamConfig(name: awayName, primaryColor: .red, secondaryColor: .red),
        stadium: "S", city: "C",
        format: MatchFormat(regulationPeriods: 2, regulationPeriodSeconds: matchLen / 2)
    )
}
```

Other test files (`ScoreboardRenderTests.swift`, `CompilationExporterE2ETests.swift`, the existing `test_projectStore_v3RoundTripWithScoreboard` in `ProjectTests.swift`) construct `ScoreboardConfig` without `matchLengthSeconds`, so the default `format: .init()` applies — no change needed.

- [ ] **Step 6: Patch `MatchSetupSheet.swift` so it compiles** (file gets deleted in Task 7)

In `apple/App/Views/Scoreboard/MatchSetupSheet.swift`, find the Stepper that binds `matchLengthSeconds`:
```swift
Stepper(value: Binding(
    get: { working.matchLengthSeconds / 60 },
    set: { working.matchLengthSeconds = $0 * 60 }
), in: 1...180) {
    Text("\(working.matchLengthSeconds / 60) minutes")
}
```

Replace with a temporary single-period stepper (the sheet is dead-end UI now — Task 6's panel rewrite removes its mount, Task 7 deletes the file):
```swift
Stepper(value: Binding(
    get: { (working.format.regulationPeriods * working.format.regulationPeriodSeconds) / 60 },
    set: { newMin in
        working.format = MatchFormat(
            regulationPeriods: 2,
            regulationPeriodSeconds: (newMin * 60) / 2,
            overtimePeriods: 0,
            overtimePeriodSeconds: 15 * 60
        )
    }
), in: 1...180) {
    Text("\((working.format.regulationPeriods * working.format.regulationPeriodSeconds) / 60) minutes")
}
```

- [ ] **Step 7: Run full suite + build app**

Run: `swift test --package-path apple/VideoCoachCore`
Run: `cd apple && xcodegen generate && cd .. && xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build`
Expected: ALL PASS / BUILD SUCCEEDED.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(core): ScoreboardConfig.format with v3 matchLengthSeconds back-compat"
```

---

## Task 5: Parallel new Workspace API (additive)

Adds `Project.appendStartStop`, `Workspace.tagStartStop()`, `Workspace.tagEvent(_:)` alongside the existing methods. Adds `.startStop` to `MatchEventKind` (additive; old 4 cases stay until Task 8). Updates the existing `Workspace.tagMatchEvent` switch to handle `.startStop` so the build stays green.

**Files:**
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/Scoreboard.swift`
- Modify: `apple/App/Models/Workspace.swift`
- Modify: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ScoreboardTests.swift`

- [ ] **Step 1: Write failing tests for `appendStartStop`**

Append to `ScoreboardTests.swift`'s `ScoreboardMutatorTests` class:

```swift
    func test_appendStartStop_appendsRecord() {
        var p = Project(name: "x")
        p.scoreboard = ScoreboardConfig(
            home: TeamConfig(name: "H", primaryColor: .red, secondaryColor: .red),
            away: TeamConfig(name: "A", primaryColor: .red, secondaryColor: .red),
            stadium: "S", city: "C"
        )
        p.appendStartStop(sourceIndex: 0, sourceSeconds: 100)
        XCTAssertEqual(p.matchEvents.count, 1)
        XCTAssertEqual(p.matchEvents[0].kind, .startStop)
        XCTAssertEqual(p.matchEvents[0].sourceSeconds, 100)
    }

    func test_appendStartStop_respectsCap() {
        var p = Project(name: "x")
        p.scoreboard = ScoreboardConfig(
            home: TeamConfig(name: "H", primaryColor: .red, secondaryColor: .red),
            away: TeamConfig(name: "A", primaryColor: .red, secondaryColor: .red),
            stadium: "S", city: "C"
        )
        for i in 1...4 {
            p.appendStartStop(sourceIndex: 0, sourceSeconds: Double(i * 100))
        }
        XCTAssertEqual(p.matchEvents.count, 4)
        p.appendStartStop(sourceIndex: 0, sourceSeconds: 500)
        XCTAssertEqual(p.matchEvents.count, 4)
    }

    func test_appendStartStop_noOpsWhenScoreboardNil() {
        var p = Project(name: "x")
        p.appendStartStop(sourceIndex: 0, sourceSeconds: 100)
        XCTAssertEqual(p.matchEvents.count, 0)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path apple/VideoCoachCore --filter ScoreboardMutatorTests`
Expected: FAIL — `appendStartStop` not defined and/or `.startStop` not a case.

- [ ] **Step 3: Add `.startStop` to `MatchEventKind`** + update `displayName`

In `Scoreboard.swift`, change:
```swift
public enum MatchEventKind: String, Codable, Hashable, Sendable {
    case gameStart
    case firstHalfEnd
    case secondHalfBegin
    case gameEnd
    case homeGoal
    case awayGoal
}
```
to:
```swift
public enum MatchEventKind: String, Codable, Hashable, Sendable {
    case gameStart           // deprecated; removed in formatVersion 4
    case firstHalfEnd        // deprecated; removed in formatVersion 4
    case secondHalfBegin     // deprecated; removed in formatVersion 4
    case gameEnd             // deprecated; removed in formatVersion 4
    case startStop           // new positional half-tag (formatVersion 4+)
    case homeGoal
    case awayGoal
}
```

Update `displayName`:
```swift
public extension MatchEventKind {
    var displayName: String {
        switch self {
        case .gameStart:        return "1H Start"
        case .firstHalfEnd:     return "1H End"
        case .secondHalfBegin:  return "2H Start"
        case .gameEnd:          return "2H End"
        case .homeGoal:         return "Home Goal"
        case .awayGoal:         return "Away Goal"
        case .startStop:        return "Start/Stop"
        }
    }
}
```

- [ ] **Step 4: Add `Project.appendStartStop`**

Append to the existing `public extension Project` block (or add a new one):
```swift
public extension Project {
    /// Append a start/stop record. No-op if the configured format's
    /// `expectedStartStopEvents` cap is already reached, or if no scoreboard
    /// is configured.
    mutating func appendStartStop(sourceIndex: Int, sourceSeconds: Double) {
        guard let cap = scoreboard?.format.expectedStartStopEvents else { return }
        let count = matchEvents.lazy.filter({ $0.kind == .startStop }).count
        guard count < cap else { return }
        matchEvents.append(.init(kind: .startStop, sourceIndex: sourceIndex, sourceSeconds: sourceSeconds))
    }
}
```

- [ ] **Step 5: Update `Workspace.tagMatchEvent` switch to handle `.startStop`** (keeps the existing method exhaustive — it's deleted entirely in Task 8)

In `apple/App/Models/Workspace.swift`, find the existing `tagMatchEvent(_ kind:)` body. Add a case for `.startStop` to its switch (the method's purpose is unchanged; this is a compile-only fix until Task 8 removes the whole method):
```swift
func tagMatchEvent(_ kind: MatchEventKind) {
    guard let player = sourcePlayer else { return }
    let idx = player.playlistPos
    let sec = player.timePos
    mutateMatchEvents { p in
        switch kind {
        case .gameStart, .firstHalfEnd, .secondHalfBegin, .gameEnd:
            p.setHalfTag(kind, sourceIndex: idx, sourceSeconds: sec)
        case .homeGoal, .awayGoal:
            p.appendGoal(kind, sourceIndex: idx, sourceSeconds: sec)
        case .startStop:
            p.appendStartStop(sourceIndex: idx, sourceSeconds: sec)
        }
    }
}
```

- [ ] **Step 6: Add `Workspace.tagStartStop()` and `Workspace.tagEvent(_:)`**

Add alongside the existing `tagMatchEvent`:
```swift
/// Capture the source player's current `(playlistPos, timePos)` and append a
/// goal record of the given kind. Used by the new E-mode in
/// MatchInspectorPanel. No-op when no source player is loaded or when kind
/// isn't a goal.
@MainActor
func tagEvent(_ kind: MatchEventKind) {
    guard kind == .homeGoal || kind == .awayGoal else { return }
    guard let player = sourcePlayer else { return }
    let idx = player.playlistPos
    let sec = player.timePos
    mutateMatchEvents { p in
        p.appendGoal(kind, sourceIndex: idx, sourceSeconds: sec)
    }
}

/// Capture the source player's current `(playlistPos, timePos)` and append a
/// .startStop record. Used by the new E-mode for the smart half-tag flow.
@MainActor
func tagStartStop() {
    guard let player = sourcePlayer else { return }
    let idx = player.playlistPos
    let sec = player.timePos
    mutateMatchEvents { p in
        p.appendStartStop(sourceIndex: idx, sourceSeconds: sec)
    }
}
```

- [ ] **Step 7: Run tests + build**

Run: `swift test --package-path apple/VideoCoachCore`
Run: `xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build`
Expected: ALL PASS / BUILD SUCCEEDED.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(app): parallel Workspace API — tagStartStop + tagEvent (additive)"
```

---

## Task 6: Inspector UX migration (atomic — KeyCommandView + ContentView + ClipCommands + MatchInspectorPanel)

Single atomic task. Splitting this would leave the app in a half-migrated state where settings mode renders the events panel (no settings UI exists yet) and the menu silently does nothing visible. Coupled UX migration is one commit.

**Files:**
- Modify: `apple/App/Views/KeyCommandView.swift`
- Modify: `apple/App/Views/ClipCommands.swift`
- Modify: `apple/App/ContentView.swift`
- Modify: `apple/App/Views/Scoreboard/MatchInspectorPanel.swift` (full rewrite)

- [ ] **Step 1: Update `KeyCommandView.swift`** — remove old fields, add E-mode + 5 typed closures

**Remove from `KeyCommandView` (the representable struct):**
```swift
let scoreboardConfigured: Bool
let onTagHalf: (MatchEventKind) -> Void
let onTagGoal: (MatchEventKind) -> Void
```

**Add:**
```swift
let eventModeActive: Bool
let onEnterEventMode: () -> Void
let onExitEventMode: () -> Void
let onTagHomeGoal: () -> Void
let onTagAwayGoal: () -> Void
let onTagStartStop: () -> Void
```

**Mirror on `KeyCatchingView`:** remove the three removed `var` properties; add:
```swift
var eventModeActive: Bool = false
var onEnterEventMode: () -> Void = {}
var onExitEventMode: () -> Void = {}
var onTagHomeGoal: () -> Void = {}
var onTagAwayGoal: () -> Void = {}
var onTagStartStop: () -> Void = {}
```

**Update `apply(to:)`:** delete the three removed assignments; add:
```swift
v.eventModeActive = eventModeActive
v.onEnterEventMode = onEnterEventMode
v.onExitEventMode = onExitEventMode
v.onTagHomeGoal = onTagHomeGoal
v.onTagAwayGoal = onTagAwayGoal
v.onTagStartStop = onTagStartStop
```

**Remove these key code constants:**
```swift
static let four: UInt16 = 0x15
static let g: UInt16 = 0x05
static let h: UInt16 = 0x04
```

**Add:**
```swift
static let e: UInt16 = 0x0E   // kVK_ANSI_E
```

**Replace the existing `case KeyCode.one, KeyCode.two, KeyCode.three, KeyCode.four:` arm** with:
```swift
case KeyCode.one, KeyCode.two, KeyCode.three:
    guard event.hasNoSignificantModifiers else { return event }
    switch self.appMode {
    case .scanning, .recording:
        if self.eventModeActive {
            switch event.keyCode {
            case KeyCode.one:   self.onTagHomeGoal()
            case KeyCode.two:   self.onTagAwayGoal()
            case KeyCode.three: self.onTagStartStop()
            default:            return event
            }
            return nil
        }
        let target: Double
        switch event.keyCode {
        case KeyCode.one:   target = 1.0
        case KeyCode.two:   target = self.currentZoomScale - zoomKeyStep
        case KeyCode.three: target = self.currentZoomScale + zoomKeyStep
        default:            return event
        }
        let cursor = self.cursorInPlayerView() ?? CGPoint(x: 0.5, y: 0.5)
        self.onZoomLevel(target, cursor)
        return nil
    default:
        return event
    }
```

**Remove the `case KeyCode.g, KeyCode.h:` arm entirely.**

**Add a new `case KeyCode.e:` arm** before `default:`:
```swift
case KeyCode.e:
    guard event.hasNoSignificantModifiers,
          self.appMode == .scanning || self.appMode == .recording,
          !self.eventModeActive else { return event }
    self.onEnterEventMode(); return nil
```

**Extend the `KeyCode.escape` arm.** Insert at the top of its body (before the existing `switch self.appMode`):
```swift
case KeyCode.escape:
    if self.eventModeActive {
        self.onExitEventMode(); return nil
    }
    // existing cascade follows (stop recording → close preview → clear tag filter → fall through)
    switch self.appMode { ... }
```

(Esc-while-(recording + E-mode) exits E-mode first, then a second Esc stops recording. Consistent with the file's documented "one layer per Esc press" cascade.)

- [ ] **Step 2: Rename in `ClipCommands.swift`** — `OpenMatchSetup` → `OpenMatchSettings`

```swift
private struct OpenMatchSettingsKey: FocusedValueKey {
    typealias Value = () -> Void
}
extension FocusedValues {
    var openMatchSettings: (() -> Void)? {
        get { self[OpenMatchSettingsKey.self] }
        set { self[OpenMatchSettingsKey.self] = newValue }
    }
}

// ProjectCommands stays structurally the same:
struct ProjectCommands: Commands {
    @FocusedValue(\.openMatchSettings) private var openMatchSettings

    var body: some Commands {
        CommandMenu("Project") {
            Button("Match Setup…") { openMatchSettings?() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(openMatchSettings == nil)
        }
    }
}
```

- [ ] **Step 3: Replace `MatchInspectorPanel.swift` body entirely**

Replace the file's full contents with:

```swift
import SwiftUI
import AppKit
import VideoCoachCore

struct MatchInspectorPanel: View {
    @Bindable var workspace: Workspace
    @Binding var mode: InspectorMode
    @Binding var eventModeActive: Bool

    var body: some View {
        switch mode {
        case .events:   eventsModeView
        case .settings: settingsModeView
        }
    }

    // MARK: - Events mode

    private var eventsModeView: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(title: "MATCH", trailing: AnyView(
                Button("Edit") { mode = .settings }
                    .controlSize(.small)
            ))
            if workspace.project.scoreboard == nil {
                Button("Setup Teams…") { mode = .settings }
            } else {
                liveScoreLine
            }
            Divider()
            Button(action: { eventModeActive.toggle() }) {
                Text("Add Event  E").frame(maxWidth: .infinity)
            }
            .disabled(workspace.project.scoreboard == nil)
            .controlSize(.large)
            if eventModeActive { eventPickerOverlay }
            Divider()
            eventsList
        }
        .padding(8)
    }

    private var liveScoreLine: some View {
        let cfg = workspace.project.scoreboard!
        return HStack {
            if let s = currentState() {
                Text("\(s.home.name) \(s.homeScore) – \(s.awayScore) \(s.away.name)")
                Spacer()
                Text(formatClock(s.clock).main).monospacedDigit()
            } else {
                Text("\(cfg.home.name) – \(cfg.away.name)")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private var eventPickerOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: {
                workspace.tagEvent(.homeGoal); eventModeActive = false
            }) {
                Text("1  Home Goal").frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: {
                workspace.tagEvent(.awayGoal); eventModeActive = false
            }) {
                Text("2  Away Goal").frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: {
                workspace.tagStartStop(); eventModeActive = false
            }) {
                Text("3  Start/Stop").frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(startStopAtCap)
            if startStopAtCap {
                Text("Game tagged. Delete a start/stop event to add another.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private var startStopAtCap: Bool {
        guard let f = workspace.project.scoreboard?.format else { return false }
        let count = workspace.project.matchEvents.lazy.filter { $0.kind == .startStop }.count
        return count >= f.expectedStartStopEvents
    }

    private var eventsList: some View {
        VStack(alignment: .leading) {
            Text("Events").font(.caption).foregroundStyle(.secondary)
            ForEach(sortedEvents()) { rec in
                HStack {
                    Text(timestamp(for: rec)).monospacedDigit().font(.caption2)
                    Text(roleLabel(for: rec)).font(.caption)
                    Spacer()
                    Button { seek(to: rec) } label: { Image(systemName: "arrow.right.circle") }
                        .buttonStyle(.borderless)
                    Button {
                        workspace.mutateMatchEvents { p in
                            p.matchEvents.removeAll { $0.id == rec.id }
                        }
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: - Settings mode

    private var settingsModeView: some View {
        let cfg = Binding(
            get: {
                workspace.project.scoreboard ?? ScoreboardConfig(
                    home: TeamConfig(name: "", primaryColor: RGBA(r: 0.5, g: 0.5, b: 0.5, a: 1),
                                     secondaryColor: RGBA(r: 0.5, g: 0.5, b: 0.5, a: 1)),
                    away: TeamConfig(name: "", primaryColor: RGBA(r: 0.5, g: 0.5, b: 0.5, a: 1),
                                     secondaryColor: RGBA(r: 0.5, g: 0.5, b: 0.5, a: 1)),
                    stadium: "", city: ""
                )
            },
            set: { workspace.project.scoreboard = $0 }
        )
        return VStack(alignment: .leading, spacing: 8) {
            header(title: "MATCH SETTINGS", trailing: AnyView(
                Button("Done") {
                    mode = .events
                    try? workspace.saveProject()
                }
                .controlSize(.small)
            ))
            Form {
                Section("Home Team") {
                    TextField("Name", text: cfg.home.name)
                    ColorPickerCell(label: "Primary", color: cfg.home.primaryColor)
                    ColorPickerCell(label: "Secondary", color: cfg.home.secondaryColor)
                }
                Section("Away Team") {
                    TextField("Name", text: cfg.away.name)
                    ColorPickerCell(label: "Primary", color: cfg.away.primaryColor)
                    ColorPickerCell(label: "Secondary", color: cfg.away.secondaryColor)
                }
                Section("Venue") {
                    TextField("Stadium", text: cfg.stadium)
                    TextField("City", text: cfg.city)
                }
                Section("Format") {
                    Stepper("Regulation periods: \(cfg.wrappedValue.format.regulationPeriods)",
                            value: cfg.format.regulationPeriods, in: 1...10)
                    Stepper("Period length: \(cfg.wrappedValue.format.regulationPeriodSeconds / 60) min",
                            value: Binding(
                                get: { cfg.wrappedValue.format.regulationPeriodSeconds / 60 },
                                set: { cfg.wrappedValue.format.regulationPeriodSeconds = $0 * 60 }
                            ), in: 1...180)
                    Stepper("Overtime periods: \(cfg.wrappedValue.format.overtimePeriods)",
                            value: cfg.format.overtimePeriods, in: 0...10)
                    Stepper("OT period length: \(cfg.wrappedValue.format.overtimePeriodSeconds / 60) min",
                            value: Binding(
                                get: { cfg.wrappedValue.format.overtimePeriodSeconds / 60 },
                                set: { cfg.wrappedValue.format.overtimePeriodSeconds = $0 * 60 }
                            ), in: 1...60)
                        .disabled(cfg.wrappedValue.format.overtimePeriods == 0)
                }
                if overcapacityCount > 0 {
                    Section {
                        Text("\(overcapacityCount) start/stop events exceed format capacity; delete or expand the format.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .padding(8)
        .onDisappear { try? workspace.saveProject() }
    }

    private var overcapacityCount: Int {
        guard let f = workspace.project.scoreboard?.format else { return 0 }
        let count = workspace.project.matchEvents.lazy.filter { $0.kind == .startStop }.count
        return max(0, count - f.expectedStartStopEvents)
    }

    // MARK: - Helpers

    private func header(title: String, trailing: AnyView) -> some View {
        HStack {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            Spacer()
            trailing
        }
    }

    private func currentState() -> ScoreboardState? {
        guard let player = workspace.sourcePlayer else { return nil }
        return scoreboardState(
            atSourceIndex: player.playlistPos,
            sourceSeconds: player.timePos,
            project: workspace.project)
    }

    private func seek(to rec: MatchEventRecord) {
        workspace.sourcePlayer?.seek(
            playlistPos: rec.sourceIndex,
            timeSeconds: rec.sourceSeconds,
            exact: true,
            completion: {})
    }

    private func sortedEvents() -> [MatchEventRecord] {
        workspace.project.matchEvents.sorted { lhs, rhs in
            let l = workspace.project.cumulativeOffset(forSourceIndex: lhs.sourceIndex) + lhs.sourceSeconds
            let r = workspace.project.cumulativeOffset(forSourceIndex: rhs.sourceIndex) + rhs.sourceSeconds
            return l < r
        }
    }

    private func timestamp(for rec: MatchEventRecord) -> String {
        let abs = workspace.project.cumulativeOffset(forSourceIndex: rec.sourceIndex) + rec.sourceSeconds
        let total = Int(abs)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// Role label for a record. Goals render their kind's `displayName`.
    /// Start/stop records derive a positional role via `interpret(...)`.
    /// During the interim (Tasks 5–7) the enum still has the four deprecated
    /// half-tag cases; they're all treated as start/stop for labelling
    /// purposes via `isStartStopKind`. Task 8 reduces the enum and simplifies
    /// this method accordingly.
    ///
    /// Position-based lookup: both the sorted start-stop subset and `interpret()`
    /// sort by ascending absSeconds using stable sort, so the rec's index in
    /// the sorted subset is its index into `interp`. Avoids fragile
    /// float-epsilon matching that would mis-resolve simultaneous start/stops.
    private func roleLabel(for rec: MatchEventRecord) -> String {
        switch rec.kind {
        case .homeGoal, .awayGoal:
            return rec.kind.displayName
        case .startStop, .gameStart, .firstHalfEnd, .secondHalfBegin, .gameEnd:
            guard let f = workspace.project.scoreboard?.format else { return "Start/Stop" }
            let sortedStartStops = workspace.project.matchEvents
                .filter { isStartStopKind($0.kind) }
                .sorted { lhs, rhs in
                    let l = workspace.project.cumulativeOffset(forSourceIndex: lhs.sourceIndex) + lhs.sourceSeconds
                    let r = workspace.project.cumulativeOffset(forSourceIndex: rhs.sourceIndex) + rhs.sourceSeconds
                    return l < r
                }
            let absEvents = sortedStartStops.map { e in
                AbsoluteMatchEvent(
                    absSeconds: workspace.project.cumulativeOffset(forSourceIndex: e.sourceIndex) + e.sourceSeconds,
                    kind: .startStop
                )
            }
            let interp = interpret(absEvents, format: f)
            guard let pos = sortedStartStops.firstIndex(where: { $0.id == rec.id }),
                  pos < interp.count else { return "Start/Stop" }
            switch interp[pos].role {
            case .start(let i): return "\(f.periodName(i)) Start"
            case .end(let i):   return "\(f.periodName(i)) End"
            }
        }
    }

    private func isStartStopKind(_ k: MatchEventKind) -> Bool {
        switch k {
        case .startStop, .gameStart, .firstHalfEnd, .secondHalfBegin, .gameEnd: return true
        case .homeGoal, .awayGoal: return false
        }
    }
}

private struct ColorPickerCell: View {
    let label: String
    @Binding var color: RGBA
    var body: some View {
        HStack {
            Text(label).font(.caption)
            Spacer()
            ColorPicker("", selection: Binding(
                get: { Color(red: color.r, green: color.g, blue: color.b, opacity: color.a) },
                set: { newColor in
                    let ns = NSColor(newColor).usingColorSpace(.deviceRGB) ?? .gray
                    color = RGBA(r: Double(ns.redComponent),
                                 g: Double(ns.greenComponent),
                                 b: Double(ns.blueComponent),
                                 a: Double(ns.alphaComponent))
                }
            ), supportsOpacity: false)
        }
    }
}
```

- [ ] **Step 4: Update `ContentView.swift`** — state ownership, top-level `InspectorMode`, wire bindings + closures

Add a top-level `enum InspectorMode` (above `ContentView` or alongside its declaration):
```swift
enum InspectorMode { case events, settings }
```

In `ContentView`, find:
```swift
@State private var showMatchSetup: Bool = false
```
Replace with:
```swift
@State private var inspectorMode: InspectorMode = .events
@State private var eventModeActive: Bool = false
```

Delete the `.sheet(isPresented: $showMatchSetup) { MatchSetupSheet(workspace: workspace) }` modifier.

Rename the focused-value publisher: `openMatchSetupHandler` → `openMatchSettingsHandler`:
```swift
private var openMatchSettingsHandler: (() -> Void)? {
    guard workspace.folder != nil else { return nil }
    return { inspectorMode = .settings }
}
```
Update the `.focusedValue` modifier:
```swift
.focusedValue(\.openMatchSettings, openMatchSettingsHandler)
```

At the `KeyCommandView(...)` construction site, **remove** the three old arguments:
```swift
scoreboardConfigured: workspace.project.scoreboard != nil,
onTagHalf: { workspace.tagMatchEvent($0) },
onTagGoal: { workspace.tagMatchEvent($0) },
```

**Add** the new arguments (inline closures — no enum/switch indirection):
```swift
eventModeActive: eventModeActive,
onEnterEventMode: { eventModeActive = true },
onExitEventMode:  { eventModeActive = false },
onTagHomeGoal:    { workspace.tagEvent(.homeGoal); eventModeActive = false },
onTagAwayGoal:    { workspace.tagEvent(.awayGoal); eventModeActive = false },
onTagStartStop:   { workspace.tagStartStop();      eventModeActive = false },
```

At the `MatchInspectorPanel(...)` call site, replace:
```swift
MatchInspectorPanel(workspace: workspace, openSetup: { showMatchSetup = true })
```
with:
```swift
MatchInspectorPanel(
    workspace: workspace,
    mode: $inspectorMode,
    eventModeActive: $eventModeActive
)
```

- [ ] **Step 5: Verify `Workspace.saveProject()` is callable from the panel.** Check access level:
```
grep -- -n "saveProject" apple/App/Models/Workspace.swift
```
If `private`, change to `internal`. (The panel's `Done` button calls `try? workspace.saveProject()`.)

- [ ] **Step 6: Regenerate xcodeproj + build**

```bash
cd apple && xcodegen generate && cd ..
xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build
```
Expected: BUILD SUCCEEDED.

If something still references `showMatchSetup`, `openMatchSetup`, or `openSetup`, grep and fix:
```
grep -rn "showMatchSetup\|openMatchSetup\b\|openSetup\b" apple/
```
Expected: zero hits after fixes.

- [ ] **Step 7: Manual smoke test**

Launch app with a project open:
1. Inspector shows MATCH header with Edit button → click Edit → settings appear inline.
2. Edit a team name; click Done → returns to events mode; live score line shows new team name.
3. Press `E` → "Add Event" panel expands with 3 buttons.
4. Press `1` → home goal added; panel collapses.
5. Press `E` then `Esc` → exits without committing.
6. `⇧⌘M` → flips inspector to settings mode.
7. Without scoreboard configured (fresh project): press `1`/`2`/`3` → zoom still works; press `G`/`H` → no-op (no bare-event behavior).

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(app): inspector E-mode + two-mode panel + KeyCommandView rewire"
```

---

## Task 7: Delete `MatchSetupSheet`

The modal sheet is no longer mounted (Task 6 removed the `.sheet` modifier) and no longer needed (Task 6's settings sub-view absorbs the form). Delete.

**Files:**
- Delete: `apple/App/Views/Scoreboard/MatchSetupSheet.swift`

- [ ] **Step 1: Delete the file**

```bash
rm apple/App/Views/Scoreboard/MatchSetupSheet.swift
```

- [ ] **Step 2: Regenerate xcodeproj**

```bash
cd apple && xcodegen generate && cd ..
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED. Grep to confirm:
```
grep -rn "MatchSetupSheet" apple/
```
Expected: zero hits.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(app): delete MatchSetupSheet (replaced by inline settings sub-view)"
```

---

## Task 8: `MatchEventKind` reduction + `scoreboardState` rewrite + persistence migration

The big one. Removes the four deprecated half-tag kinds, rewrites `scoreboardState` to walk `interpret()` for per-period clock state (so multi-period formats actually work), migrates v3 records on decode via a custom `MatchEventKind.init(from:)`, bumps `formatVersion` to 4, ports all tests.

**Files:**
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/Scoreboard.swift` (kind reduction + scoreboardState rewrite + MatchEventKind.init(from:))
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/Project.swift` (currentFormatVersion → 4)
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/ProjectStore.swift` (read guard widens)
- Modify: `apple/App/Models/Workspace.swift` (remove `tagMatchEvent`)
- Modify: `apple/App/Views/Scoreboard/MatchInspectorPanel.swift` (simplify roleLabel / drop isStartStopKind)
- Modify: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ScoreboardTests.swift` (rewrite tests using `.startStop`)
- Modify: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ProjectTests.swift` (add v3→v4 test; update format-version assertion)
- Modify: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/CompilationExporterE2ETests.swift` (rewrite `.gameStart` → `.startStop`)
- Modify: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/CompilationPlannerScoreboardTests.swift` (rewrite `setHalfTag(.gameStart)` → `appendStartStop`; assertion kind → `.startStop`)

- [ ] **Step 1: Rewrite `scoreboardState(absoluteTime:config:events:)` in `Scoreboard.swift`**

Replace the entire function body with the per-period walk:

```swift
public func scoreboardState(
    absoluteTime now: Double,
    config: ScoreboardConfig,
    events: [AbsoluteMatchEvent]
) -> ScoreboardState? {
    guard !config.home.name.isEmpty, !config.away.name.isEmpty else { return nil }

    let startStops = events.filter { $0.kind == .startStop }
    let goals = events.filter { $0.kind == .homeGoal || $0.kind == .awayGoal }

    let interp = interpret(startStops, format: config.format)

    guard let firstStart = interp.first(where: {
        if case .start(let i) = $0.role, i == 0 { return true } else { return false }
    }) else { return nil }
    guard now >= firstStart.absSeconds else { return nil }

    // Highest-indexed .start with absSeconds <= now is the "current period".
    var currentIndex: Int? = nil
    var currentStartAbs: Double = 0
    for ev in interp {
        if case .start(let i) = ev.role, ev.absSeconds <= now {
            currentIndex = i
            currentStartAbs = ev.absSeconds
        }
    }
    let curIdx = currentIndex!

    let curEnd = interp.first(where: {
        if case .end(let i) = $0.role, i == curIdx { return true } else { return false }
    })

    let cumulativePriorPeriods: Double = (0..<curIdx).reduce(0) { $0 + config.format.periodSeconds($1) }
    let clock: ClockDisplay
    if let end = curEnd, now >= end.absSeconds {
        let isLastExpected = (curIdx == config.format.totalPeriods - 1)
        if isLastExpected {
            clock = .fulltime
        } else {
            clock = .onBreak(label: config.format.breakLabel(afterPeriodIndex: curIdx))
        }
    } else {
        let elapsedInPeriod = now - currentStartAbs
        let perSec = config.format.periodSeconds(curIdx)
        let displayedSeconds = cumulativePriorPeriods + elapsedInPeriod
        if elapsedInPeriod <= perSec {
            clock = .running(seconds: displayedSeconds)
        } else {
            clock = .stoppage(
                baseSeconds: cumulativePriorPeriods + perSec,
                plusSeconds: elapsedInPeriod - perSec
            )
        }
    }

    // Score window: lastEndAbs depends on role of last interp event.
    let lastEndAbs: Double
    if interp.count == config.format.expectedStartStopEvents,
       let last = interp.last, case .end(_) = last.role {
        lastEndAbs = last.absSeconds
    } else {
        lastEndAbs = .infinity
    }

    func countGoals(_ kind: MatchEventKind) -> Int {
        goals.reduce(into: 0) { acc, e in
            guard e.kind == kind,
                  e.absSeconds <= now,
                  e.absSeconds >= firstStart.absSeconds,
                  e.absSeconds <= lastEndAbs else { return }
            acc += 1
        }
    }

    return ScoreboardState(
        home: config.home, away: config.away,
        stadium: config.stadium, city: config.city,
        homeScore: countGoals(.homeGoal),
        awayScore: countGoals(.awayGoal),
        clock: clock
    )
}
```

- [ ] **Step 2: Reduce `MatchEventKind` to 3 cases**

Replace the 7-case enum with:
```swift
public enum MatchEventKind: String, Codable, Hashable, Sendable {
    case startStop
    case homeGoal
    case awayGoal
}
```

Update `displayName`:
```swift
public extension MatchEventKind {
    var displayName: String {
        switch self {
        case .homeGoal:  return "Home Goal"
        case .awayGoal:  return "Away Goal"
        case .startStop: return "Start/Stop"
        }
    }
}
```

- [ ] **Step 3: Add custom `MatchEventKind.init(from:)`** for v3 raw-string migration

Add right after the enum:
```swift
public extension MatchEventKind {
    /// Custom decoder migrates v3 raw values (gameStart/firstHalfEnd/
    /// secondHalfBegin/gameEnd) to .startStop. v4+ raw values decode normally.
    /// Encoder is synthesized — only v4 raw values ever round-trip back to disk.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "homeGoal":  self = .homeGoal
        case "awayGoal":  self = .awayGoal
        case "startStop",
             "gameStart", "firstHalfEnd", "secondHalfBegin", "gameEnd":
            self = .startStop
        default:
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown MatchEventKind raw value: \(raw)")
        }
    }
}
```

`Project.init(from:)`'s existing line `self.matchEvents = try c.decodeIfPresent([MatchEventRecord].self, forKey: .matchEvents) ?? []` keeps working unchanged — the v3 migration happens transparently per-record via this custom kind decoder. No `RawMatchEventRecord` struct needed.

- [ ] **Step 4: Remove `Project.setHalfTag` from `Scoreboard.swift`**

Find and delete the `mutating func setHalfTag(_ kind: MatchEventKind, ...)` method (no longer called by anyone — `tagMatchEvent` is also removed in Step 6 below).

- [ ] **Step 5: Bump `Project.currentFormatVersion` to 4** and widen `ProjectStore.read` guard

In `Project.swift`:
```swift
static let currentFormatVersion: Int = 4
```

In `ProjectStore.swift`, the guard already references `Project.currentFormatVersion`. Update the comment block:
```swift
// Accept v1 (legacy), v2 (.zoom event variant), v3 (scoreboard + matchEvents),
// v4 (.startStop migration; MatchFormat replaces matchLengthSeconds). Upper
// bound is `Project.currentFormatVersion` — bump there to widen this guard.
if project.formatVersion < 1 || project.formatVersion > Project.currentFormatVersion {
    throw ProjectStoreError.unsupportedFormatVersion(project.formatVersion)
}
```

- [ ] **Step 6: Remove `Workspace.tagMatchEvent` from `Workspace.swift`**

Find and delete the entire method (the new `tagEvent` + `tagStartStop` added in Task 5 replace it; the panel rewrite in Task 6 stopped calling it).

- [ ] **Step 7: Simplify `MatchInspectorPanel.roleLabel`** — old kinds gone, no `isStartStopKind` needed

```swift
private func roleLabel(for rec: MatchEventRecord) -> String {
    switch rec.kind {
    case .homeGoal, .awayGoal:
        return rec.kind.displayName
    case .startStop:
        guard let f = workspace.project.scoreboard?.format else { return "Start/Stop" }
        let sortedStartStops = workspace.project.matchEvents
            .filter { $0.kind == .startStop }
            .sorted { lhs, rhs in
                let l = workspace.project.cumulativeOffset(forSourceIndex: lhs.sourceIndex) + lhs.sourceSeconds
                let r = workspace.project.cumulativeOffset(forSourceIndex: rhs.sourceIndex) + rhs.sourceSeconds
                return l < r
            }
        let absEvents = sortedStartStops.map { e in
            AbsoluteMatchEvent(
                absSeconds: workspace.project.cumulativeOffset(forSourceIndex: e.sourceIndex) + e.sourceSeconds,
                kind: .startStop
            )
        }
        let interp = interpret(absEvents, format: f)
        guard let pos = sortedStartStops.firstIndex(where: { $0.id == rec.id }),
              pos < interp.count else { return "Start/Stop" }
        switch interp[pos].role {
        case .start(let i): return "\(f.periodName(i)) Start"
        case .end(let i):   return "\(f.periodName(i)) End"
        }
    }
}
```

Delete the `isStartStopKind` helper entirely.

- [ ] **Step 8: Rewrite tests to use `.startStop`**

**`InterpretTests.swift`** — change the helper:
```swift
private func startStop(_ s: Double) -> AbsoluteMatchEvent {
    AbsoluteMatchEvent(absSeconds: s, kind: .startStop)
}
```

**`ScoreboardTests.swift`** — sweep:
- `evt(.gameStart, at: …)` → `evt(.startStop, at: …)`
- `evt(.firstHalfEnd, at: …)` → `evt(.startStop, at: …)`
- `evt(.secondHalfBegin, at: …)` → `evt(.startStop, at: …)`
- `evt(.gameEnd, at: …)` → `evt(.startStop, at: …)`

Look for direct call-site references (not via the helper):
```
grep -- -n "gameStart\|firstHalfEnd\|secondHalfBegin\|gameEnd\|setHalfTag" apple/VideoCoachCore/Tests/VideoCoachCoreTests/ScoreboardTests.swift
```
For each hit:
- `p.setHalfTag(.gameStart, …)` → `p.appendStartStop(…)`. Note: `appendStartStop` no-ops without a scoreboard, so any test calling it needs to configure `p.scoreboard` first. Drop calls in tests where the scoreboard is intentionally nil (e.g., `test_projectWrapper_nilWhenScoreboardMissing` — the matchEvents state doesn't matter; the test just asserts `scoreboardState(...)` returns nil).
- Old kinds inside `[evt(.firstHalfEnd, …), evt(.gameStart, …)]` literals (e.g., `test_outOfOrderTags_doNotCrash`) → all become `.startStop`. The interpreter sorts by `absSeconds` so the test's intent (verifying out-of-order doesn't crash) is preserved.
- Assertions referencing `.halftime` were already updated in Task 3 to `.onBreak(label: "HT")`. Verify by grep.

Delete the two old `setHalfTag` tests in `ScoreboardMutatorTests` (the `test_setHalfTagReplacesExisting` etc., if they exist) — `setHalfTag` is gone. The `appendStartStop` tests added in Task 5 cover the new chokepoint.

Add new tests for multi-period formats:
```swift
func test_quarters_betweenQ1AndQ2_showsBreak() {
    let format = MatchFormat(regulationPeriods: 4, regulationPeriodSeconds: 12*60)
    let config = ScoreboardConfig(
        home: TeamConfig(name: "H", primaryColor: .red, secondaryColor: .red),
        away: TeamConfig(name: "A", primaryColor: .red, secondaryColor: .red),
        stadium: "S", city: "C", format: format
    )
    let events = [
        AbsoluteMatchEvent(absSeconds: 0,    kind: .startStop),  // Q1 start
        AbsoluteMatchEvent(absSeconds: 720,  kind: .startStop),  // Q1 end
    ]
    let s = scoreboardState(absoluteTime: 750, config: config, events: events)
    XCTAssertEqual(s?.clock, .onBreak(label: "BREAK"))
}

func test_quarters_fulltimeAfterQ4End() {
    let format = MatchFormat(regulationPeriods: 4, regulationPeriodSeconds: 720)
    let config = ScoreboardConfig(
        home: TeamConfig(name: "H", primaryColor: .red, secondaryColor: .red),
        away: TeamConfig(name: "A", primaryColor: .red, secondaryColor: .red),
        stadium: "S", city: "C", format: format
    )
    let events: [AbsoluteMatchEvent] = (0..<8).map { i in
        AbsoluteMatchEvent(absSeconds: Double(i) * 1000, kind: .startStop)
    }
    let s = scoreboardState(absoluteTime: 8000, config: config, events: events)
    XCTAssertEqual(s?.clock, .fulltime)
}
```

Final grep to confirm clean:
```
grep -- -n "gameStart\|firstHalfEnd\|secondHalfBegin\|gameEnd\|setHalfTag" apple/VideoCoachCore/Tests/VideoCoachCoreTests/ScoreboardTests.swift
```
Expected: zero hits.

**`CompilationExporterE2ETests.swift`** — find `kind: .gameStart` and replace with `kind: .startStop`:
```swift
let events: [MatchEventRecord] = [
    .init(kind: .startStop, sourceIndex: 0, sourceSeconds: 0.0)
]
```

**`CompilationPlannerScoreboardTests.swift`** — `test_matchEventsAbs_mapsThroughCumulativeOffset` currently calls `p.setHalfTag(.gameStart, …)` and asserts `AbsoluteMatchEvent(absSeconds: 10, kind: .gameStart)`. Rewrite:
```swift
p.scoreboard = ScoreboardConfig(
    home: TeamConfig(name: "H", primaryColor: .red, secondaryColor: .red),
    away: TeamConfig(name: "A", primaryColor: .red, secondaryColor: .red),
    stadium: "S", city: "C"
)  // appendStartStop no-ops without a scoreboard
p.appendStartStop(sourceIndex: 0, sourceSeconds: 10)
```
And update the assertion:
```swift
XCTAssertEqual(abs[0], AbsoluteMatchEvent(absSeconds: 10, kind: .startStop))
```

- [ ] **Step 9: Add v3 → v4 migration test to `ProjectTests.swift`**

```swift
func test_v3JSON_matchEventsMigrateToStartStop() throws {
    let json = """
    {
      "formatVersion": 3,
      "name": "v3 fixture",
      "sourceVideos": [],
      "clips": [],
      "preferences": {
        "scanVolume": 1, "previewSourceVolume": 1, "previewCommentaryVolume": 1,
        "lastExportResolution": "r1080", "lastExportQuality": "medium"
      },
      "scoreboard": {
        "home": {"name":"ARS","primaryColor":{"r":1,"g":0,"b":0,"a":1},"secondaryColor":{"r":1,"g":0,"b":0,"a":1}},
        "away": {"name":"BUR","primaryColor":{"r":0,"g":0,"b":1,"a":1},"secondaryColor":{"r":0,"g":0,"b":1,"a":1}},
        "stadium":"EMIRATES","city":"LONDON",
        "matchLengthSeconds": 5400
      },
      "matchEvents": [
        {"id":"\(UUID().uuidString)","kind":"gameStart","sourceIndex":0,"sourceSeconds":1.0},
        {"id":"\(UUID().uuidString)","kind":"firstHalfEnd","sourceIndex":0,"sourceSeconds":2700.0},
        {"id":"\(UUID().uuidString)","kind":"secondHalfBegin","sourceIndex":0,"sourceSeconds":2800.0},
        {"id":"\(UUID().uuidString)","kind":"gameEnd","sourceIndex":0,"sourceSeconds":5500.0},
        {"id":"\(UUID().uuidString)","kind":"homeGoal","sourceIndex":0,"sourceSeconds":1500.0}
      ]
    }
    """.data(using: .utf8)!
    let p = try JSONDecoder().decode(Project.self, from: json)
    XCTAssertEqual(p.matchEvents.count, 5)
    XCTAssertEqual(p.matchEvents.filter { $0.kind == .startStop }.count, 4)
    XCTAssertEqual(p.matchEvents.filter { $0.kind == .homeGoal }.count, 1)
    XCTAssertEqual(p.scoreboard?.format.regulationPeriods, 2)
    XCTAssertEqual(p.scoreboard?.format.regulationPeriodSeconds, 2700)
    XCTAssertEqual(p.scoreboard?.format.overtimePeriods, 0)
}
```

- [ ] **Step 10: Update `formatVersion` assertions in `ProjectTests.swift`**

Find every assertion of `formatVersion == 3` and update to `== 4`:
```
grep -- -n "formatVersion, 3\|formatVersion == 3" apple/VideoCoachCore/Tests/VideoCoachCoreTests/ProjectTests.swift
```
Update each.

- [ ] **Step 11: Run full core suite + build app**

Run: `swift test --package-path apple/VideoCoachCore`
Run: `cd apple && xcodegen generate && cd .. && xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build`
Expected: ALL PASS / BUILD SUCCEEDED.

Final grep:
```
grep -rn "gameStart\|firstHalfEnd\|secondHalfBegin\|gameEnd\|setHalfTag\|tagMatchEvent" apple/
```
Expected: zero hits outside the `MatchEventKind.init(from:)` raw-string match list and the v3-fixture inline JSON in the migration test.

- [ ] **Step 12: Commit**

```bash
git add -A
git commit -m "feat(core): MatchEventKind reduced to 3 + scoreboardState walks interpret() + v3→v4 migration"
```

---

## Task 9: End-to-end sanity sweep

- [ ] **Step 1: Run the full test suite**

Run: `swift test --package-path apple/VideoCoachCore`
Expected: ALL PASS.

- [ ] **Step 2: Build**

Run: `cd apple && xcodegen generate && cd .. && xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED, no new warnings.

- [ ] **Step 3: Manual smoke test**

Launch the freshly built app. Verify all of:

1. **Existing v3 project loads cleanly.** Open any pre-existing project; verify scoreboard config + match events still work; format defaulted to 2 × 45-min soccer.
2. **Inspector mode-swap.** `Project → Match Setup…` (or click "Edit") flips inspector to settings mode. Edit a team name; click "Done"; verify live score line reflects the change.
3. **Format edit.** In settings mode, change Regulation periods 2 → 4; Period length 45 → 12 min; click Done. Verify labels use "P1"/"P2"/etc instead of "1H"/"2H".
4. **E-mode keyboard flow.** With scoreboard configured: press `E` → "Add Event" panel expands. Press `1` → home goal added; panel collapses. Press `E`, `2` → away goal. Press `E`, `3` → start/stop. Verify each event appears in the events list with the right derived role label.
5. **E-mode mouse flow.** Click "Add Event"; click "Home Goal" button in the overlay; same result.
6. **Esc exits E-mode.** Press `E`, then `Esc` → no event added, panel collapses.
7. **Esc during recording + E-mode requires two presses.** Start recording; press `E`; press `Esc` → exits E-mode (still recording). Press `Esc` again → stops recording. Consistent with the existing "one layer per Esc press" cascade.
8. **Cap enforcement.** With default soccer (cap 4), tag 4 start/stop events; verify Start/Stop button in the overlay disabled with helper text. `E,3` is also a no-op.
9. **Zoom keys still work without scoreboard.** Fresh project (no scoreboard): press `1`/`2`/`3` → zoom; no event-add behavior.
10. **Bare `G`/`H` no longer fire events.** With scoreboard configured but NOT in E-mode, press `G` → nothing (no event added).
11. **Undo works.** After tagging a few events, Cmd+Z reverses one at a time.
12. **Export.** Export a clip; verify scoreboard burns into the .mp4 with the configured format.
13. **Persistence.** Close + reopen the project; verify all settings + events persist and the on-disk `formatVersion` is 4.

- [ ] **Step 4: If anything regresses, debug and fix.** Otherwise summarize delivered work.

---

## Notes for the implementer

- **The `.xcodeproj` is gitignored.** Always run `xcodegen generate` after creating new App-target files. SwiftPM core files are auto-discovered.
- **The interpreter is the only place that knows about positional roles.** Don't sprinkle "is this the gameStart event?" logic anywhere — call `interpret()` and pattern-match on `PeriodRole`.
- **Migration is decode-time, not save-time.** v3 records get rewritten to `.startStop` at decode via the custom `MatchEventKind.init(from:)`; the next `ProjectStore.write` lands a v4 file.
- **Workspace stays project-data only.** No UI-mode methods on it. The `inspectorMode` and `eventModeActive` flags live on `ContentView` as `@State` (Option A from the spec's decision log).
- **`InspectorMode` is a top-level enum** in `ContentView.swift`, not nested inside the panel. ContentView owns the state; the panel is the consumer.
- **No `TagAction` enum / `handleTagAction` switch.** Wire the 5 KeyCommandView closures inline at the call site — matches the codebase's existing many-named-closures pattern.
- **`roleLabel` uses position-based lookup, not float-epsilon match.** Both `sortedEvents()`-style sort and `interpret()` use stable sort on the same input, so array indices align by construction.
