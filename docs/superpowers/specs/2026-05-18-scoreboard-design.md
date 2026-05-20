# Virtual Scoreboard — Design Spec

**Date:** 2026-05-18
**Status:** Approved through brainstorming + two adversarial review passes
**Worktree:** `.claude/worktrees/scoreboard`

## Goal

Insert a Premier-League-broadcast-style scoreboard overlay into Coach Cutups that
appears in **every** visible context — source-video scanning, clip recording,
clip preview, and HEVC export. The user configures two teams (name, primary +
secondary color), a stadium and city, and a whole-match length, then tags the
six match events (1H start/end, 2H start/end, home goal, away goal) while
scanning. The overlay computes the displayed clock and score from those tags
purely as a function of the current source-video time.

Visual reference:

```
┌─────────────────────────────────────────────────────────┐
│ [home-color]    ARS  0 - 0  BUR     [away-color]  0:07  │
│ EMIRATES STADIUM LONDON                                 │
└─────────────────────────────────────────────────────────┘
```

## Architecture summary

- **Data:** Two additive fields on `Project` — `scoreboard: ScoreboardConfig?`
  and `matchEvents: [MatchEventRecord]`. `formatVersion` bumps 2 → 3.
  Backward-compatible: v2 projects load with both empty and behave identically
  to today.
- **Clock logic:** A single pure function `scoreboardState(absoluteTime:config:events:)`
  in `VideoCoachCore` that takes pre-resolved absolute times. A thin
  project-level convenience wrapper resolves the offsets. Returns `nil` when
  the scoreboard should be hidden.
- **Drawing:** A single CG function `drawScoreboard(into:size:state:)` in a
  new `Sources/VideoCoachCore/Overlays/` module. The export compositor calls
  it directly from its existing Stage-2 CGContext pass. The three live
  contexts (scan, record, preview) each mount an AppKit overlay `NSView`
  whose `draw(_:)` calls the **same** function. **One function → one look
  across all four contexts.**
- **Render-tier split mirrors existing precedent.** Strokes (`StrokeReplayLayer`)
  and the preview text bar (`previewTextBar`) already live as AppKit/SwiftUI
  overlays on top of `AVPlayerView` because `AVPlayer`'s playback path on
  macOS 26 strips custom-compositor instruction subclasses (see
  `ClipPreviewBuilder.swift:253-262`). The scoreboard joins them for the same
  reason. Export remains the only context that draws inside the AVFoundation
  compositor pipeline. Parity is enforced by the shared `drawScoreboard`
  function, not by call-site symmetry.

## 1. Data model

In `Sources/VideoCoachCore/Project.swift`:

```swift
// Reuses the existing RGBA type from Stroke.swift
// (public struct RGBA: Codable, Hashable, Sendable with normalized r,g,b,a: Double).

public struct TeamConfig: Codable, Hashable, Sendable {
    public var name: String           // "ARS" — short broadcast abbreviation
    public var primaryColor: RGBA     // main bar background
    public var secondaryColor: RGBA   // thin accent strip + score-divider tint
}

public struct ScoreboardConfig: Codable, Hashable, Sendable {
    public var home: TeamConfig
    public var away: TeamConfig
    public var stadium: String        // "EMIRATES STADIUM"
    public var city: String           // "LONDON"
    public var matchLengthSeconds: Int = 90 * 60   // whole match; half = /2
}

public enum MatchEventKind: String, Codable, Hashable, Sendable {
    case gameStart          // == 1st half begin
    case firstHalfEnd
    case secondHalfBegin
    case gameEnd            // == 2nd half end
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
    public var sourceIndex: Int       // index into project.sourceVideos
    public var sourceSeconds: Double  // time within that source
}

public struct Project: Codable, Hashable, Sendable {
    public var formatVersion: Int = 3
    // …existing fields…
    public var scoreboard: ScoreboardConfig? = nil
    public var matchEvents: [MatchEventRecord] = []
}

public extension Project {
    /// Replace any existing record of this half-kind **in place** (preserving
    /// the existing `id` for undo + SwiftUI ForEach stability); otherwise
    /// append.
    mutating func setHalfTag(
        _ kind: MatchEventKind,
        sourceIndex: Int,
        sourceSeconds: Double
    ) {
        precondition(kind.isHalfTag)
        if let i = matchEvents.firstIndex(where: { $0.kind == kind }) {
            matchEvents[i].sourceIndex = sourceIndex
            matchEvents[i].sourceSeconds = sourceSeconds
            // id intentionally preserved
        } else {
            matchEvents.append(
                .init(id: UUID(), kind: kind,
                      sourceIndex: sourceIndex, sourceSeconds: sourceSeconds)
            )
        }
    }

    mutating func appendGoal(
        _ kind: MatchEventKind,
        sourceIndex: Int,
        sourceSeconds: Double
    ) {
        precondition(kind == .homeGoal || kind == .awayGoal)
        matchEvents.append(
            .init(id: UUID(), kind: kind,
                  sourceIndex: sourceIndex, sourceSeconds: sourceSeconds)
        )
    }
}
```

