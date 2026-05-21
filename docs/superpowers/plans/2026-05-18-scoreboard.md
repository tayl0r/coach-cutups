# Virtual Scoreboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a PL-broadcast-style scoreboard overlay that renders in all four contexts (source scan, clip recording, clip preview, HEVC export), driven by 6 match-event tags placed on the source-video timeline.

**Architecture:** Pure clock-from-tags computation in `VideoCoachCore`; single CG drawing function called from one compositor (export) and three AppKit overlay views (scan/record/preview). Preview path uses an AppKit overlay (StrokeReplayLayer pattern) — *not* `PreviewCompositor`, which is stripped by AVPlayer on macOS 26.

**Tech Stack:** Swift, SwiftUI, AppKit (NSViewRepresentable + CALayer), CoreText, AVFoundation, XCTest.

**Spec:** `docs/superpowers/specs/2026-05-18-scoreboard-design.md` — read it before starting.

**Codebase reference points:**

- `apple/VideoCoachCore/Sources/VideoCoachCore/Project.swift` — data model (existing `Project`, `Clip`; reuse existing `RGBA` in `Stroke.swift`)
- `apple/VideoCoachCore/Sources/VideoCoachCore/ProjectStore.swift` — JSON load/save with `formatVersion` guard
- `apple/VideoCoachCore/Sources/VideoCoachCore/CompilationCompositor.swift:309` — `drawTextBar` reference pattern; we extend Stage-2 here
- `apple/VideoCoachCore/Sources/VideoCoachCore/CompilationInstruction.swift` — instruction subclass we extend
- `apple/VideoCoachCore/Sources/VideoCoachCore/CompilationExporter.swift:297-342` — the `export(...)` Step-2 loop where we populate scoreboard fields
- `apple/App/Export/ExportSheet.swift:610-625` — the existing `exporter.export(...)` call site that we extend
- `apple/VideoCoachCore/Sources/VideoCoachCore/UndoController.swift` — `UndoAction` enum we extend
- `apple/VideoCoachCore/Sources/VideoCoachCore/PlaybackTimeline.swift` — `Clip.sourceTime(atRecordTime:)` is the canonical record→source mapper
- `apple/App/Preview/StrokeReplayLayer.swift` — pattern for the preview overlay (uses `AVPlayer.addPeriodicTimeObserver`; treats composition time as record time 1:1 because freezes are baked via `scaleTimeRange`)
- `apple/App/Preview/ClipPreviewBuilder.swift:184-187, 253-262` — composition build with built-in compositor (custom-compositor strip on macOS 26)
- `apple/App/Source/MPVSourcePlayer.swift:31-67, 445-451, 505` — `@MainActor @Observable`; `seek(playlistPos:timeSeconds:exact:completion:)`
- `apple/App/Views/KeyCommandView.swift` — existing window-level `NSEvent.addLocalMonitorForEvents` for keyboard shortcuts (already gates on text-field focus; we extend it)
- `apple/App/Models/Workspace.swift` — central app state
- `apple/App/ContentView.swift:289-299, 339-357, 458-473` — preview ZStack, `KeyCommandView` construction site, `previewTextBar`
- `apple/VideoCoachCore/Tests/VideoCoachCoreTests/Helpers/{FiducialAsset,PixelSampling}.swift` — pixel-test helpers (`averageRGB(in:normalizedRect:)` takes NORMALIZED [0,1] coords)
- `apple/VideoCoachCore/Tests/VideoCoachCoreTests/CompilationExporterE2ETests.swift:273` — `runExport(clip:)` existing helper pattern

**Test command (core):** `swift test --package-path apple/VideoCoachCore --filter <pattern>`
**Build command (app):** `xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build`

> **Before `xcodebuild` after creating a new App-target source file:** run
> `xcodegen generate --spec apple/project.yml`. The `.xcodeproj` is gitignored
> and regenerated from `apple/project.yml`; new files in `apple/App/**` won't
> be picked up by `xcodebuild` until `xcodegen` re-scans the `sources: [App]`
> tree. Core-package files (`apple/VideoCoachCore/**`) don't need this —
> SwiftPM picks them up automatically.

---

## File map

### Create
- `apple/VideoCoachCore/Sources/VideoCoachCore/Scoreboard.swift` — types + `Project` extensions + `formatClock` + `scoreboardState`
- `apple/VideoCoachCore/Sources/VideoCoachCore/Overlays/Scoreboard.swift` — `drawScoreboard(into:size:state:)`
- `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ScoreboardTests.swift` — types + mutators + clock + state + format tests
- `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ScoreboardRenderTests.swift` — smoke render
- `apple/VideoCoachCore/Tests/VideoCoachCoreTests/CompilationPlannerScoreboardTests.swift` — planner precompute unit test
- `apple/App/Views/Scoreboard/ScoreboardOverlayView.swift` — NSViewRepresentable for scan/record
- `apple/App/Views/Scoreboard/ScoreboardReplayOverlay.swift` — NSViewRepresentable for preview
- `apple/App/Views/Scoreboard/MatchInspectorPanel.swift` — Match panel UI
- `apple/App/Views/Scoreboard/MatchSetupSheet.swift` — team config sheet

### Modify
- `apple/VideoCoachCore/Sources/VideoCoachCore/Project.swift` — add `scoreboard`/`matchEvents` fields; `Project.currentFormatVersion` constant
- `apple/VideoCoachCore/Sources/VideoCoachCore/ProjectStore.swift` — widen read guard; write bumps via `Project.currentFormatVersion`
- `apple/VideoCoachCore/Sources/VideoCoachCore/UndoController.swift` — add `editMatchEvents` case
- `apple/VideoCoachCore/Sources/VideoCoachCore/CompilationInstruction.swift` — add three scoreboard fields to `make(...)`
- `apple/VideoCoachCore/Sources/VideoCoachCore/CompilationCompositor.swift` — draw scoreboard in Stage-2
- `apple/VideoCoachCore/Sources/VideoCoachCore/CompilationExporter.swift` — add static `clipStartAbsSeconds(for:sourceCumulativeOffsets:)` helper; extend `export(...)` signature
- `apple/App/Export/ExportSheet.swift` — precompute scoreboard inputs once per export, pass through
- `apple/App/Models/Workspace.swift` — `mutateMatchEvents`, `tagMatchEvent`, undo/redo arms
- `apple/App/Views/KeyCommandView.swift` — add `four`/`g`/`h` key codes; route tagging when scoreboard configured
- `apple/App/ContentView.swift` — sheet, menu, panel, ZStack mounts, KeyCommandView wiring
- `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ProjectTests.swift` — update v2→v3 assertion + add format-version migration tests
- `apple/VideoCoachCore/Tests/VideoCoachCoreTests/CompilationExporterE2ETests.swift` — extend `runExport(clip:)` helper with optional `scoreboard`/`matchEvents`; add export pixel-anchor test

---

## Task 1: Data model — types, `Project` fields, mutators, `currentFormatVersion`

**Files:**
- Create: `apple/VideoCoachCore/Sources/VideoCoachCore/Scoreboard.swift`
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/Project.swift`
- Modify: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ProjectTests.swift`
- Create: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ScoreboardTests.swift`

- [ ] **Step 1: Write failing behavior tests** (skip tautology tests for literal defaults — those add no coverage beyond what the compiler enforces)

`apple/VideoCoachCore/Tests/VideoCoachCoreTests/ScoreboardTests.swift`:
```swift
import XCTest
@testable import VideoCoachCore

final class ScoreboardMutatorTests: XCTestCase {
    func test_setHalfTag_appendsNewRecord() {
        var p = Project(name: "x")
        p.setHalfTag(.gameStart, sourceIndex: 0, sourceSeconds: 10)
        XCTAssertEqual(p.matchEvents.count, 1)
        XCTAssertEqual(p.matchEvents[0].kind, .gameStart)
        XCTAssertEqual(p.matchEvents[0].sourceSeconds, 10)
    }

    func test_setHalfTag_replacesInPlacePreservingId() {
        var p = Project(name: "x")
        p.setHalfTag(.gameStart, sourceIndex: 0, sourceSeconds: 10)
        let firstID = p.matchEvents[0].id
        p.setHalfTag(.gameStart, sourceIndex: 0, sourceSeconds: 20)
        XCTAssertEqual(p.matchEvents.count, 1)
        XCTAssertEqual(p.matchEvents[0].sourceSeconds, 20)
        XCTAssertEqual(p.matchEvents[0].id, firstID, "id must be preserved across half-tag replace")
    }

    func test_appendGoal_appendsEachTime() {
        var p = Project(name: "x")
        p.appendGoal(.homeGoal, sourceIndex: 0, sourceSeconds: 100)
        p.appendGoal(.homeGoal, sourceIndex: 0, sourceSeconds: 200)
        XCTAssertEqual(p.matchEvents.count, 2)
        XCTAssertNotEqual(p.matchEvents[0].id, p.matchEvents[1].id)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path apple/VideoCoachCore --filter ScoreboardMutatorTests`
Expected: FAIL — types and methods not defined.

- [ ] **Step 3: Create `Scoreboard.swift` with types + Project extension**

```swift
import Foundation

// Reuses RGBA from Stroke.swift (public struct RGBA: Codable, Hashable, Sendable).

public struct TeamConfig: Codable, Hashable, Sendable {
    public var name: String
    public var primaryColor: RGBA
    public var secondaryColor: RGBA

    public init(name: String, primaryColor: RGBA, secondaryColor: RGBA) {
        self.name = name
        self.primaryColor = primaryColor
        self.secondaryColor = secondaryColor
    }
}

public struct ScoreboardConfig: Codable, Hashable, Sendable {
    public var home: TeamConfig
    public var away: TeamConfig
    public var stadium: String
    public var city: String
    public var matchLengthSeconds: Int

    public init(home: TeamConfig, away: TeamConfig, stadium: String, city: String, matchLengthSeconds: Int = 90 * 60) {
        self.home = home
        self.away = away
        self.stadium = stadium
        self.city = city
        self.matchLengthSeconds = matchLengthSeconds
    }
}

public enum MatchEventKind: String, Codable, Hashable, Sendable {
    case gameStart
    case firstHalfEnd
    case secondHalfBegin
    case gameEnd
    case homeGoal
    case awayGoal
}

public extension MatchEventKind {
    var isHalfTag: Bool {
        switch self {
        case .gameStart, .firstHalfEnd, .secondHalfBegin, .gameEnd: return true
        case .homeGoal, .awayGoal: return false
        }
    }
}

public struct MatchEventRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: MatchEventKind
    public var sourceIndex: Int
    public var sourceSeconds: Double

    public init(id: UUID = UUID(), kind: MatchEventKind, sourceIndex: Int, sourceSeconds: Double) {
        self.id = id
        self.kind = kind
        self.sourceIndex = sourceIndex
        self.sourceSeconds = sourceSeconds
    }
}

public struct AbsoluteMatchEvent: Equatable, Hashable, Sendable {
    public let absSeconds: Double
    public let kind: MatchEventKind