### Invariants

- The four half-tags are at-most-one per project. `setHalfTag` enforces this
  by replacing in-place; the existing `id` is preserved so undo records a
  single "edit timestamp" entry and the SwiftUI events list animates the
  row rather than tearing it down and re-inserting.
- `homeGoal` / `awayGoal` are unlimited; `appendGoal` always appends.
- Source-time ordering is *not* enforced at the data layer. The clock logic
  reads whatever timestamps are stored; the tagging UI surfaces a non-blocking
  warning if a placement is inconsistent (e.g. `firstHalfEnd` before
  `gameStart`).
- `MatchEventRecord.id` is stable across replaces. SwiftUI `ForEach` keys on
  it; `(kind, sourceSeconds)` would collide for two goals tagged in the same
  source second and array index would shift on row deletion.

## 2. Clock semantics

```swift
public enum ClockDisplay: Equatable, Sendable {
    /// Clock running normally. `seconds` measured from kickoff:
    /// 0…halfLen during 1H, halfLen…matchLen during 2H.
    case running(seconds: Double)
    /// Stoppage time. Main clock frozen at `baseSeconds` (= halfLen at end
    /// of 1H, = matchLen at end of 2H); `+M:SS` overlay counts `plusSeconds`.
    case stoppage(baseSeconds: Double, plusSeconds: Double)
    case halftime    // "HT"
    case fulltime    // "FT"
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

public struct AbsoluteMatchEvent: Equatable, Sendable {
    public let absSeconds: Double
    public let kind: MatchEventKind
}

/// Canonical pure function. Compositors call this directly (their
/// instructions carry pre-resolved absolute times so the cumulative-offset
/// walk doesn't happen on AVFoundation's render queue).
public func scoreboardState(
    absoluteTime now: Double,
    config: ScoreboardConfig,
    events: [AbsoluteMatchEvent]
) -> ScoreboardState?

/// Convenience for live (scan/record/preview) call sites that have a
/// `Project` + a `(sourceIndex, sourceSeconds)` pair. One-line wrapper that
/// walks `project.cumulativeOffset` once and delegates.
public func scoreboardState(
    atSourceIndex sourceIndex: Int,
    sourceSeconds: Double,
    project: Project
) -> ScoreboardState?
```

### Time mapping

The project's sources form a virtual concat in `sourceVideos` order. Define

```
abs(t) = project.cumulativeOffset(forSourceIndex: t.sourceIndex) + t.sourceSeconds
```

(`Project.cumulativeOffset` already exists.) **The cumulative-offset walk
happens once per call at the project-level wrapper or once per
instruction-build at the export planner — never on AVFoundation's render
queue.**

### Returns `nil` if

- `config == nil`, OR
- either team's `name` is empty, OR
- no `gameStart` event is in `events`, OR
- `now < abs(gameStart)`

### Otherwise

Compute `halfLen = Double(config.matchLengthSeconds) / 2.0` (Double division —
correct for odd-minute matches). Let `tStart, tH1End, tH2Start, tEnd` be the
absolute times of the corresponding half-tags from `events`.

**Missing-tag fallback (apply in this order, before consulting the table):**

- If `tH1End` is missing but `tH2Start` is present, set `tH1End := tH2Start`
  (skips HT entirely; avoids the false "1H stoppage past actual play, then
  jump to 2H" artifact when the user forgot the end-of-1H tag).
- If `tH2Start` is missing but `tH1End` is present, leave `tH2Start := +∞`
  (HT shows indefinitely until 2H is tagged).
- If `tEnd` is missing, leave `tEnd := +∞`.

Then:

| Condition | `ClockDisplay` |
|---|---|
| `now < tH1End` and `now − tStart ≤ halfLen` | `.running(now − tStart)` |
| `now < tH1End` and `now − tStart > halfLen` | `.stoppage(halfLen, now − tStart − halfLen)` |
| `tH1End ≤ now < tH2Start` | `.halftime` |
| `tH2Start ≤ now < tEnd` and `halfLen + (now − tH2Start) ≤ matchLen` | `.running(halfLen + (now − tH2Start))` |
| `tH2Start ≤ now < tEnd` and `halfLen + (now − tH2Start) > matchLen` | `.stoppage(matchLen, halfLen + (now − tH2Start) − matchLen)` |
| `now ≥ tEnd` | `.fulltime` |

The `tH1End` boundary is strict `<` (not `≤`) so that when the missing-tag
fallback `tH1End := tH2Start` fires, the instant `now == tH2Start` falls
through to 2H running rather than getting pinned to 1H stoppage. The cost is
a 1-frame off-by-one when an explicit `firstHalfEnd` tag is present (that
exact instant shows HT instead of the final 1H-stoppage frame) — acceptable.

### Scores

`homeScore` is the count of `.homeGoal` records in `events` satisfying **all
three** conditions; `awayScore` analogous for `.awayGoal`:

1. `absSeconds ≤ now`
2. `absSeconds ≥ abs(gameStart)`
3. `absSeconds ≤ tEnd` (where `tEnd = +∞` if `gameEnd` is missing)

Goals tagged outside the game span are ignored — they're almost certainly
mistakes (the `G`/`H` shortcuts are easy to fire while seeking pre-kickoff
footage). Goals tagged between `tH1End` and `tH2Start` (during HT) do count;
they appear in the score the moment HT begins, which matches real-broadcast
HT graphics that already reflect 1H goals.

### Cost

The function is O(events.count) per call. `events` is bounded by ~10–20 per
match (4 half-tags + a handful of goals), so per-frame recomputation in the
export compositor is trivial; no per-instruction state-transition
pre-computation needed.

## 3. Overlays module

New `Sources/VideoCoachCore/Overlays/Scoreboard.swift`:

```swift
func drawScoreboard(into cg: CGContext, size: CGSize, state: ScoreboardState)
```

Assumes the caller has set up a top-left user-space (matching the convention
already established by `CompilationCompositor.startRequest` after its
`translateBy/scaleBy(-1)` flip, and matching what an AppKit
`NSView.draw(_:)` provides through `NSGraphicsContext.current!.cgContext`).
The function does its own CoreText bottom-left save/restore dance internally,
the same way today's `drawTextBar` does.

(We do NOT touch the existing `drawTextBar` in this work. The "Adjacent
refactor" idea from earlier drafts was based on a misreading — `drawTextBar`
isn't duplicated between `CompilationCompositor` and `PreviewCompositor`; it
only exists in the former, because the preview text bar is a SwiftUI overlay
in `ContentView.swift:458`. The new `Overlays/Scoreboard.swift` file earns
its place on the scoreboard's own merits — it's called from one compositor
plus three AppKit overlay views.)

### Scoreboard layout (drawn by `drawScoreboard`)

Anchored **top-left** of the output frame, scaled relative to frame height so
the bar reads the same at 1080p as at source-resolution exports.

```
height ≈ 8% of frame height
width  ≈ 36% of frame width
margin ≈ 1.5% of frame height from top & left edges

[home primary]│center divider│[away primary]│clock cell
HOME 0  -  0 AWAY                            0:07
[home accent strip 8% of bar height across top]
[away accent strip mirrored on its half]

Stadium / city band sits flush below the score row, half-height, 80%-opacity
black background, "STADIUM" bold then " CITY" lighter.
```

Implementation: pure CG + CoreText, mirroring the patterns in today's
`drawTextBar`. White text on team-primary backgrounds; we don't compute
contrast automatically — the user picks the colors.

`ClockDisplay` → string formatting (extracted as a free `formatClock(_:) -> ClockLabels`
helper so it can be unit-tested without a CG context):

- `.running(s)` → main: `MM:SS` (zero-padded minutes), trailing: empty
- `.stoppage(base, plus)` → main: `MM:SS` of `base`, trailing: `+M:SS` of `plus`
- `.halftime` → main: `HT`, trailing: empty
- `.fulltime` → main: `FT`, trailing: empty

## 4. Render integration in all four contexts

| Context | Wiring |
|---|---|
| **Source scan** | `ScoreboardOverlayView` (`NSViewRepresentable` → CALayer-backed `NSView`) mounted in the same `ZStack` as `MPVPlayerView`, sized to its frame, `allowsHitTesting(false)`. The view observes `workspace.sourcePlayer?.timePos` / `playlistPos` (already `@MainActor`/`@Observable`, updated by the mpv event pump on every `time-pos` property change). SwiftUI's `updateNSView` body fires on each change, computes `scoreboardState(atSourceIndex:sourceSeconds:project:)`, and calls `nsView.setNeedsDisplay(_:)` only when the result differs from `lastState`. `NSView.draw(_:)` calls `drawScoreboard(into: NSGraphicsContext.current!.cgContext, size: bounds.size, state: state)`. See "Scan refresh driver" below. |
| **Clip recording** | Same `ScoreboardOverlayView` mounted above the recording-mode `MPVPlayerView`, as a visual aid for the operator. **The overlay is *not* burned into the saved clip** — clips persist only as a webcam `.mov` + event log + a reference into the source video. The scoreboard is re-rendered fresh by the preview/export paths using whatever the project's scoreboard config / match events are at render time. |
| **Clip preview** | A new `ScoreboardReplayOverlay: NSViewRepresentable` mounted in the existing preview `ZStack` (`ContentView.swift:289-299`) alongside `StrokeReplayOverlay` and `previewTextBar`. Follows the **`StrokeReplayLayer` pattern exactly** (`apple/App/Preview/StrokeReplayLayer.swift`): an `AVPlayer.addPeriodicTimeObserver` at 1 Hz on the main queue, maps composition time → record time by walking `playbackSegments` the same way `StrokeReplayLayer` does, then computes `scoreboardState(atSourceIndex:sourceSeconds:project:)` from `workspace.project`. `setNeedsDisplay(_:)` only on state change; `draw(_:)` calls the same `drawScoreboard`. **The preview path does NOT touch `PreviewCompositor` — strokes and the text bar don't either, for the same documented macOS 26 reason** (`ClipPreviewBuilder.swift:253-262`). `PreviewInstruction` is NOT extended. |
| **Export** | `CompilationCompositor.startRequest`'s existing Stage-2 CGContext pass adds one block: after `drawTextBar(...)`, if `let s = scoreboardState(absoluteTime: clipStartAbs + recordTime, config:, events:)` then `drawScoreboard(into: cg, size: size, state: s)`. `CompilationInstruction` is extended with the fields below. |

### Parity invariant (revised)

**One `drawScoreboard` function produces the pixels in every context.** Three
contexts call it from `NSView.draw(_:)`; one (export) calls it from a
CGContext bound to the composition output buffer. Both call shapes pass a
top-left CG context and identical state; the function is bit-identical
regardless of who called it.

This is the same render-tier split that already exists for strokes and the
preview text bar. Inventing a 4-context-symmetric compositor architecture to
re-establish call-site symmetry would re-introduce the macOS 26 black-playback
bug `ClipPreviewBuilder` deliberately works around.

### Scan refresh driver

**No display link.** `MPVSourcePlayer` is `@MainActor`/`@Observable`; its
`timePos: Double` and `playlistPos: Int` are written on the main actor by the
mpv event pump on every `time-pos` property-change event (~10–60 Hz during
playback, 0 Hz while paused). The `ScoreboardOverlayView` representable
observes those values transitively via `workspace.sourcePlayer`; SwiftUI's
`updateNSView` fires on each change and calls `nsView.setNeedsDisplay(_:)`
only when `scoreboardState(...)` differs from a stored `lastState:
ScoreboardState?` on the view.

This avoids `CVDisplayLink` (deprecated on macOS 14+, fires on a private
background thread → `@MainActor` data race) and `CADisplayLink` (overkill
for a 1-second-granularity, non-animated clock). It also avoids any
lifecycle management — SwiftUI handles view appear/disappear naturally.

If empirical testing shows mpv's `time-pos` events miss a boundary (extremely
unlikely — they fire on every demuxed frame), the fallback is a
`Timer.publish(every: 0.5, on: .main, in: .common)` driving a `@State` tick.
Still no display link.