    public init(absSeconds: Double, kind: MatchEventKind) {
        self.absSeconds = absSeconds
        self.kind = kind
    }
}

public extension Project {
    /// Replace any existing record of this half-kind in place (preserving the
    /// existing `id` for undo + SwiftUI ForEach stability); otherwise append.
    mutating func setHalfTag(_ kind: MatchEventKind, sourceIndex: Int, sourceSeconds: Double) {
        precondition(kind.isHalfTag, "setHalfTag requires a half-tag kind")
        if let i = matchEvents.firstIndex(where: { $0.kind == kind }) {
            matchEvents[i].sourceIndex = sourceIndex
            matchEvents[i].sourceSeconds = sourceSeconds
        } else {
            matchEvents.append(.init(kind: kind, sourceIndex: sourceIndex, sourceSeconds: sourceSeconds))
        }
    }

    mutating func appendGoal(_ kind: MatchEventKind, sourceIndex: Int, sourceSeconds: Double) {
        precondition(kind == .homeGoal || kind == .awayGoal, "appendGoal requires a goal kind")
        matchEvents.append(.init(kind: kind, sourceIndex: sourceIndex, sourceSeconds: sourceSeconds))
    }
}
```

- [ ] **Step 4: Modify `Project.swift` — add `currentFormatVersion`, scoreboard/matchEvents fields, bump default**

Change the struct from:
```swift
public struct Project: Codable, Hashable, Sendable {
    public var formatVersion: Int = 2  // bumped from 1 for .zoom event variant
    public var name: String
    public var sourceVideos: [SourceRef] = []
    public var clips: [Clip] = []
    public var preferences: Preferences = .init()
    public init(name: String) { self.name = name }
}
```
to:
```swift
public struct Project: Codable, Hashable, Sendable {
    /// Bumped to 3 for `scoreboard` + `matchEvents` (additive, optional fields).
    /// To bump again, update `Project.currentFormatVersion` and the read-guard
    /// upper bound in `ProjectStore.read` — one source of truth.
    public var formatVersion: Int = Project.currentFormatVersion
    public var name: String
    public var sourceVideos: [SourceRef] = []
    public var clips: [Clip] = []
    public var preferences: Preferences = .init()
    public var scoreboard: ScoreboardConfig? = nil
    public var matchEvents: [MatchEventRecord] = []
    public init(name: String) { self.name = name }
}

public extension Project {
    static let currentFormatVersion: Int = 3
}
```

- [ ] **Step 5: Proactively update `test_emptyProjectRoundtripsThroughJSON` in `ProjectTests.swift`**

The existing test at `ProjectTests.swift:17` asserts `XCTAssertEqual(decoded.formatVersion, 2)`. Its purpose is a freshness check on the default, not a contract about v2. Change to:
```swift
XCTAssertEqual(decoded.formatVersion, 3)
```

Do NOT touch `test_preferencesDeviceIDs_decodeFromLegacyJSONMissingKeys` — its `"formatVersion": 1` inline literal is the legacy-decode back-compat contract.

- [ ] **Step 6: Run tests**

Run: `swift test --package-path apple/VideoCoachCore`
Expected: ALL PASS.

- [ ] **Step 7: Commit**

```bash
git add apple/VideoCoachCore/Sources/VideoCoachCore/Scoreboard.swift apple/VideoCoachCore/Sources/VideoCoachCore/Project.swift apple/VideoCoachCore/Tests/VideoCoachCoreTests/ScoreboardTests.swift apple/VideoCoachCore/Tests/VideoCoachCoreTests/ProjectTests.swift
git commit -m "feat(core): scoreboard data types + Project fields + currentFormatVersion"
```

---

## Task 2: `ClockDisplay`, `formatClock`, `scoreboardState` + project wrapper

**Files:**
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/Scoreboard.swift`
- Modify: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ScoreboardTests.swift`

- [ ] **Step 1: Append failing tests**

```swift
final class FormatClockTests: XCTestCase {
    func test_running_zero() { XCTAssertEqual(formatClock(.running(seconds: 0)), ClockLabels(main: "00:00", trailing: "")) }
    func test_running_padding() {
        XCTAssertEqual(formatClock(.running(seconds: 5)), ClockLabels(main: "00:05", trailing: ""))
        XCTAssertEqual(formatClock(.running(seconds: 125)), ClockLabels(main: "02:05", trailing: ""))
    }
    func test_running_drops_fractions() {
        XCTAssertEqual(formatClock(.running(seconds: 125.9)), ClockLabels(main: "02:05", trailing: ""))
    }
    func test_stoppage() {
        XCTAssertEqual(formatClock(.stoppage(baseSeconds: 2700, plusSeconds: 47)),
                       ClockLabels(main: "45:00", trailing: "+0:47"))
        XCTAssertEqual(formatClock(.stoppage(baseSeconds: 5400, plusSeconds: 305)),
                       ClockLabels(main: "90:00", trailing: "+5:05"))
    }
    func test_halftime_fulltime() {
        XCTAssertEqual(formatClock(.halftime), ClockLabels(main: "HT", trailing: ""))
        XCTAssertEqual(formatClock(.fulltime), ClockLabels(main: "FT", trailing: ""))
    }
}

final class ScoreboardStateTests: XCTestCase {
    private func cfg(matchLen: Int = 90 * 60, homeName: String = "H", awayName: String = "A") -> ScoreboardConfig {
        ScoreboardConfig(
            home: TeamConfig(name: homeName, primaryColor: .red, secondaryColor: .red),
            away: TeamConfig(name: awayName, primaryColor: .red, secondaryColor: .red),
            stadium: "S", city: "C", matchLengthSeconds: matchLen)
    }
    private func evt(_ kind: MatchEventKind, at: Double) -> AbsoluteMatchEvent { .init(absSeconds: at, kind: kind) }

    // Nil cases
    func test_nil_whenNoGameStart() { XCTAssertNil(scoreboardState(absoluteTime: 100, config: cfg(), events: [])) }
    func test_nil_whenHomeNameEmpty() { XCTAssertNil(scoreboardState(absoluteTime: 100, config: cfg(homeName: ""), events: [evt(.gameStart, at: 0)])) }
    func test_nil_whenAwayNameEmpty() { XCTAssertNil(scoreboardState(absoluteTime: 100, config: cfg(awayName: ""), events: [evt(.gameStart, at: 0)])) }
    func test_nil_whenNowBeforeGameStart() { XCTAssertNil(scoreboardState(absoluteTime: 5, config: cfg(), events: [evt(.gameStart, at: 10)])) }

    // Clock branches
    func test_firstHalfRunning() {
        XCTAssertEqual(scoreboardState(absoluteTime: 100, config: cfg(), events: [evt(.gameStart, at: 0)])?.clock, .running(seconds: 100))
    }
    func test_firstHalfStoppage() {
        XCTAssertEqual(scoreboardState(absoluteTime: 2750, config: cfg(), events: [evt(.gameStart, at: 0)])?.clock,
                       .stoppage(baseSeconds: 2700, plusSeconds: 50))
    }
    func test_halftime() {
        XCTAssertEqual(scoreboardState(absoluteTime: 2800, config: cfg(),
            events: [evt(.gameStart, at: 0), evt(.firstHalfEnd, at: 2750)])?.clock, .halftime)
    }
    func test_secondHalfRunning() {
        XCTAssertEqual(scoreboardState(absoluteTime: 3000, config: cfg(),
            events: [evt(.gameStart, at: 0), evt(.firstHalfEnd, at: 2750), evt(.secondHalfBegin, at: 2900)])?.clock,
            .running(seconds: 2800))
    }
    func test_secondHalfStoppage() {
        XCTAssertEqual(scoreboardState(absoluteTime: 5650, config: cfg(),
            events: [evt(.gameStart, at: 0), evt(.firstHalfEnd, at: 2750), evt(.secondHalfBegin, at: 2900)])?.clock,
            .stoppage(baseSeconds: 5400, plusSeconds: 50))
    }
    func test_fulltime() {
        XCTAssertEqual(scoreboardState(absoluteTime: 6000, config: cfg(),
            events: [evt(.gameStart, at: 0), evt(.firstHalfEnd, at: 2750),
                     evt(.secondHalfBegin, at: 2900), evt(.gameEnd, at: 5800)])?.clock, .fulltime)
    }

    // Missing-tag fallback (spec §2)
    func test_missingFirstHalfEnd_butSecondHalfBeginPresent_clampsAtH2() {
        XCTAssertEqual(scoreboardState(absoluteTime: 2899, config: cfg(),
            events: [evt(.gameStart, at: 0), evt(.secondHalfBegin, at: 2900)])?.clock,
            .stoppage(baseSeconds: 2700, plusSeconds: 199))
        XCTAssertEqual(scoreboardState(absoluteTime: 2900, config: cfg(),
            events: [evt(.gameStart, at: 0), evt(.secondHalfBegin, at: 2900)])?.clock,
            .running(seconds: 2700))
    }
    func test_missingSecondHalfBegin_HTIndefinitely() {
        XCTAssertEqual(scoreboardState(absoluteTime: 10_000, config: cfg(),
            events: [evt(.gameStart, at: 0), evt(.firstHalfEnd, at: 2750)])?.clock, .halftime)
    }