The clip-recording overlay reuses the same representable. The preview overlay
uses `AVPlayer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 1), queue: .main)` — 1 Hz suffices for whole-second clock updates and matches the cadence `StrokeReplayLayer` would use if it cared about whole seconds.

### Instruction payload (export only)

`CompilationInstruction` gains three fields. `PreviewInstruction` does **not**
change — the preview overlay reads from `workspace.project` directly, the
way `StrokeReplayLayer` reads clip events.

```swift
var scoreboardConfig: ScoreboardConfig?
var matchEventsAbs: [AbsoluteMatchEvent]   // pre-resolved at planner time
var clipStartAbsSeconds: Double            // pre-resolved at planner time
```

Both `matchEventsAbs` and `clipStartAbsSeconds` are computed once at
instruction-build time on the main thread using `Project.cumulativeOffset` —
**the AVFoundation render queue never walks the source list**. This
eliminates both the unchecked-subscript-on-private-queue hazard and the
duplicate-state smell of carrying the whole cumulative-offsets array per
instruction.

Per-frame in `CompilationCompositor.startRequest`:

```swift
let absNow = inst.clipStartAbsSeconds + recordTime
if let cfg = inst.scoreboardConfig,
   let state = scoreboardState(absoluteTime: absNow,
                               config: cfg,
                               events: inst.matchEventsAbs) {
    drawScoreboard(into: cg, size: size, state: state)
}
```