    // Score counting
    func test_goalsInGameSpan_count() {
        let s = scoreboardState(absoluteTime: 1000, config: cfg(),
            events: [evt(.gameStart, at: 0), evt(.homeGoal, at: 100), evt(.homeGoal, at: 500), evt(.awayGoal, at: 700)])
        XCTAssertEqual(s?.homeScore, 2); XCTAssertEqual(s?.awayScore, 1)
    }
    func test_goalsBeforeGameStart_ignored() {
        XCTAssertEqual(scoreboardState(absoluteTime: 1000, config: cfg(),
            events: [evt(.homeGoal, at: -10), evt(.gameStart, at: 0)])?.homeScore, 0)
    }
    func test_goalsAfterGameEnd_ignored() {
        XCTAssertEqual(scoreboardState(absoluteTime: 10_000, config: cfg(),
            events: [evt(.gameStart, at: 0), evt(.gameEnd, at: 5800), evt(.homeGoal, at: 6000)])?.homeScore, 0)
    }
    func test_goalsDuringHT_count() {
        let s = scoreboardState(absoluteTime: 2800, config: cfg(),
            events: [evt(.gameStart, at: 0), evt(.firstHalfEnd, at: 2750), evt(.homeGoal, at: 2780)])
        XCTAssertEqual(s?.clock, .halftime); XCTAssertEqual(s?.homeScore, 1)
    }
    func test_goalsNotYetReached_notCounted() {
        XCTAssertEqual(scoreboardState(absoluteTime: 100, config: cfg(),
            events: [evt(.gameStart, at: 0), evt(.homeGoal, at: 500)])?.homeScore, 0)
    }

    // Odd-minute match — halfLen must be Double-divided
    func test_oddMinuteMatch_halfLenIsHalfPrecise() {
        XCTAssertEqual(scoreboardState(absoluteTime: 2730, config: cfg(matchLen: 91 * 60),
            events: [evt(.gameStart, at: 0)])?.clock, .running(seconds: 2730))
    }

    func test_outOfOrderTags_doNotCrash() {
        XCTAssertEqual(scoreboardState(absoluteTime: 100, config: cfg(),
            events: [evt(.firstHalfEnd, at: 50), evt(.gameStart, at: 0)])?.clock, .halftime)
    }

    // Project wrapper
    func test_projectWrapper_walksCumulativeOffset() {
        var p = Project(name: "x")
        p.sourceVideos = [
            SourceRef(bookmark: Data(), displayName: "a", durationSeconds: 60),
            SourceRef(bookmark: Data(), displayName: "b", durationSeconds: 60),
        ]
        p.scoreboard = ScoreboardConfig(
            home: TeamConfig(name: "H", primaryColor: .red, secondaryColor: .red),
            away: TeamConfig(name: "A", primaryColor: .red, secondaryColor: .red),
            stadium: "S", city: "C")
        p.setHalfTag(.gameStart, sourceIndex: 1, sourceSeconds: 5)  // abs = 65
        XCTAssertEqual(scoreboardState(atSourceIndex: 1, sourceSeconds: 10, project: p)?.clock,
                       .running(seconds: 5))   // now abs=70, elapsed=5
    }
    func test_projectWrapper_nilWhenScoreboardMissing() {
        var p = Project(name: "x")
        p.setHalfTag(.gameStart, sourceIndex: 0, sourceSeconds: 0)
        XCTAssertNil(scoreboardState(atSourceIndex: 0, sourceSeconds: 10, project: p))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path apple/VideoCoachCore --filter "FormatClockTests|ScoreboardStateTests"`
Expected: FAIL — `formatClock`/`scoreboardState`/`ClockDisplay`/`ScoreboardState`/`ClockLabels` not defined.

- [ ] **Step 3: Append to `Scoreboard.swift`**

```swift
// MARK: - Clock display + state

public enum ClockDisplay: Equatable, Sendable {
    case running(seconds: Double)
    case stoppage(baseSeconds: Double, plusSeconds: Double)
    case halftime
    case fulltime
}

public struct ClockLabels: Equatable, Sendable {
    public let main: String
    public let trailing: String
    public init(main: String, trailing: String) {
        self.main = main; self.trailing = trailing
    }
}

public func formatClock(_ d: ClockDisplay) -> ClockLabels {
    func mmss(_ s: Double) -> String {
        let total = Int(s)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
    func plusMSS(_ s: Double) -> String {
        let total = Int(s)
        return String(format: "+%d:%02d", total / 60, total % 60)
    }
    switch d {
    case .running(let s):           return .init(main: mmss(s), trailing: "")
    case .stoppage(let b, let p):   return .init(main: mmss(b), trailing: plusMSS(p))
    case .halftime:                 return .init(main: "HT", trailing: "")
    case .fulltime:                 return .init(main: "FT", trailing: "")
    }
}

public struct ScoreboardState: Equatable, Sendable {
    public let home: TeamConfig
    public let away: TeamConfig
    public let stadium: String
    public let city: String
    public let homeScore: Int
    public let awayScore: Int
    public let clock: ClockDisplay
}

/// Canonical pure function. Compositors call this directly (their instructions
/// carry pre-resolved absolute times so the cumulative-offset walk doesn't
/// happen on AVFoundation's render queue).
public func scoreboardState(
    absoluteTime now: Double,
    config: ScoreboardConfig,
    events: [AbsoluteMatchEvent]
) -> ScoreboardState? {
    guard !config.home.name.isEmpty, !config.away.name.isEmpty else { return nil }
    guard let tStart = events.first(where: { $0.kind == .gameStart })?.absSeconds else { return nil }
    guard now >= tStart else { return nil }

    let halfLen = Double(config.matchLengthSeconds) / 2.0
    let matchLen = Double(config.matchLengthSeconds)

    let rawTH1End = events.first(where: { $0.kind == .firstHalfEnd })?.absSeconds
    let rawTH2Start = events.first(where: { $0.kind == .secondHalfBegin })?.absSeconds
    let rawTEnd = events.first(where: { $0.kind == .gameEnd })?.absSeconds

    // Missing-tag fallback (spec §2)
    let tH1End: Double = rawTH1End ?? rawTH2Start ?? .infinity
    let tH2Start: Double = rawTH2Start ?? .infinity
    let tEnd: Double = rawTEnd ?? .infinity

    let clock: ClockDisplay
    if now < tH1End {  // strict < so fallback tH1End := tH2Start lets now==tH2Start hit 2H
        let elapsed = now - tStart
        clock = elapsed <= halfLen
            ? .running(seconds: elapsed)
            : .stoppage(baseSeconds: halfLen, plusSeconds: elapsed - halfLen)
    } else if now < tH2Start {
        clock = .halftime
    } else if now < tEnd {
        let elapsed = halfLen + (now - tH2Start)
        clock = elapsed <= matchLen
            ? .running(seconds: elapsed)
            : .stoppage(baseSeconds: matchLen, plusSeconds: elapsed - matchLen)
    } else {
        clock = .fulltime
    }

    func countGoals(_ kind: MatchEventKind) -> Int {
        events.reduce(into: 0) { acc, e in
            guard e.kind == kind, e.absSeconds <= now,
                  e.absSeconds >= tStart, e.absSeconds <= tEnd else { return }
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

/// Convenience for live (scan/record/preview) call sites that have a Project +
/// (sourceIndex, sourceSeconds) pair. Walks `cumulativeOffset` once and delegates.
public func scoreboardState(
    atSourceIndex sourceIndex: Int,
    sourceSeconds: Double,
    project: Project
) -> ScoreboardState? {
    guard let cfg = project.scoreboard else { return nil }
    let absNow = project.cumulativeOffset(forSourceIndex: sourceIndex) + sourceSeconds
    let absEvents: [AbsoluteMatchEvent] = project.matchEvents.map { rec in
        AbsoluteMatchEvent(
            absSeconds: project.cumulativeOffset(forSourceIndex: rec.sourceIndex) + rec.sourceSeconds,
            kind: rec.kind
        )
    }
    return scoreboardState(absoluteTime: absNow, config: cfg, events: absEvents)
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --package-path apple/VideoCoachCore --filter "FormatClockTests|ScoreboardStateTests"`
Expected: ALL PASS.

- [ ] **Step 5: Commit**

```bash
git add apple/VideoCoachCore/Sources/VideoCoachCore/Scoreboard.swift apple/VideoCoachCore/Tests/VideoCoachCoreTests/ScoreboardTests.swift
git commit -m "feat(core): ClockDisplay + formatClock + scoreboardState (canonical + project wrapper)"
```

---

## Task 3: `ProjectStore` widen read guard + write bumps formatVersion

**Files:**
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/ProjectStore.swift`
- Modify: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ProjectTests.swift`

- [ ] **Step 1: Append failing tests in `ProjectTests.swift`**

```swift
    func test_v2JSON_decodesWithEmptyScoreboardDefaults() throws {
        let json = """
        {
          "formatVersion": 2, "name": "x",
          "sourceVideos": [], "clips": [],
          "preferences": {
            "scanVolume": 1, "previewSourceVolume": 1, "previewCommentaryVolume": 1,
            "lastExportResolution": "r1080", "lastExportQuality": "medium"
          }
        }
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(Project.self, from: json)
        XCTAssertEqual(p.formatVersion, 2)
        XCTAssertNil(p.scoreboard)
        XCTAssertTrue(p.matchEvents.isEmpty)
    }

    func test_projectStore_writeBumpsFormatVersionToCurrent() throws {
        var p = Project(name: "x")
        p.formatVersion = 2  // simulate freshly loaded v2 project
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try ProjectStore.write(p, to: tmp)
        let reread = try ProjectStore.read(from: tmp)
        XCTAssertEqual(reread.formatVersion, 3, "write must bump formatVersion to current (3)")
    }

    func test_projectStore_v3RoundTripWithScoreboard() throws {
        var p = Project(name: "x")
        p.scoreboard = ScoreboardConfig(
            home: TeamConfig(name: "ARS", primaryColor: .red, secondaryColor: .red),
            away: TeamConfig(name: "BUR", primaryColor: .red, secondaryColor: .red),
            stadium: "EMIRATES STADIUM", city: "LONDON")
        p.setHalfTag(.gameStart, sourceIndex: 0, sourceSeconds: 1.0)
        p.appendGoal(.homeGoal, sourceIndex: 0, sourceSeconds: 10.0)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try ProjectStore.write(p, to: tmp)
        let reread = try ProjectStore.read(from: tmp)
        XCTAssertEqual(reread.scoreboard?.home.name, "ARS")
        XCTAssertEqual(reread.matchEvents.count, 2)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path apple/VideoCoachCore --filter ProjectTests`
Expected: `test_projectStore_writeBumpsFormatVersionToCurrent` FAILS — read throws `unsupportedFormatVersion(3)`.

- [ ] **Step 3: Modify `ProjectStore.swift`**

Change the guard block (current lines 21-27) from:
```swift
        if project.formatVersion < 1 || project.formatVersion > 2 {
            throw ProjectStoreError.unsupportedFormatVersion(project.formatVersion)
        }
```
to:
```swift
        // Accept v1 (legacy), v2 (.zoom event variant), v3 (scoreboard +
        // matchEvents). `Project.currentFormatVersion` is the upper bound —
        // bump it there to widen this guard.
        if project.formatVersion < 1 || project.formatVersion > Project.currentFormatVersion {
            throw ProjectStoreError.unsupportedFormatVersion(project.formatVersion)
        }
```

Change `write(_:to:)` signature from:
```swift
    public static func write(_ project: Project, to folder: URL) throws {
```
to:
```swift
    public static func write(_ project: Project, to folder: URL) throws {
        var project = project
        project.formatVersion = Project.currentFormatVersion
```

- [ ] **Step 4: Run tests**

Run: `swift test --package-path apple/VideoCoachCore`
Expected: ALL PASS.

- [ ] **Step 5: Commit**

```bash
git add apple/VideoCoachCore/Sources/VideoCoachCore/ProjectStore.swift apple/VideoCoachCore/Tests/VideoCoachCoreTests/ProjectTests.swift
git commit -m "feat(core): ProjectStore widens to currentFormatVersion; write bumps on save"
```

---

## Task 4: `drawScoreboard` + smoke render test

**Files:**
- Create: `apple/VideoCoachCore/Sources/VideoCoachCore/Overlays/Scoreboard.swift`
- Create: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ScoreboardRenderTests.swift`

(Note: color-anchor probe is covered end-to-end in Task 10's export pixel-anchor test. Here we keep only a "the function actually drew something inside the bar rect" smoke check, which the export test does NOT verify.)

- [ ] **Step 1: Write failing test**

`apple/VideoCoachCore/Tests/VideoCoachCoreTests/ScoreboardRenderTests.swift`:
```swift
import XCTest
import CoreGraphics
@testable import VideoCoachCore

final class ScoreboardRenderTests: XCTestCase {
    /// Allocate a stable-lifetime CG context backed by an `UnsafeMutableRawPointer`
    /// the test owns and releases. The `&pixels` / `withUnsafeMutableBytes`
    /// shortcut creates a context whose backing pointer dangles past the
    /// closure — an explicit allocation is the only sound way to share a
    /// CGContext factory across a test method.
    private func makeContext(width: Int = 1280, height: Int = 720)
        -> (cg: CGContext, snapshot: () -> [UInt8], release: () -> Void)
    {
        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount, alignment: MemoryLayout<UInt8>.alignment
        )
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        let cg = CGContext(
            data: raw, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: 1, y: -1)
        let snapshot: () -> [UInt8] = {
            let buf = UnsafeBufferPointer(
                start: raw.assumingMemoryBound(to: UInt8.self), count: byteCount)
            return Array(buf)
        }
        let release: () -> Void = { raw.deallocate() }
        return (cg, snapshot, release)
    }

    private func runningState() -> ScoreboardState {
        ScoreboardState(
            home: TeamConfig(name: "ARS",
                primaryColor: RGBA(r: 1, g: 0, b: 0, a: 1),
                secondaryColor: RGBA(r: 1, g: 1, b: 1, a: 1)),
            away: TeamConfig(name: "BUR",
                primaryColor: RGBA(r: 0, g: 0, b: 1, a: 1),
                secondaryColor: RGBA(r: 1, g: 1, b: 1, a: 1)),
            stadium: "EMIRATES STADIUM", city: "LONDON",
            homeScore: 0, awayScore: 0,
            clock: .running(seconds: 7))
    }

    func test_smokeRender_drawsInsideBarRect_leavesOutsideUntouched() {
        let w = 1280, h = 720
        let (cg, snapshot, release) = makeContext(width: w, height: h)
        defer { release() }
        drawScoreboard(into: cg, size: CGSize(width: w, height: h), state: runningState())
        let bytes = snapshot()
        // Probe a point well inside the bar (top-left area).
        let inside = bytes[(60 * w + 200) * 4 + 0..<(60 * w + 200) * 4 + 4]  // BGRA
        let insideSum = Int(inside[inside.startIndex]) + Int(inside[inside.startIndex + 1]) + Int(inside[inside.startIndex + 2])
        XCTAssertGreaterThan(insideSum, 10, "expected some non-background pixels inside bar rect")

        // Probe far outside the bar (bottom-right quadrant).
        let outside = bytes[((h - 50) * w + (w - 50)) * 4 + 0..<((h - 50) * w + (w - 50)) * 4 + 4]
        let outsideSum = Int(outside[outside.startIndex]) + Int(outside[outside.startIndex + 1]) + Int(outside[outside.startIndex + 2])
        XCTAssertEqual(outsideSum, 0, "expected untouched (transparent black) pixels far outside bar")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path apple/VideoCoachCore --filter ScoreboardRenderTests`
Expected: FAIL — `drawScoreboard` not defined.

- [ ] **Step 3: Implement `drawScoreboard`**

Create `apple/VideoCoachCore/Sources/VideoCoachCore/Overlays/Scoreboard.swift`:

```swift
import CoreGraphics
import CoreText
import Foundation

/// Draws the broadcast scoreboard overlay anchored to the top-left of `size`.
/// Caller MUST have set up top-left user space — the convention
/// `CompilationCompositor` uses after its `translateBy/scaleBy(-1)` flip;
/// AppKit's `NSView.draw(_:)` provides this through
/// `NSGraphicsContext.current!.cgContext` when the view has `isFlipped = true`.
public func drawScoreboard(into cg: CGContext, size: CGSize, state: ScoreboardState) {
    let barH = size.height * 0.08
    let barW = size.width  * 0.36
    let inset = size.height * 0.015
    let topY = inset
    let leftX = inset

    let accentH = barH * 0.08
    let scoreBarH = barH - accentH
    let venueBandH = barH * 0.5

    // Sub-cell widths within the main bar.
    let homeW  = barW * 0.30
    let scoreW = barW * 0.20
    let awayW  = barW * 0.30
    let clockW = barW * 0.20

    func color(_ c: RGBA) -> CGColor {
        CGColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }

    // Score-row backgrounds (below accent strip)
    let scoreRowY = topY + accentH
    let homeRect  = CGRect(x: leftX,                              y: scoreRowY, width: homeW,  height: scoreBarH)
    let scoreRect = CGRect(x: leftX + homeW,                      y: scoreRowY, width: scoreW, height: scoreBarH)
    let awayRect  = CGRect(x: leftX + homeW + scoreW,             y: scoreRowY, width: awayW,  height: scoreBarH)
    let clockRect = CGRect(x: leftX + homeW + scoreW + awayW,     y: scoreRowY, width: clockW, height: scoreBarH)

    cg.setFillColor(color(state.home.primaryColor)); cg.fill(homeRect)
    cg.setFillColor(color(RGBA(r: 0.1, g: 0.1, b: 0.1, a: 1))); cg.fill(scoreRect)
    cg.setFillColor(color(state.away.primaryColor)); cg.fill(awayRect)
    cg.setFillColor(color(RGBA(r: 0.05, g: 0.05, b: 0.05, a: 0.95))); cg.fill(clockRect)

    // Accent strips on top
    cg.setFillColor(color(state.home.secondaryColor))
    cg.fill(CGRect(x: leftX, y: topY, width: homeW, height: accentH))
    cg.setFillColor(color(state.away.secondaryColor))
    cg.fill(CGRect(x: leftX + homeW + scoreW, y: topY, width: awayW, height: accentH))

    // Venue band
    let venueRect = CGRect(x: leftX, y: topY + barH, width: barW, height: venueBandH)
    cg.setFillColor(color(RGBA(r: 0, g: 0, b: 0, a: 0.8))); cg.fill(venueRect)

    // Text
    let labels = formatClock(state.clock)
    drawText(state.home.name, in: homeRect, fontSize: scoreBarH * 0.55, bold: true, into: cg, canvasHeight: size.height)
    drawText("\(state.homeScore) - \(state.awayScore)", in: scoreRect, fontSize: scoreBarH * 0.55, bold: true, into: cg, canvasHeight: size.height)
    drawText(state.away.name, in: awayRect, fontSize: scoreBarH * 0.55, bold: true, into: cg, canvasHeight: size.height)
    drawText(labels.main, in: clockRect, fontSize: scoreBarH * 0.55, bold: true, into: cg, canvasHeight: size.height)
    if !labels.trailing.isEmpty {
        let plusRect = CGRect(x: clockRect.maxX + 2, y: scoreRowY, width: clockW * 0.5, height: scoreBarH)
        drawText(labels.trailing, in: plusRect, fontSize: scoreBarH * 0.45, bold: false, into: cg, canvasHeight: size.height)
    }
    drawText("\(state.stadium) \(state.city)", in: venueRect.insetBy(dx: 6, dy: 2),
             fontSize: venueBandH * 0.55, bold: true, into: cg, canvasHeight: size.height)
}

// MARK: - Internal text helper

private let whiteCG = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

private func drawText(
    _ s: String,
    in rect: CGRect,
    fontSize: CGFloat,
    bold: Bool,
    into cg: CGContext,
    canvasHeight: CGFloat
) {
    guard !s.isEmpty else { return }
    let baseFont = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
        ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
    let traits: CTFontSymbolicTraits = bold ? .boldTrait : []
    let font = CTFontCreateCopyWithSymbolicTraits(baseFont, fontSize, nil, traits, traits) ?? baseFont
    let attrs: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: whiteCG,
    ]
    guard let attributed = CFAttributedStringCreate(nil, s as CFString, attrs as CFDictionary) else { return }
    let line = CTLineCreateWithAttributedString(attributed)
    let lineBounds = CTLineGetImageBounds(line, cg)

    // Caller is in top-left user space; CoreText draws bottom-up. Flip locally.
    cg.saveGState()
    cg.translateBy(x: 0, y: canvasHeight)
    cg.scaleBy(x: 1, y: -1)
    let flippedY = canvasHeight - rect.maxY
    let textX = rect.minX + (rect.width - lineBounds.width) / 2 - lineBounds.minX
    let textY = flippedY + (rect.height - lineBounds.height) / 2 - lineBounds.minY
    cg.textPosition = CGPoint(x: textX, y: textY)
    CTLineDraw(line, cg)
    cg.restoreGState()
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --package-path apple/VideoCoachCore --filter ScoreboardRenderTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apple/VideoCoachCore/Sources/VideoCoachCore/Overlays/Scoreboard.swift apple/VideoCoachCore/Tests/VideoCoachCoreTests/ScoreboardRenderTests.swift
git commit -m "feat(core): drawScoreboard + smoke render test"
```

---

## Task 5: `UndoController.editMatchEvents` case

**Files:**
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/UndoController.swift`

(No test — the existing `editClip`/`reorderClips` tests already cover `pushEdit`/`popForUndo`/`popForRedo` semantics. Adding a `Sendable` enum case is compiler-checked; behavior beyond the existing test set is zero. The real coverage lives in Task 11's `Workspace.undo()`/`redo()` switch arms, which the compiler will require to handle the new case exhaustively.)

- [ ] **Step 1: Add the case**

In `UndoController.swift`, change `UndoAction` to:
```swift
public enum UndoAction: Sendable {
    case editClip(id: Clip.ID, before: Clip, after: Clip)
    case deleteClip(DeletedClip)
    case reorderClips(beforeOrder: [Clip.ID], afterOrder: [Clip.ID])
    /// Snapshot pair of the project's `matchEvents` list around a tag/untag/replace.
    /// The list is bounded (~10–20 entries) so per-step copy cost is negligible.
    case editMatchEvents(before: [MatchEventRecord], after: [MatchEventRecord])
}
```

- [ ] **Step 2: Build**

Run: `swift build --package-path apple/VideoCoachCore`
Expected: SUCCESS (existing callers do not exhaustive-switch on `UndoAction`; if any do, address them when their callers are updated in Task 11).

- [ ] **Step 3: Commit**

```bash
git add apple/VideoCoachCore/Sources/VideoCoachCore/UndoController.swift
git commit -m "feat(core): UndoAction.editMatchEvents case"
```

---

## Task 6: Extend `CompilationInstruction` with scoreboard fields

**Files:**
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/CompilationInstruction.swift`

- [ ] **Step 1: Add fields and update `make(...)` builder**

In the class body, add:
```swift
public var scoreboardConfig: ScoreboardConfig? = nil
public var matchEventsAbs: [AbsoluteMatchEvent] = []
public var clipStartAbsSeconds: Double = 0
```

In the `static func make(...)` signature, **append** three new defaulted parameters at the end (so existing call sites still compile):
```swift
scoreboardConfig: ScoreboardConfig? = nil,
matchEventsAbs: [AbsoluteMatchEvent] = [],
clipStartAbsSeconds: Double = 0
```
And in the function body, assign onto the constructed instance:
```swift
i.scoreboardConfig = scoreboardConfig
i.matchEventsAbs = matchEventsAbs
i.clipStartAbsSeconds = clipStartAbsSeconds
```

- [ ] **Step 2: Build**

Run: `swift build --package-path apple/VideoCoachCore`
Expected: SUCCESS.

- [ ] **Step 3: Commit**

```bash
git add apple/VideoCoachCore/Sources/VideoCoachCore/CompilationInstruction.swift
git commit -m "feat(core): CompilationInstruction carries scoreboard fields"
```

---

## Task 7: `CompilationCompositor` calls `drawScoreboard`

**Files:**
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/CompilationCompositor.swift`

- [ ] **Step 1: Locate the existing `drawTextBar(inst.textBarLine, ...)` call** (around line 250 in `startRequest`).

- [ ] **Step 2: Insert scoreboard draw immediately after** the text-bar draw, inside the `if let inst` block:
```swift
            let absNow = inst.clipStartAbsSeconds + recordTime
            if let cfg = inst.scoreboardConfig,
               let s = scoreboardState(absoluteTime: absNow,
                                       config: cfg,
                                       events: inst.matchEventsAbs) {
                drawScoreboard(into: cg, size: size, state: s)
            }
```

- [ ] **Step 3: Run full core suite**

Run: `swift test --package-path apple/VideoCoachCore`
Expected: ALL PASS (existing exporter tests build instructions without the new fields → defaults nil/empty/0, the `if let cfg` short-circuits, no behavior change).

- [ ] **Step 4: Commit**

```bash
git add apple/VideoCoachCore/Sources/VideoCoachCore/CompilationCompositor.swift
git commit -m "feat(export): CompilationCompositor draws scoreboard when configured"
```

---

## Task 8: Planner integration — `CompilationExporter.export(...)` signature + `ExportSheet` precompute

**Files:**
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/CompilationExporter.swift`
- Modify: `apple/App/Export/ExportSheet.swift`

- [ ] **Step 1: Add `clipStartAbsSeconds` static helper in `CompilationExporter.swift`**

(So Task 9's unit test can verify the precompute without spinning up an `AVAssetExportSession`.)
```swift
extension CompilationExporter {
    /// Per-clip absolute-time precompute used to populate scoreboard fields
    /// on `CompilationInstruction`. Pure; unit-testable without running an
    /// export. Returns `(sourceCumulativeOffsets[clip.sourceIndex] ?? 0) +
    /// clip.startSourceSeconds`.
    public static func clipStartAbsSeconds(
        for clip: Clip,
        sourceCumulativeOffsets: [Int: Double]
    ) -> Double {
        (sourceCumulativeOffsets[clip.sourceIndex] ?? 0) + clip.startSourceSeconds
    }
}
```
(File location: append at the bottom of `CompilationExporter.swift`.)

- [ ] **Step 2: Extend `CompilationExporter.export(...)` signature**

In `CompilationExporter.swift`'s `export(...)` function (currently around lines 297–342), **append** three new defaulted parameters after the existing inputs (`plan:`, `clipsByID:`, `sourceAssets:`, `clipWebcamAssets:`, etc.):
```swift
scoreboardConfig: ScoreboardConfig? = nil,
matchEventsAbs: [AbsoluteMatchEvent] = [],
sourceCumulativeOffsets: [Int: Double] = [:],
```

`sourceCumulativeOffsets[i]` is `project.cumulativeOffset(forSourceIndex: i)` — pre-walked by the caller. Dictionary-keyed (not array-indexed) to avoid the unchecked-subscript hazard the spec calls out.

- [ ] **Step 3: Inside the `for entry in plan.entries { … CompilationInstruction.make(...) }` loop**, compute `clipStartAbsSeconds` and pass all three fields through:
```swift
let clipStartAbsSeconds = Self.clipStartAbsSeconds(
    for: clip,
    sourceCumulativeOffsets: sourceCumulativeOffsets
)
let inst = CompilationInstruction.make(
    // …existing arguments unchanged, in the same order…
    scoreboardConfig: scoreboardConfig,
    matchEventsAbs: matchEventsAbs,
    clipStartAbsSeconds: clipStartAbsSeconds
)
```
(The `clip` binding is already in scope from the loop — verify the variable name in the actual file; adjust if it's `entry.clip` or similar.)

- [ ] **Step 4: In `ExportSheet.swift`, precompute the three values once per export**

Locate the existing `try await exporter.export(...)` call (around lines 610–625). On the main actor, BEFORE the `Task { … }` (or directly inside it before the `await`), compute:
```swift
let scoreboardConfig = workspace.project.scoreboard
let cumulativeOffsets: [Int: Double] = Dictionary(
    uniqueKeysWithValues: workspace.project.sourceVideos.indices.map {
        ($0, workspace.project.cumulativeOffset(forSourceIndex: $0))
    }
)
let matchEventsAbs: [AbsoluteMatchEvent] = workspace.project.matchEvents.map { rec in
    AbsoluteMatchEvent(
        absSeconds: (cumulativeOffsets[rec.sourceIndex] ?? 0) + rec.sourceSeconds,
        kind: rec.kind
    )
}
```
Then pass them into each `exporter.export(...)` call:
```swift
try await exporter.export(
    plan: plan,
    clipsByID: context.clipsByID,
    sourceAssets: context.sourceAssets,
    clipWebcamAssets: context.clipWebcamAssets,
    // …other existing args, unchanged…
    scoreboardConfig: scoreboardConfig,
    matchEventsAbs: matchEventsAbs,
    sourceCumulativeOffsets: cumulativeOffsets
)
```

- [ ] **Step 5: Build + full core suite**

Run: `swift test --package-path apple/VideoCoachCore`
Run: `xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build`
Expected: ALL PASS / SUCCESS. The defaults preserve behavior for tests that don't supply scoreboard inputs.

- [ ] **Step 6: Commit**

```bash
git add apple/VideoCoachCore/Sources/VideoCoachCore/CompilationExporter.swift apple/App/Export/ExportSheet.swift
git commit -m "feat(export): planner threads scoreboard inputs through to instructions"
```

---

## Task 9: Planner precompute unit test

**Files:**
- Create: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/CompilationPlannerScoreboardTests.swift`

- [ ] **Step 1: Write the test**

```swift
import XCTest
@testable import VideoCoachCore

final class CompilationPlannerScoreboardTests: XCTestCase {
    func test_clipStartAbsSeconds_addsCumulativeOffsetToStartSourceSeconds() {
        let clip = Clip(
            name: "c", sourceIndex: 1, startSourceSeconds: 30,
            recordingDuration: 5, recordingFilename: "x.mov", sortIndex: 0)
        let offsets: [Int: Double] = [0: 0, 1: 100, 2: 250]
        XCTAssertEqual(
            CompilationExporter.clipStartAbsSeconds(for: clip, sourceCumulativeOffsets: offsets),
            130)
    }

    func test_clipStartAbsSeconds_unknownSourceIndexFallsBackToZero() {
        let clip = Clip(
            name: "c", sourceIndex: 99, startSourceSeconds: 7,
            recordingDuration: 1, recordingFilename: "x.mov", sortIndex: 0)
        XCTAssertEqual(
            CompilationExporter.clipStartAbsSeconds(for: clip, sourceCumulativeOffsets: [:]),
            7)
    }

    /// Direct assertion that the absolute-event projection (the same arithmetic
    /// `ExportSheet` does before calling `export(...)`) maps through cumulative
    /// offsets correctly. Locks down "drops .gameStart" / "uses sourceSeconds
    /// raw" regressions so the export pixel test doesn't have to detect them.
    func test_matchEventsAbs_mapsThroughCumulativeOffset() {
        var p = Project(name: "x")
        p.sourceVideos = [
            SourceRef(bookmark: Data(), displayName: "a", durationSeconds: 100),
            SourceRef(bookmark: Data(), displayName: "b", durationSeconds: 60),
        ]
        p.setHalfTag(.gameStart, sourceIndex: 0, sourceSeconds: 10)
        p.appendGoal(.homeGoal, sourceIndex: 1, sourceSeconds: 5)
        let offsets: [Int: Double] = [0: 0, 1: 100]
        let abs: [AbsoluteMatchEvent] = p.matchEvents.map { rec in
            AbsoluteMatchEvent(
                absSeconds: (offsets[rec.sourceIndex] ?? 0) + rec.sourceSeconds,
                kind: rec.kind)
        }
        XCTAssertEqual(abs.count, 2)
        XCTAssertEqual(abs[0], AbsoluteMatchEvent(absSeconds: 10, kind: .gameStart))
        XCTAssertEqual(abs[1], AbsoluteMatchEvent(absSeconds: 105, kind: .homeGoal))
    }
}
```

- [ ] **Step 2: Run + commit**

Run: `swift test --package-path apple/VideoCoachCore --filter CompilationPlannerScoreboardTests`
Expected: ALL PASS.

```bash
git add apple/VideoCoachCore/Tests/VideoCoachCoreTests/CompilationPlannerScoreboardTests.swift
git commit -m "test(export): planner precompute (clipStartAbsSeconds + matchEventsAbs)"
```

---

## Task 10: Export pixel-anchor integration test

**Files:**
- Modify: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/CompilationExporterE2ETests.swift`

- [ ] **Step 1: Extend the existing `runExport(clip:)` helper**

Read the existing `runExport(clip:)` (around line 273). It builds a `Project` internally and exports. Extend it with two optional defaulted parameters so we can inject scoreboard state without touching any other test:

```swift
private func runExport(
    clip: Clip,
    scoreboard: ScoreboardConfig? = nil,
    matchEvents: [MatchEventRecord] = []
) async throws {
    // existing body…
    // After `var project = Project(name: "export-e2e")` (or wherever the
    // Project is constructed), add:
    project.scoreboard = scoreboard
    project.matchEvents = matchEvents
    // …continue with existing logic (compilationPlan + exporter.export).
    // When calling exporter.export(...), pass the precomputed scoreboard
    // inputs through (same pattern as Task 8's ExportSheet integration):
    //   let cumulativeOffsets: [Int: Double] = Dictionary(uniqueKeysWithValues:
    //       project.sourceVideos.indices.map {
    //           ($0, project.cumulativeOffset(forSourceIndex: $0))
    //       })
    //   let matchEventsAbs: [AbsoluteMatchEvent] = project.matchEvents.map { rec in
    //       AbsoluteMatchEvent(
    //           absSeconds: (cumulativeOffsets[rec.sourceIndex] ?? 0) + rec.sourceSeconds,
    //           kind: rec.kind)
    //   }
    //   try await exporter.export(
    //       … existing args …,
    //       scoreboardConfig: project.scoreboard,
    //       matchEventsAbs: matchEventsAbs,
    //       sourceCumulativeOffsets: cumulativeOffsets
    //   )
}
```

(Read the actual file structure carefully — preserve existing call ordering. The defaults preserve all existing test callers.)

- [ ] **Step 2: Add the export test**

```swift
func test_export_drawsScoreboard_homePrimaryAtHomeCell_awayPrimaryAtAwayCell() async throws {
    // Build a clip the existing infra can export. Mirror the pattern from
    // other tests in this file (e.g., `test_export_basicClip` if present).
    let clip = Clip(
        name: "scoreboard-export",
        tags: ["test"],
        sourceIndex: 0,
        startSourceSeconds: 2,
        recordingDuration: 2,
        recordingFilename: camURL.lastPathComponent,
        events: [
            .init(recordTime: 0, kind: .zoom(.identity)),
            .init(recordTime: 0, kind: .play(sourceTime: 2)),
        ],
        sortIndex: 0
    )
    let scoreboard = ScoreboardConfig(
        home: TeamConfig(name: "RED",
            primaryColor: RGBA(r: 1, g: 0, b: 0, a: 1),
            secondaryColor: RGBA(r: 1, g: 1, b: 1, a: 1)),
        away: TeamConfig(name: "BLU",
            primaryColor: RGBA(r: 0, g: 0, b: 1, a: 1),
            secondaryColor: RGBA(r: 1, g: 1, b: 1, a: 1)),
        stadium: "TEST", city: "X"
    )
    // gameStart at source(0, 0.0): scoreboard is "on" for any export frame,
    // regardless of where the clip starts. This keeps the test sensitive to
    // colors / position without coupling to clipStartAbsSeconds — Task 9
    // verifies that precompute separately.
    let events: [MatchEventRecord] = [
        .init(kind: .gameStart, sourceIndex: 0, sourceSeconds: 0.0)
    ]
    try await runExport(clip: clip, scoreboard: scoreboard, matchEvents: events)
    let frame = try await sampleFrame(of: outURL, atOutputTime: 0.5)

    // Spec §3 layout in NORMALIZED output coords:
    //   bar: leftX≈0.015, topY≈0.015, barW≈0.36, barH≈0.08
    //   homeCell: x ∈ [0.015, 0.123]   (leftX → leftX + 0.30·barW)
    //   awayCell: x ∈ [0.195, 0.303]   (after home + score cells)
    let homeAvg = PixelSampling.averageRGB(
        in: frame,
        normalizedRect: CGRect(x: 0.05, y: 0.04, width: 0.04, height: 0.03))
    XCTAssertGreaterThan(homeAvg.r, 0.5, "home cell should be red-dominant")
    XCTAssertLessThan(homeAvg.b, 0.3,    "home cell should not be blue")

    let awayAvg = PixelSampling.averageRGB(
        in: frame,
        normalizedRect: CGRect(x: 0.23, y: 0.04, width: 0.04, height: 0.03))
    XCTAssertGreaterThan(awayAvg.b, 0.5, "away cell should be blue-dominant")
    XCTAssertLessThan(awayAvg.r, 0.3,    "away cell should not be red")
}
```

(If `sampleFrame(of:atOutputTime:)` has a slightly different signature, read the helper above the existing tests and adjust. If probe coords miss because the actual rendered layout differs slightly, shift the probe rects — do NOT change `drawScoreboard`'s layout constants unless they're clearly wrong against spec §3.)

- [ ] **Step 3: Run + commit**

Run: `swift test --package-path apple/VideoCoachCore --filter test_export_drawsScoreboard`
Expected: PASS.

```bash
git add apple/VideoCoachCore/Tests/VideoCoachCoreTests/CompilationExporterE2ETests.swift
git commit -m "test(export): pixel-anchor integration test for scoreboard"
```

---

## Task 11: `Workspace.mutateMatchEvents` + `tagMatchEvent` + undo/redo arms

**Files:**
- Modify: `apple/App/Models/Workspace.swift`

- [ ] **Step 1: Add `mutateMatchEvents` + `tagMatchEvent` helpers**

In the `@Observable` `Workspace` class body, add:
```swift
/// Snapshot-then-mutate-then-push-undo wrapper for all match-event edits.
func mutateMatchEvents(_ mutate: (inout Project) -> Void) {
    let before = project.matchEvents
    mutate(&project)
    let after = project.matchEvents
    guard before != after else { return }
    undoController.pushEdit(.editMatchEvents(before: before, after: after))
}

/// Capture the source player's current `(playlistPos, timePos)` and apply the
/// appropriate match-event mutation for `kind`. Half-tags replace in place;
/// goals append. No-op when no source player is loaded.
func tagMatchEvent(_ kind: MatchEventKind) {
    guard let player = sourcePlayer else { return }
    let idx = player.playlistPos
    let sec = player.timePos
    mutateMatchEvents { p in
        if kind.isHalfTag {
            p.setHalfTag(kind, sourceIndex: idx, sourceSeconds: sec)
        } else {
            p.appendGoal(kind, sourceIndex: idx, sourceSeconds: sec)
        }
    }
}
```

- [ ] **Step 2: Add undo/redo arms**

Locate `Workspace.undo()` / `redo()` (search for `case .editClip`). Add to the `undo()` switch:
```swift
case .editMatchEvents(let before, _):
    project.matchEvents = before
```
And to the `redo()` switch:
```swift
case .editMatchEvents(_, let after):
    project.matchEvents = after
```
(Match the actual dispatch shape — if there's a single helper that applies the inverse, model the new case the same way.)

- [ ] **Step 3: Build**

Run: `xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build`
Expected: SUCCESS.

- [ ] **Step 4: Commit**

```bash
git add apple/App/Models/Workspace.swift
git commit -m "feat(app): Workspace.mutateMatchEvents + tagMatchEvent + undo/redo arms"
```

---

## Task 12: `MatchSetupSheet`

**Files:**
- Create: `apple/App/Views/Scoreboard/MatchSetupSheet.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI
import VideoCoachCore
import AppKit

struct MatchSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    // Workspace is @Observable; we only read project.scoreboard for the initial
    // value and write it back on Save — no SwiftUI bindings needed, so no @Bindable.
    let workspace: Workspace
    @State private var working: ScoreboardConfig

    init(workspace: Workspace) {
        self.workspace = workspace
        let defaultColor = RGBA(r: 0.5, g: 0.5, b: 0.5, a: 1)
        let blank = TeamConfig(name: "", primaryColor: defaultColor, secondaryColor: defaultColor)
        _working = State(initialValue: workspace.project.scoreboard
            ?? ScoreboardConfig(home: blank, away: blank, stadium: "", city: ""))
    }

    var body: some View {
        Form {
            Section("Home Team") {
                TextField("Name", text: $working.home.name)
                HStack {
                    ColorPickerCell(label: "Primary", color: $working.home.primaryColor)
                    ColorPickerCell(label: "Secondary", color: $working.home.secondaryColor)
                }
            }
            Section("Away Team") {
                TextField("Name", text: $working.away.name)
                HStack {
                    ColorPickerCell(label: "Primary", color: $working.away.primaryColor)
                    ColorPickerCell(label: "Secondary", color: $working.away.secondaryColor)
                }
            }
            Section("Venue") {
                TextField("Stadium", text: $working.stadium)
                TextField("City", text: $working.city)
            }
            Section("Match length") {
                Stepper(value: Binding(
                    get: { working.matchLengthSeconds / 60 },
                    set: { working.matchLengthSeconds = $0 * 60 }
                ), in: 1...180) {
                    Text("\(working.matchLengthSeconds / 60) minutes")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    workspace.project.scoreboard = working
                    dismiss()
                }
            }
        }
    }
}

private struct ColorPickerCell: View {
    let label: String
    @Binding var color: RGBA
    var body: some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption)
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

- [ ] **Step 2: Build + commit**

Run: `xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build`
Expected: SUCCESS.

```bash
git add apple/App/Views/Scoreboard/MatchSetupSheet.swift
git commit -m "feat(app): MatchSetupSheet for team / venue / match length config"
```

---

## Task 13: Wire `Project → Match Setup…` menu item

**Files:**
- Modify: `apple/App/ContentView.swift`

- [ ] **Step 1: Add sheet state**

Near other `@State` properties at the top of `ContentView`:
```swift
@State private var showMatchSetup: Bool = false
```

- [ ] **Step 2: Add menu item via `.commands`**

Locate the existing `.commands` block (search for `CommandMenu` or `CommandGroup`). If a "Project" `CommandMenu` exists, add the button there; otherwise create one:
```swift
CommandMenu("Project") {
    Button("Match Setup…") { showMatchSetup = true }
        .keyboardShortcut("m", modifiers: [.command, .shift])
}
```

- [ ] **Step 3: Present the sheet**

On the top-level view, add:
```swift
.sheet(isPresented: $showMatchSetup) {
    MatchSetupSheet(workspace: workspace)
}
```

- [ ] **Step 4: Build + manual test + commit**

Run: `xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build`
Launch from the freshly-built path; test Project → Match Setup… opens; fill fields; Save; reopen the sheet to verify persistence in memory.

```bash
git add apple/App/ContentView.swift
git commit -m "feat(app): Project → Match Setup… menu item"
```

---

## Task 14: `MatchInspectorPanel`

**Files:**
- Create: `apple/App/Views/Scoreboard/MatchInspectorPanel.swift`
- Modify: `apple/App/ContentView.swift` (mount in scanning-mode inspector area)

- [ ] **Step 1: Create the panel**

```swift
import SwiftUI
import VideoCoachCore

struct MatchInspectorPanel: View {
    let workspace: Workspace
    var openSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MATCH").font(.caption.bold()).foregroundStyle(.secondary)
            if workspace.project.scoreboard == nil {
                Button("Setup Teams…", action: openSetup)
            } else {
                liveScoreLine
            }
            Divider()
            tagButtons
            Divider()
            eventsList
        }
        .padding(8)
    }

    private var liveScoreLine: some View {
        HStack {
            if let s = currentState() {
                Text("\(s.home.name) \(s.homeScore) – \(s.awayScore) \(s.away.name)")
                Spacer()
                Text(formatClock(s.clock).main).monospacedDigit()
            } else {
                Text(workspace.project.scoreboard.map { "\($0.home.name) – \($0.away.name)" } ?? "—")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private var tagButtons: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tag event at current time:").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("1H Start") { workspace.tagMatchEvent(.gameStart) }
                Button("1H End")   { workspace.tagMatchEvent(.firstHalfEnd) }
                Button("2H Start") { workspace.tagMatchEvent(.secondHalfBegin) }
                Button("2H End")   { workspace.tagMatchEvent(.gameEnd) }
            }
            HStack {
                Button("Home Goal  G") { workspace.tagMatchEvent(.homeGoal) }
                Button("Away Goal  H") { workspace.tagMatchEvent(.awayGoal) }
            }
        }
        .controlSize(.small)
        .disabled(workspace.project.scoreboard == nil)
    }

    private var eventsList: some View {
        VStack(alignment: .leading) {
            Text("Events").font(.caption).foregroundStyle(.secondary)
            ForEach(sortedEvents()) { rec in
                HStack {
                    Text(timestamp(for: rec)).monospacedDigit().font(.caption2)
                    Text(label(for: rec.kind)).font(.caption)
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
    private func label(for kind: MatchEventKind) -> String {
        switch kind {
        case .gameStart:        return "1H Start"
        case .firstHalfEnd:     return "1H End"
        case .secondHalfBegin:  return "2H Start"
        case .gameEnd:          return "2H End"
        case .homeGoal:         return "Home Goal"
        case .awayGoal:         return "Away Goal"
        }
    }
}
```

- [ ] **Step 2: Mount in `ContentView.swift`**

Find the scanning-mode inspector area. Add:
```swift
if workspace.appMode == .scanning {
    MatchInspectorPanel(workspace: workspace, openSetup: { showMatchSetup = true })
}
```
(Pick whichever existing inspector tab/panel structure the app uses — don't invent a new layout.)

- [ ] **Step 3: Build + manual test + commit**

Run: `xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build`
Launch. Configure teams. Click tag buttons in scanning mode. Verify events appear, seek works, delete works.

```bash
git add apple/App/Views/Scoreboard/MatchInspectorPanel.swift apple/App/ContentView.swift
git commit -m "feat(app): MatchInspectorPanel with tag buttons + events list"
```

---

## Task 15: Keyboard shortcuts via `KeyCommandView`

**⚠️ Collision note.** `KeyCommandView` already binds `1`/`2`/`3` to source-zoom controls (`KeyCommandView.swift:182-204`) in `.scanning`/`.recording` modes. A SwiftUI `.onKeyPress(["1","2","3","4"])` higher in the chain would never fire — the AppKit monitor consumes the events first. This task **extends `KeyCommandView`** rather than fighting it, inheriting its existing `firstResponder is NSText` text-field gate for free.

**Policy:** When `workspace.project.scoreboard != nil`, `1`/`2`/`3`/`4` route to half tags and `g`/`h` route to goals (existing zoom-on-`1`/`2`/`3` is suppressed for that mode). Without scoreboard configured, the existing zoom bindings are preserved unchanged. `Cmd+0` for zoom reset, mouse-wheel, and on-screen zoom toolbar remain available.

**Files:**
- Modify: `apple/App/Views/KeyCommandView.swift`
- Modify: `apple/App/ContentView.swift`

- [ ] **Step 1: Add `four`/`g`/`h` key codes**

In `KeyCommandView.swift`'s `KeyCode` enum (around line 63), append:
```swift
static let four: UInt16 = 0x15   // kVK_ANSI_4
static let g: UInt16 = 0x05      // kVK_ANSI_G
static let h: UInt16 = 0x04      // kVK_ANSI_H
```

- [ ] **Step 2: Add fields + closures on the representable and `KeyCatchingView`**

In `KeyCommandView` (the SwiftUI representable struct), add:
```swift
let scoreboardConfigured: Bool
let onTagHalf: (MatchEventKind) -> Void
let onTagGoal: (MatchEventKind) -> Void
```
In `KeyCatchingView` (the `NSView` subclass), mirror them as `var` properties initialized to defaults:
```swift
var scoreboardConfigured: Bool = false
var onTagHalf: (MatchEventKind) -> Void = { _ in }
var onTagGoal: (MatchEventKind) -> Void = { _ in }
```
In `updateNSView(_:context:)` (or `makeNSView`), propagate them onto the view.

- [ ] **Step 3: Extend the `.keyDown` monitor switch**

Modify the existing `case KeyCode.one, KeyCode.two, KeyCode.three:` arm to also handle `KeyCode.four` and route to tagging when scoreboard is configured:

```swift
case KeyCode.one, KeyCode.two, KeyCode.three, KeyCode.four:
    let modSignificant: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
    guard event.modifierFlags.intersection(modSignificant).isEmpty else { return event }
    switch self.appMode {
    case .scanning, .recording:
        if self.scoreboardConfigured {
            let kind: MatchEventKind
            switch event.keyCode {
            case KeyCode.one:   kind = .gameStart
            case KeyCode.two:   kind = .firstHalfEnd
            case KeyCode.three: kind = .secondHalfBegin
            case KeyCode.four:  kind = .gameEnd
            default:            return event
            }
            self.onTagHalf(kind)
            return nil
        }
        // No scoreboard: preserve existing zoom behavior on 1/2/3; let 4 pass through.
        guard event.keyCode != KeyCode.four else { return event }
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

case KeyCode.g, KeyCode.h:
    let modSignificant: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
    guard event.modifierFlags.intersection(modSignificant).isEmpty else { return event }
    guard self.scoreboardConfigured else { return event }
    switch self.appMode {
    case .scanning, .recording:
        self.onTagGoal(event.keyCode == KeyCode.g ? .homeGoal : .awayGoal)
        return nil
    default:
        return event
    }
```

(The existing `textIsFocused` gate at the top of the monitor closure already short-circuits when a `TextField` is focused — the new shortcuts inherit it.)

- [ ] **Step 4: Wire the new closures in `ContentView.swift`**

At the `KeyCommandView(...)` construction site (around lines 339–357), pass:
```swift
scoreboardConfigured: workspace.project.scoreboard != nil,
onTagHalf: { workspace.tagMatchEvent($0) },
onTagGoal: { workspace.tagMatchEvent($0) },
```

- [ ] **Step 5: Build + manual test + commit**

Run: `xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build`
Launch. **With** scoreboard configured: press `1`/`2`/`3`/`4`/`G`/`H` in scanning — events appear, no zoom change. Click into Match Setup's team-name `TextField`, type "1234gh" — text enters the field, no tagging fires. **Without** scoreboard configured: `1`/`2`/`3` still control zoom; `4`/`G`/`H` do nothing (system beep is fine).

```bash
git add apple/App/Views/KeyCommandView.swift apple/App/ContentView.swift
git commit -m "feat(app): match-tagging shortcuts via existing KeyCommandView monitor"
```

---

## Task 16: `ScoreboardOverlayView` (scan + record)

**Files:**
- Create: `apple/App/Views/Scoreboard/ScoreboardOverlayView.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI
import AppKit
import VideoCoachCore

struct ScoreboardOverlayView: NSViewRepresentable {
    let workspace: Workspace

    func makeNSView(context: Context) -> ScoreboardLayerView {
        let v = ScoreboardLayerView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    func updateNSView(_ nsView: ScoreboardLayerView, context: Context) {
        let next: ScoreboardState?
        if let player = workspace.sourcePlayer {
            next = scoreboardState(
                atSourceIndex: player.playlistPos,
                sourceSeconds: player.timePos,
                project: workspace.project)
        } else {
            next = nil
        }
        nsView.setStateIfChanged(next)
    }
}

final class ScoreboardLayerView: NSView {
    private var lastState: ScoreboardState?

    override var isFlipped: Bool { true }   // top-left user space

    func setStateIfChanged(_ s: ScoreboardState?) {
        if s != lastState {
            lastState = s
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let state = lastState else { return }
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        drawScoreboard(into: cg, size: bounds.size, state: state)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
```

- [ ] **Step 2: Build + commit**

Run: `xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build`
Expected: SUCCESS.

```bash
git add apple/App/Views/Scoreboard/ScoreboardOverlayView.swift
git commit -m "feat(app): ScoreboardOverlayView for scan/record"
```

---

## Task 17: Mount scan + record overlays

**Files:**
- Modify: `apple/App/ContentView.swift` (and recording-mode view if separate)

- [ ] **Step 1: Locate the scanning-mode `ZStack`** wrapping the source `MPVPlayerView`. Add inside (after the player view so it renders on top):
```swift
ScoreboardOverlayView(workspace: workspace)
    .allowsHitTesting(false)
```

- [ ] **Step 2: Locate the recording-mode `ZStack`** (may be in `ContentView.swift` or under `apple/App/Recording/`). Add the same overlay there.

- [ ] **Step 3: Build + manual test + commit**

Run: `xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build`
Launch. Configure teams + tag `gameStart` near source start. Scrub past the tag → scoreboard appears. Switch to recording mode → scoreboard appears there too. Pre-game → scoreboard absent.

```bash
git add apple/App/ContentView.swift
git commit -m "feat(app): mount scoreboard overlay in scan + record ZStacks"
```

---

## Task 18: `ScoreboardReplayOverlay` (preview)

**Files:**
- Create: `apple/App/Views/Scoreboard/ScoreboardReplayOverlay.swift`

**Note:** Preview compositions bake freezes via `scaleTimeRange` in `ClipPreviewBuilder.swift:184-187`, so composition time IS record time 1:1 within a single-clip preview (same model `StrokeReplayLayer` uses; see `StrokeReplayLayer.swift:136`). Record time → source time MUST go through `Clip.sourceTime(atRecordTime:)` in `PlaybackTimeline.swift` — the linear `clip.startSourceSeconds + recordTime` is wrong for any clip containing `.play`/`.pause`/`.skip` events (i.e. essentially every recorded clip), because freezes hold source time still while record time advances.

- [ ] **Step 1: Implement**

```swift
import SwiftUI
import AppKit
import AVFoundation
import VideoCoachCore

struct ScoreboardReplayOverlay: NSViewRepresentable {
    let player: AVPlayer
    let clip: Clip
    let workspace: Workspace

    func makeNSView(context: Context) -> ScoreboardLayerView {
        let v = ScoreboardLayerView()
        context.coordinator.attach(player: player, view: v, clip: clip, workspace: workspace)
        return v
    }

    func updateNSView(_ nsView: ScoreboardLayerView, context: Context) {}

    static func dismantleNSView(_ nsView: ScoreboardLayerView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private weak var player: AVPlayer?
        private var token: Any?
        private weak var view: ScoreboardLayerView?
        private weak var workspace: Workspace?
        private var clip: Clip?

        func attach(player: AVPlayer, view: ScoreboardLayerView, clip: Clip, workspace: Workspace) {
            self.player = player
            self.view = view
            self.workspace = workspace
            self.clip = clip
            // 1 Hz suffices for whole-second clock updates.
            let interval = CMTime(value: 1, timescale: 1)
            token = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                self?.tick(compositionTime: time.seconds)
            }
        }

        func detach() {
            if let token, let player { player.removeTimeObserver(token) }
            token = nil
        }

        private func tick(compositionTime t: Double) {
            guard let workspace, let clip, let view else { return }
            // Composition time → record time is 1:1 in a single-clip preview
            // (freezes baked via scaleTimeRange in ClipPreviewBuilder).
            // Record time → source time MUST go through sourceTime(atRecordTime:)
            // to correctly hold source time still during .pause segments.
            let recordTime = max(0, min(t, clip.recordingDuration))
            let sourceSeconds = clip.sourceTime(atRecordTime: recordTime)
            let state = scoreboardState(
                atSourceIndex: clip.sourceIndex,
                sourceSeconds: sourceSeconds,
                project: workspace.project)
            view.setStateIfChanged(state)
        }
    }
}
```

- [ ] **Step 2: Build + commit**

Run: `xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build`
Expected: SUCCESS.

```bash
git add apple/App/Views/Scoreboard/ScoreboardReplayOverlay.swift
git commit -m "feat(app): ScoreboardReplayOverlay for clip preview (uses sourceTime mapping)"
```

---

## Task 19: Mount preview overlay

**Files:**
- Modify: `apple/App/ContentView.swift`

- [ ] **Step 1: Locate the preview `ZStack`** around `ContentView.swift:289-299` (holding `AVPlayerView`, `StrokeReplayOverlay`, `previewTextBar`).

- [ ] **Step 2: Add the overlay** alongside `StrokeReplayOverlay`:
```swift
if let avPlayer = previewAVPlayer, let clip = currentPreviewClip {
    ScoreboardReplayOverlay(player: avPlayer, clip: clip, workspace: workspace)
        .allowsHitTesting(false)
}
```
(Use whatever bindings `StrokeReplayOverlay` uses to get the `AVPlayer` and current `Clip` — copy that pattern.)

- [ ] **Step 3: Build + manual test + commit**

Run: `xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build`
Launch. Configure teams + tag `gameStart` + tag a `homeGoal`. Record (or use an existing) clip whose source-time spans the goal. Play in preview → scoreboard appears, score bumps at the goal moment. If the clip has a freeze segment: scoreboard clock holds during the freeze (this is the bug `sourceTime(atRecordTime:)` prevents).

```bash
git add apple/App/ContentView.swift
git commit -m "feat(app): mount ScoreboardReplayOverlay in preview ZStack"
```

---

## Task 20: End-to-end sanity sweep

- [ ] **Step 1: Run full test suite + build**

Run: `swift test --package-path apple/VideoCoachCore`
Expected: ALL PASS.

Run: `xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build`
Expected: SUCCESS, no new warnings.

- [ ] **Step 2: Manual smoke test**

Launch the freshly-built app. With one source video loaded:

1. Open Project → Match Setup; configure two teams with distinct colors; Save.
2. Scrub source video. Press `1` near the start.
3. Verify scoreboard appears in scan view; clock counts up.
4. Press `G` twice and `H` once. Verify score `2-1` and event list updates.
5. Press `2` for end of 1st half. Scrub past — verify "HT".
6. Press `3` for 2nd half begin. Verify clock resumes at 45:00.
7. Press `4` for game end. Verify "FT".
8. Cmd+Z several times — verify each tag undoes one at a time, in reverse order.
9. Record a clip spanning a goal. Open the clip in preview — verify scoreboard renders, score before/after goal moment matches.
10. Test a clip with a freeze segment — verify scoreboard clock holds steady during the freeze (not ticking through).
11. Export the clip. Open the output .mp4 — verify scoreboard burned in.
12. Close + reopen the project — verify scoreboard config + events persist.

- [ ] **Step 3: If anything regresses, debug and fix.** Otherwise, summarize delivered work.

---

## Notes for the implementer

- **Reuse `RGBA`.** It already exists in `Stroke.swift` — do not re-declare it.
- **`PreviewCompositor` is NOT touched.** Preview rendering of the scoreboard happens via the AppKit overlay (Task 18), not inside `PreviewCompositor`. `PreviewInstruction` is NOT extended. The reason is documented in `ClipPreviewBuilder.swift:253-262` — macOS 26 strips custom-compositor instruction subclasses on the playback path.
- **`drawTextBar` is not touched.** Earlier spec drafts proposed extracting it; that idea was dropped after the false-dedup justification was identified (see spec's decisions log).
- **Use `Clip.sourceTime(atRecordTime:)`** in the preview overlay — the linear `clip.startSourceSeconds + recordTime` would tick the clock through freeze segments. This is the canonical record→source mapper, already used elsewhere in the codebase.
- **`KeyCommandView` extension over `.onKeyPress`** — `1`/`2`/`3` already have zoom bindings; the existing AppKit monitor consumes them first and also provides the text-field gate for free.
- **TDD discipline** for new pure functions; UI tasks are visual-test-only. Don't add SwiftUI snapshot test infrastructure.
- **Build after every Swift change.** This codebase's convention (per user prefs) is to run `xcodebuild` after Swift edits before claiming a task done.