## 5. Tagging UI

A "Match" inspector panel visible whenever scanning mode is active.

```
MATCH
─────────────────────────────────────
[Setup Teams…]   (or: HOME 0 – 0 AWAY  ●●:●●)

Tag event at current time:
[ 1H Start ] [ 1H End ] [ 2H Start ] [ 2H End ]
[ Home Goal  G ] [ Away Goal  H ]

Events (chronological)
─────────────────────────────────────
00:02:11   1H Start                  ⌫
00:23:48   Home Goal                 ⌫
00:47:05   1H End                    ⌫
…
```

Clicking an event row seeks the source player to that time. The trash icon
removes it (undoable). Re-tagging a half-tag prompts a small inline confirm
("Replace existing 1H Start at 00:02:11?") — single click to confirm; goals
have no such prompt since they're unlimited.

### Keyboard shortcuts

Active when the scanning view has focus and no text field is editing:

| Key | Event |
|---|---|
| `1` | `gameStart` (1H start) |
| `2` | `firstHalfEnd` |
| `3` | `secondHalfBegin` |
| `4` | `gameEnd` (2H end) |
| `G` | `homeGoal` |
| `H` | `awayGoal` |

All tags capture `(sourceIndex, sourceSeconds)` from the current source player
position at keystroke time. Each action goes through the existing
`UndoController` (see below).

### Undo integration

`UndoController.UndoAction` gains one case:

```swift
case editMatchEvents(before: [MatchEventRecord], after: [MatchEventRecord])
```

All tag/untag/replace operations go through `Workspace.mutateMatchEvents`,
which:

1. Captures `before = project.matchEvents`.
2. Applies the mutation (via `Project.setHalfTag`, `Project.appendGoal`, or
   a direct `remove(id:)`).
3. Pushes `.editMatchEvents(before:, after: project.matchEvents)` via
   `undoController.pushEdit(_:)`.

`Workspace.undo()` / `redo()` gain a switch arm that assigns the snapshot
back to `project.matchEvents`. The list is bounded (~10–20 entries) so the
per-step copy cost is negligible, and snapshot symmetry matches the existing
`editClip` and `reorderClips` precedent. No coalescing — every keyboard-shortcut
press is its own undo step, the same granularity users expect from clip edits.

## 6. Team config UI

New `Project → Match Setup…` menu item (and an empty-state button in the
Match panel) opens a small sheet:

```
Match Setup
──────────────────────────────────────────
Home Team
  Name      [ ARS                       ]
  Primary   [■]  Secondary  [■]   (NSColorWell)

Away Team
  Name      [ BUR                       ]
  Primary   [■]  Secondary  [■]

Venue
  Stadium   [ EMIRATES STADIUM          ]
  City      [ LONDON                    ]

Match length [  90  ] minutes

                              [ Cancel ]  [ Save ]
```

Colors use the standard macOS `NSColorWell` — full system picker incl.
eyedropper and hex entry. Saved to `project.scoreboard`. Empty fields are
allowed; the scoreboard only renders during playback once both team names
are non-empty AND `gameStart` is tagged.

**Availability.** `Project → Match Setup…` is enabled at all times, including
during scanning, clip recording, and active export. In-flight exports keep
the `scoreboardConfig` snapshot they captured at composition-build time, so
edits do not affect a render in progress. Scan, record, and preview overlays
read live and pick up the new config on their next observer-driven refresh.

## 7. Persistence / migration

- `Project.formatVersion`'s default bumps 2 → 3.
- `ProjectStore.read` widens its accepted range from `1...2` to `1...3`.
  The comment block on the guard is updated to mention v3 = added scoreboard
  config + match events.
- `ProjectStore.write` sets `formatVersion = 3` unconditionally before
  encoding (it does not today — it just encodes the in-memory value). The
  on-disk schema becomes v3 the first time any project is saved by the new
  code, even if its scoreboard fields are empty.
- Reading v2 JSON: `scoreboard = nil`, `matchEvents = []`, `formatVersion`
  reads back as the literal `2`. App behavior is identical to today until
  the next save bumps the file to v3.
- No imperative migration step — additive fields with defaults handle it.

## 8. Testing strategy

- **`scoreboardState` unit tests** — one test per `ClockDisplay` branch
  (pre-game returns nil; 1H running; 1H stoppage; HT; 2H running; 2H stoppage;
  FT) plus edge cases (missing `secondHalfBegin` → HT indefinitely; missing
  `firstHalfEnd` but `secondHalfBegin` present → 1H clamps at 2H start, no
  HT; goals before `gameStart` not counted; goals after `gameEnd` not
  counted; goals during HT counted; out-of-order tags don't crash).

- **`drawScoreboard` rendering tests** — three thin tests, not byte-compare
  baseline PNGs (CoreText AA varies across macOS minor versions, baselines
  are a re-baselining tax for marginal coverage):
  1. Pure-function `formatClock(_:) -> ClockLabels` (extracted as a free
     function in `Overlays/Scoreboard.swift`) with one assertion per
     `ClockDisplay` variant — `.running(125) → ("02:05", "")`,
     `.stoppage(2700, 47) → ("45:00", "+0:47")`, `.halftime → ("HT", "")`,
     `.fulltime → ("FT", "")`, `.running(0) → ("00:00", "")`,
     `.running(2700) → ("45:00", "")`.
  2. One smoke render per variant: invoke `drawScoreboard` into a fixed-size
     CGContext with a representative state, assert non-background pixels
     exist inside the expected bar rect and pixels outside are untouched.
     Catches "layout vanished," "drew at wrong origin," "bar rect wrong size"
     without coupling to font-rendering details.
  3. One color-anchor test: set `home.primaryColor = (1,0,0,1)`,
     `away.primaryColor = (0,0,1,1)`, render, sample home-cell center and
     away-cell center with the existing `PixelSampling.averageRGB` helper
     (`Tests/Helpers/PixelSampling.swift`), assert dominant channel matches
     with ±0.10 tolerance — same pattern `CompilationExporterE2ETests` uses.
     Catches "swapped home/away," "color not applied," "wrong cell coords."

- **Format-version migration tests** in `ProjectTests.swift`, following the
  existing inline-JSON pattern in
  `test_preferencesDeviceIDs_decodeFromLegacyJSONMissingKeys`:
  1. `test_v2JSON_decodesWithEmptyScoreboardDefaults` — inline a v2 JSON
     literal lacking `scoreboard` and `matchEvents` keys; decode; assert
     defaults populate and `formatVersion == 2`.
  2. `test_saveBumpsFormatVersionToCurrent` — write a Project with
     `formatVersion = 2` via `ProjectStore.write`, re-read, assert
     `formatVersion == 3`.
  3. `test_projectWithScoreboardConfigRoundtrips` — populate scoreboard
     with non-default config + a handful of `MatchEventRecord`s, round-trip
     through `JSONEncoder` / `JSONDecoder`, assert structural equality.

- **Export pixel-anchor integration test** — add one method to
  `CompilationExporterE2ETests.swift`. Use the existing `FiducialAsset`
  source already wired up in setUp. Configure
  `home.primaryColor = (1,0,0,1)`, `away.primaryColor = (0,0,1,1)`, tag
  `gameStart` at source(0, 1.0), run a real export, sample a frame inside
  the configured clip window via the existing `sampleFrame(of:atOutputTime:)`
  helper. Probe the expected home and away cell centers of the scoreboard
  rect with `PixelSampling.averageRGB`; assert R > 0.6 / B < 0.3 for home
  and B > 0.6 / R < 0.3 for away. Catches the full
  `Project.scoreboard` → `CompilationInstruction.scoreboardConfig` →
  `drawScoreboard` → output pixels plumbing in one test, using infra that
  already exists.

## Non-goals (YAGNI)

- Team logos / crests
- Possession, shots-on-target, or other stats
- Substitution / card events
- Stoppage-time cap (real broadcasts cap at e.g. +5; we let it count freely)
- Per-export or per-clip "hide scoreboard" toggle
- Multiple matches per project
- Editing a placed event's timestamp via drag (delete + re-tag instead)
- Animation / transitions when score changes
- Auto-detection of high-contrast text color from team primary
- Coalescing rapid undo entries (each keypress = one undo, matches existing
  clip-edit granularity)

## Decisions log

| Decision | Chosen | Rejected alternatives | Why |
|---|---|---|---|
| Clock model | PL broadcast clock (1H 0→halfLen, stoppage `+M:SS`, HT, 2H halfLen→matchLen, stoppage `+M:SS`, FT) | "Pure source-elapsed"; "per-half elapsed only" | Matches real broadcast feel; user requirement |
| Off-clock states | Hide before kickoff; HT between halves; FT after | "Always show, freeze clock"; "always show with bare labels" | PL convention; less visual noise pre-game |
| Tagging UX | Visible Match panel + keyboard shortcuts | "Shortcuts only"; "scrub-bar menu" | Discoverable + fast for power users |
| Event multiplicity | Halves at-most-one (replace, preserve `id`); goals unlimited (append) | "All single-shot"; "all unlimited" | Matches real match shape; goals are countable events, halves are state transitions |
| Config gating | Optional; scoreboard hides when missing | "Required at project open"; "required to enable Match panel" | Doesn't disrupt existing projects; non-modal |
| Colors per team | Two (primary + secondary) | "One color"; "hex+swatches simpler" | Matches real broadcast graphics |
| Location | Stadium + City (two fields) | "Single free-text"; "skip entirely" | Visual hierarchy from screenshot |
| Render-tech split | One CG function (`drawScoreboard`) called from 1 compositor + 3 AppKit overlay views | Rasterize SwiftUI per frame + cache; two parallel renderers + snapshot-tested parity | Parity is structural (one function); the asymmetry of call sites (3 AppKit + 1 compositor) mirrors the existing strokes/text-bar split, which exists for the documented macOS 26 custom-compositor strip |
| Preview path integration | AppKit overlay reading `workspace.project`, observing `AVPlayer.addPeriodicTimeObserver` | Extend `PreviewInstruction` and draw inside `PreviewCompositor` | `PreviewCompositor` doesn't run on the preview playback path on macOS 26 (custom compositor stripped); strokes/text-bar already work this way for the same reason |
| Scan refresh primitive | Observe `@Observable MPVSourcePlayer.timePos`; diff-and-`setNeedsDisplay` | `CVDisplayLink` (deprecated, background thread, data race); `CADisplayLink` (overkill); `Timer` at 4 Hz | The data source already pushes main-actor updates on every mpv `time-pos` event; observation is already how the rest of the app reads playback state |
| Scoreboard state pre-resolution | Precompute `clipStartAbsSeconds` + `matchEventsAbs` at planner time | Carry `sourceCumulativeOffsets: [Double]` per instruction; recompute on render queue | AVFoundation's render queue should not walk project state; precomputation avoids both an unchecked subscript hazard and duplicate-state-per-instruction |
| `scoreboardState` API | Canonical absolute-time function + one-line project-time convenience | Two parallel functions of equal weight | Compositor uses absolute; UI uses project — wrapper is the cheapest possible adapter |
| `MatchEventRecord.id` | Stable UUID, preserved across half-tag replace | Drop the id; use `(kind, sourceSeconds)` for SwiftUI identity | `sourceSeconds` collides on duplicate-instant goals; array index shifts on delete; only stable id is safe for SwiftUI `ForEach` |
| `ClockDisplay.stoppage` payload | Both fields `Double` | Mixed `Int`/`Double`; drop `baseSeconds` and derive in renderer | Avoids type-mixing footgun; `baseSeconds` self-describes the frozen value to the renderer; odd-minute matches need `Double` division for `halfLen` |
| Missing-halftime-tag fallback | Pin `tH1End := tH2Start` when only `tH2Start` exists | Treat missing as `+∞` (spec's original); validate ordering in UI | One-line precedence rule, eliminates a real "false stoppage then jump" artifact for the common forget-1H-end case at zero complexity cost |
| Goal-in-game-span guard | Count goals only when `abs(gameStart) ≤ abs(goal) ≤ abs(tEnd)` | Count all goals with `abs ≤ now` | One-line guard, prevents single-keypress mistakes (errant `G`/`H` while seeking pre-kickoff footage) from silently corrupting the score |
| Undo for match events | Single `editMatchEvents(before:after:)` snapshot case in existing `UndoController` | Per-event cases; separate undo stack | Matches existing `editClip`/`reorderClips` snapshot precedent; bounded list makes snapshot cheap |
| `drawTextBar` extraction | Leave in `CompilationCompositor` | Move to shared `Overlays/` module along with `drawScoreboard` | Earlier draft claimed it was duplicated between compositors — it isn't. Preview's text bar is a SwiftUI overlay (`previewTextBar`), not CG. There's no CG-side dedup to do, and the SwiftUI-vs-CG parity is a different problem and intentionally out of scope |
| Snapshot-PNG variant tests | Pure-function format tests + smoke render + color-anchor probe | One baseline PNG per `ClockDisplay` variant | CoreText AA varies across macOS versions; baselines are a re-baselining tax; the three-test split catches the same bug classes with no fixture maintenance |
| Format-version test | Inline JSON literal in `ProjectTests` (existing pattern) | v2 fixture file in test bundle | Matches `test_preferencesDeviceIDs_decodeFromLegacyJSONMissingKeys`; no permanent fixture-file treadmill |
| Export integration test | Color-anchor probe via existing `FiducialAsset` + `PixelSampling` infra | OCR-the-rendered-digit; skip the test | Infra already exists (`CompilationExporterE2ETests` patterns); color anchoring exercises the full plumbing chain at ~30 LOC |
