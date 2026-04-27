# Video Coach Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a native macOS app that lets the user scan a soccer match video, record commentary clips with webcam + voice + freehand drawings, and export per-tag HEVC compilations.

**Architecture:** Swift + SwiftUI shell, all video work via AVFoundation. Pure-logic types (data model, event-log → source-time reconstruction, tag aggregation, export composition math) live in a local Swift Package (`VideoCoachCore`) for fast TDD via `swift test`. The app target (`VideoCoach`) wraps it in SwiftUI/AVKit, owns the `AVCaptureSession`, `AVPlayer`, and the `AVAssetWriter` export pipeline. Project state persists as a folder containing `project.json` + `recordings/` of `.mov` files.

**Tech Stack:** Swift 5.9+, SwiftUI, AVFoundation, AVKit, Core Animation, Core Media, VideoToolbox (implicit). XCTest for tests. XcodeGen for declarative `.xcodeproj` generation.

**Reference design:** [`2026-04-27-video-coach-design.md`](./2026-04-27-video-coach-design.md). Read it before starting any phase.

**Test strategy:**
- Pure-logic types (`VideoCoachCore`) → real TDD with `swift test`. Fast, deterministic, headless.
- AVFoundation integration (capture, player, composition, export) → small XCTest integration cases that build a 5-second synthetic asset and verify outputs. Plus manual verification per phase.
- UI → manual verification per phase, against a checklist. SwiftUI Previews where they help.

**Commit cadence:** commit after every passing test or completed step. Fast, small commits. Branch off `main` for each phase if working in a worktree.

---

## Phase 1 — Repo + project scaffold

> Adversarial-review fixes from two review passes are folded into this plan. Highlights: time anchor uses the first `AVCaptureVideoDataOutput` sample buffer's PTS (sub-frame accurate); freeze frames implemented via custom `AVVideoCompositing` (not `scaleTimeRange`); export uses `AVAssetExportSession` with a real spike (Task 9.0) that exercises a stub compositor + audio mix; HEVC container is `.mov`; bookmarks are non-security-scoped with stale-regen handling; capture format is explicit and configured *after* `addInput` (the canonical AVCam order); Workspace loader is properly async; per-instruction context flows via a `CompilationInstruction` subclass; Mode C clip preview is layered (separate AVPlayerLayer + CAShapeLayer overlay + text-bar view) instead of reusing the export's full compositor.

### Task 1.1: Add `.gitignore` and `README.md`

**Files:**
- Create: `.gitignore`
- Create: `README.md`

**Step 1:** Write `.gitignore`:

```gitignore
# Xcode
build/
DerivedData/
*.xcuserstate
xcuserdata/
*.xcworkspace/xcuserdata/

# Swift
.build/
Package.resolved
.swiftpm/

# macOS
.DS_Store

# XcodeGen
*.xcodeproj
```

**Step 2:** Write `README.md`:

```markdown
# Video Coach

Native macOS app for building tagged compilations of clips from full-length match videos.

See `docs/plans/` for design and implementation plans.

## Build

Requires Xcode 15+ and macOS 14+ (Apple Silicon).

```bash
brew install xcodegen
xcodegen generate
open VideoCoach.xcodeproj
```
```

**Step 3:** Commit:
```bash
git add .gitignore README.md
git commit -m "chore: add gitignore and README"
```

---

### Task 1.2: Create the `VideoCoachCore` Swift Package

**Files:**
- Create: `VideoCoachCore/Package.swift`
- Create: `VideoCoachCore/Sources/VideoCoachCore/Placeholder.swift`
- Create: `VideoCoachCore/Tests/VideoCoachCoreTests/PlaceholderTests.swift`

**Step 1:** Write `VideoCoachCore/Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VideoCoachCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VideoCoachCore", targets: ["VideoCoachCore"]),
    ],
    targets: [
        .target(name: "VideoCoachCore"),
        .testTarget(name: "VideoCoachCoreTests", dependencies: ["VideoCoachCore"]),
    ]
)
```

**Step 2:** Create source/test directories and a stub Swift file in each (SwiftPM requires at least one `.swift` per target — bare `.gitkeep`s won't compile):

`VideoCoachCore/Sources/VideoCoachCore/Placeholder.swift`:
```swift
// Replaced in Task 2.1.
```

`VideoCoachCore/Tests/VideoCoachCoreTests/PlaceholderTests.swift`:
```swift
import XCTest
final class PlaceholderTests: XCTestCase {
    func test_placeholder() { XCTAssertTrue(true) }
}
```

(Both files will be removed when the real types arrive in Phase 2.)

**Step 3:** Verify it builds:
```bash
cd VideoCoachCore && swift build
```
Expected: `Build complete!`

**Step 4:** Commit:
```bash
git add VideoCoachCore
git commit -m "feat: scaffold VideoCoachCore Swift package"
```

---

### Task 1.3: Create the XcodeGen project spec for the app target

**Files:**
- Create: `project.yml`
- Create: `App/Info.plist`
- Create: `App/VideoCoach.entitlements`
- Create: `App/VideoCoachApp.swift`
- Create: `App/ContentView.swift`

**Step 1:** Write `project.yml`:

```yaml
name: VideoCoach
options:
  bundleIdPrefix: com.videocoach
  deploymentTarget:
    macOS: "14.0"
  developmentLanguage: en
packages:
  VideoCoachCore:
    path: VideoCoachCore
targets:
  VideoCoach:
    type: application
    platform: macOS
    sources:
      - App
    dependencies:
      - package: VideoCoachCore
    info:
      path: App/Info.plist
      properties:
        NSCameraUsageDescription: Video Coach uses your camera to record commentary on match clips.
        NSMicrophoneUsageDescription: Video Coach uses your microphone to record commentary on match clips.
        CFBundleDisplayName: Video Coach
        LSMinimumSystemVersion: "14.0"
    settings:
      base:
        CODE_SIGN_ENTITLEMENTS: App/VideoCoach.entitlements
        CODE_SIGN_STYLE: Automatic
        ENABLE_HARDENED_RUNTIME: YES
        SWIFT_VERSION: 5.9
        MACOSX_DEPLOYMENT_TARGET: "14.0"
        ARCHS: arm64
```

**Step 2:** Write `App/VideoCoach.entitlements` (XML plist):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.camera</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
```

**Step 3:** Write the minimum app shell.

`App/VideoCoachApp.swift`:
```swift
import SwiftUI

@main
struct VideoCoachApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1100, minHeight: 700)
        }
    }
}
```

`App/ContentView.swift`:
```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        Text("Video Coach")
            .font(.largeTitle)
            .padding()
    }
}
```

**Step 4:** Generate and open the Xcode project:
```bash
brew install xcodegen   # if not already installed
xcodegen generate
```
Expected output ends with `Created project at /…/VideoCoach.xcodeproj`.

**Step 5:** Open in Xcode and run once to verify the empty window appears:
```bash
open VideoCoach.xcodeproj
```
Press `⌘R`. Expected: a blank window with "Video Coach" centered.

**Step 6:** Commit:
```bash
git add project.yml App/
git commit -m "feat: scaffold VideoCoach app target via XcodeGen"
```

---

### Task 1.4: Codesigning + first-launch permission preflight

Hardened-runtime apps with camera + mic entitlements pop two TCC dialogs on first launch. If the user denies either, capture initialization throws. We need a stable signing identity (so permission grants survive relaunch) and a UI that explains what to do on denial.

**Files:**
- Create: `scripts/sign.sh`
- Modify: `App/ContentView.swift`

**Step 1:** Write `scripts/sign.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
APP="${1:-build/Debug/VideoCoach.app}"
IDENTITY="${VIDEO_COACH_IDENTITY:-Apple Development}"
codesign --force --deep --options runtime \
  --entitlements App/VideoCoach.entitlements \
  --sign "$IDENTITY" "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | head -10
```

```bash
chmod +x scripts/sign.sh
```

**Step 2:** Document expected first-launch flow in `README.md`:

> First launch will pop two macOS permission dialogs (camera, microphone). Approve both. If denied, re-grant via System Settings → Privacy & Security → Camera / Microphone → Video Coach. TCC normally persists grants across rebuilds when bundle ID, Team ID, and entitlements are stable. A clean build folder, an Xcode major-version change, or a re-sign with a different identity may force re-granting — the empty-state UI handles this gracefully.

**Step 3:** Add a permission-denied empty state to `ContentView`. When the workspace's `CaptureSessionController.configure()` throws with `.permissionDenied`, display:

```swift
VStack {
    Text("Video Coach needs camera and microphone access.")
    Text("Open System Settings → Privacy & Security to grant permission, then relaunch.")
    Button("Open System Settings") {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }
}
```

**Step 4:** Commit:
```bash
git add scripts/sign.sh README.md App/ContentView.swift
git commit -m "feat: codesigning helper and permission-denied empty state"
```

---

## Phase 2 — Core data models (TDD)

All work in this phase happens inside `VideoCoachCore/`. Run tests with:
```bash
cd VideoCoachCore && swift test
```

### Task 2.1: `Stroke` and `StrokePoint`

**Files:**
- Create: `VideoCoachCore/Sources/VideoCoachCore/Stroke.swift`
- Create: `VideoCoachCore/Tests/VideoCoachCoreTests/StrokeTests.swift`

**Step 1:** Write the failing test (`StrokeTests.swift`):
```swift
import XCTest
@testable import VideoCoachCore

final class StrokeTests: XCTestCase {
    func test_strokeRoundtripsThroughJSON() throws {
        let stroke = Stroke(
            color: .init(r: 1, g: 0, b: 0, a: 1),
            lineWidth: 0.005,
            points: [
                .init(x: 0.1, y: 0.2, t: 0.0),
                .init(x: 0.5, y: 0.6, t: 0.05),
            ],
            autoClearAfterSeconds: 5.0
        )
        let data = try JSONEncoder().encode(stroke)
        let decoded = try JSONDecoder().decode(Stroke.self, from: data)
        XCTAssertEqual(decoded.points.count, 2)
        XCTAssertEqual(decoded.autoClearAfterSeconds, 5.0)
        XCTAssertEqual(decoded.color.r, 1.0)
    }
}
```

**Step 2:** Run, expect failure (`Cannot find 'Stroke' in scope`):
```bash
cd VideoCoachCore && swift test --filter StrokeTests
```

**Step 3:** Implement `Stroke.swift`:
```swift
import Foundation

public struct RGBA: Codable, Hashable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    public static let red = RGBA(r: 1, g: 0.2, b: 0.2, a: 1)
}

public struct StrokePoint: Codable, Hashable, Sendable {
    public var x: Double          // 0...1 of frame width
    public var y: Double          // 0...1 of frame height
    public var t: Double          // seconds since stroke start
    public init(x: Double, y: Double, t: Double) {
        self.x = x; self.y = y; self.t = t
    }
}

public struct Stroke: Codable, Hashable, Sendable {
    public var color: RGBA
    public var lineWidth: Double                    // normalized to frame height
    public var points: [StrokePoint]
    public var autoClearAfterSeconds: Double?       // nil = persist
    public init(color: RGBA, lineWidth: Double, points: [StrokePoint], autoClearAfterSeconds: Double?) {
        self.color = color
        self.lineWidth = lineWidth
        self.points = points
        self.autoClearAfterSeconds = autoClearAfterSeconds
    }
}
```

**Step 4:** Run, expect pass.

**Step 5:** Commit:
```bash
git add VideoCoachCore/Sources/VideoCoachCore/Stroke.swift VideoCoachCore/Tests/VideoCoachCoreTests/StrokeTests.swift
git commit -m "feat(core): Stroke and StrokePoint with JSON roundtrip"
```

---

### Task 2.2: `CommentaryEvent`

**Files:**
- Create: `VideoCoachCore/Sources/VideoCoachCore/CommentaryEvent.swift`
- Create: `VideoCoachCore/Tests/VideoCoachCoreTests/CommentaryEventTests.swift`

**Step 1:** Write tests covering each event variant + Codable roundtrip:

```swift
import XCTest
@testable import VideoCoachCore

final class CommentaryEventTests: XCTestCase {
    func test_allKindsRoundtripThroughJSON() throws {
        let stroke = Stroke(color: .red, lineWidth: 0.005,
            points: [.init(x: 0.1, y: 0.1, t: 0)], autoClearAfterSeconds: nil)
        let events: [CommentaryEvent] = [
            .init(recordTime: 0.0, kind: .play),
            .init(recordTime: 1.5, kind: .pause),
            .init(recordTime: 2.0, kind: .play),
            .init(recordTime: 3.0, kind: .skip(delta: -3)),
            .init(recordTime: 3.2, kind: .skip(delta: 3)),
            .init(recordTime: 4.0, kind: .stroke(stroke)),
            .init(recordTime: 5.0, kind: .clearAll),
        ]
        let data = try JSONEncoder().encode(events)
        let decoded = try JSONDecoder().decode([CommentaryEvent].self, from: data)
        XCTAssertEqual(decoded.count, 7)
        if case .skip(let d) = decoded[3].kind { XCTAssertEqual(d, -3) } else { XCTFail() }
        if case .stroke(let s) = decoded[5].kind { XCTAssertEqual(s.points.count, 1) } else { XCTFail() }
    }
}
```

**Step 2:** Run, expect failure.

**Step 3:** Implement `CommentaryEvent.swift`:

```swift
import Foundation

public struct CommentaryEvent: Codable, Hashable, Sendable {
    public var recordTime: Double
    public var kind: Kind
    public init(recordTime: Double, kind: Kind) {
        self.recordTime = recordTime
        self.kind = kind
    }

    public enum Kind: Codable, Hashable, Sendable {
        case play
        case pause
        case skip(delta: Double)
        case stroke(Stroke)
        case clearAll
    }
}
```

**Step 4:** Run, expect pass. Commit:
```bash
git add VideoCoachCore
git commit -m "feat(core): CommentaryEvent with Codable enum kinds"
```

---

### Task 2.3: `Clip`, `SourceRef`, `Project`, `Preferences`

**Files:**
- Create: `VideoCoachCore/Sources/VideoCoachCore/Project.swift`
- Create: `VideoCoachCore/Tests/VideoCoachCoreTests/ProjectTests.swift`

**Step 1:** Write tests covering construction defaults, tag normalization, and a full project JSON roundtrip:

```swift
import XCTest
@testable import VideoCoachCore

final class ProjectTests: XCTestCase {
    func test_normalizeTags_splitsOnCommaTrimsLowercasesAndDedupes() {
        XCTAssertEqual(
            Tag.normalize(input: " Attacking-Chance, transitions , set,piece, transitions "),
            ["attacking-chance", "transitions", "set", "piece"]
        )
    }

    func test_emptyProjectRoundtripsThroughJSON() throws {
        let p = Project(name: "MyMatch")
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(decoded.name, "MyMatch")
        XCTAssertEqual(decoded.formatVersion, 1)
        XCTAssertTrue(decoded.clips.isEmpty)
    }

    func test_projectWithClipRoundtrips() throws {
        var p = Project(name: "M")
        p.clips.append(Clip(
            name: "play 1", notes: "first one", tags: ["attacking-chance"],
            sourceIndex: 0, startSourceSeconds: 12.0, recordingDuration: 4.5,
            recordingFilename: "clip-A.mov",
            events: [.init(recordTime: 0, kind: .play)],
            sortIndex: 0
        ))
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(decoded.clips.first?.tags, ["attacking-chance"])
    }
}
```

**Step 2:** Run, expect failure.

**Step 3:** Implement `Project.swift`:

```swift
import Foundation

public enum Tag {
    public static func normalize(input: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for fragment in input.split(separator: ",") {
            let trimmed = fragment.trimmingCharacters(in: .whitespaces).lowercased()
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            out.append(trimmed)
        }
        return out
    }
}

public enum Resolution: String, Codable, Sendable, CaseIterable { case source, r1080, r720 }
public enum Quality: String, Codable, Sendable, CaseIterable { case low, medium, high }

public struct Preferences: Codable, Hashable, Sendable {
    public var scanVolume: Double = 1.0
    public var previewSourceVolume: Double = 1.0
    public var previewCommentaryVolume: Double = 1.0
    public var lastExportResolution: Resolution = .r1080
    public var lastExportQuality: Quality = .medium
    public init() {}
}

public struct SourceRef: Codable, Hashable, Sendable {
    public var bookmark: Data
    public var displayName: String
    public var durationSeconds: Double
    public init(bookmark: Data, displayName: String, durationSeconds: Double) {
        self.bookmark = bookmark; self.displayName = displayName; self.durationSeconds = durationSeconds
    }
}

public struct Clip: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var notes: String
    public var tags: [String]

    public var sourceIndex: Int
    public var startSourceSeconds: Double
    public var recordingDuration: Double

    public var recordingFilename: String

    public var events: [CommentaryEvent]
    public var sortIndex: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        notes: String = "",
        tags: [String] = [],
        sourceIndex: Int,
        startSourceSeconds: Double,
        recordingDuration: Double,
        recordingFilename: String,
        events: [CommentaryEvent] = [],
        sortIndex: Int,
        createdAt: Date = .init()
    ) {
        self.id = id; self.name = name; self.notes = notes; self.tags = tags
        self.sourceIndex = sourceIndex; self.startSourceSeconds = startSourceSeconds
        self.recordingDuration = recordingDuration; self.recordingFilename = recordingFilename
        self.events = events; self.sortIndex = sortIndex; self.createdAt = createdAt
    }
}

public struct Project: Codable, Hashable, Sendable {
    public var formatVersion: Int = 1
    public var name: String
    public var sourceVideos: [SourceRef] = []
    public var clips: [Clip] = []
    public var preferences: Preferences = .init()
    public init(name: String) { self.name = name }
}
```

**Step 4:** Run, expect pass. Commit:
```bash
git add VideoCoachCore
git commit -m "feat(core): Project, Clip, SourceRef, Preferences, Tag.normalize"
```

---

## Phase 3 — Source-time reconstruction (TDD)

### Task 3.1: `sourceTimeAt(recordTime:)` walking the event log

**Files:**
- Create: `VideoCoachCore/Sources/VideoCoachCore/PlaybackTimeline.swift`
- Create: `VideoCoachCore/Tests/VideoCoachCoreTests/PlaybackTimelineTests.swift`

**Step 1:** Write tests covering each event type:

```swift
import XCTest
@testable import VideoCoachCore

final class PlaybackTimelineTests: XCTestCase {
    func test_noEvents_advancesAtRate1() {
        let clip = makeClip(start: 100, events: [])
        XCTAssertEqual(clip.sourceTime(atRecordTime: 0), 100, accuracy: 1e-9)
        XCTAssertEqual(clip.sourceTime(atRecordTime: 5), 105, accuracy: 1e-9)
    }

    func test_pauseAndResume_freezesSource() {
        let clip = makeClip(start: 100, events: [
            .init(recordTime: 2.0, kind: .pause),
            .init(recordTime: 4.0, kind: .play),
        ])
        XCTAssertEqual(clip.sourceTime(atRecordTime: 1.0), 101, accuracy: 1e-9)
        XCTAssertEqual(clip.sourceTime(atRecordTime: 3.0), 102, accuracy: 1e-9) // frozen
        XCTAssertEqual(clip.sourceTime(atRecordTime: 5.0), 103, accuracy: 1e-9) // resumed
    }

    func test_skipForwardJumpsSourceWithoutAdvancingRecord() {
        let clip = makeClip(start: 100, events: [
            .init(recordTime: 2.0, kind: .skip(delta: 3)),
        ])
        XCTAssertEqual(clip.sourceTime(atRecordTime: 1.0), 101, accuracy: 1e-9)
        XCTAssertEqual(clip.sourceTime(atRecordTime: 2.0), 105, accuracy: 1e-9) // jumped
        XCTAssertEqual(clip.sourceTime(atRecordTime: 3.0), 106, accuracy: 1e-9)
    }

    func test_strokeAndClearAllAreNoOps_forSourceTime() {
        let stroke = Stroke(color: .red, lineWidth: 0.005, points: [], autoClearAfterSeconds: nil)
        let clip = makeClip(start: 100, events: [
            .init(recordTime: 1.0, kind: .stroke(stroke)),
            .init(recordTime: 2.0, kind: .clearAll),
        ])
        XCTAssertEqual(clip.sourceTime(atRecordTime: 3.0), 103, accuracy: 1e-9)
    }

    private func makeClip(start: Double, events: [CommentaryEvent]) -> Clip {
        Clip(name: "t", sourceIndex: 0, startSourceSeconds: start,
             recordingDuration: 10, recordingFilename: "t.mov",
             events: events, sortIndex: 0)
    }
}
```

**Step 2:** Run, expect failure (`Value of type 'Clip' has no member 'sourceTime'`).

**Step 3:** Implement `PlaybackTimeline.swift`:

```swift
import Foundation

public extension Clip {
    /// Source-video time the user was looking at, at the given record-time.
    /// Walks the event log applying play/pause/skip; stroke and clearAll do not affect source time.
    func sourceTime(atRecordTime t: Double) -> Double {
        var sourceTime = startSourceSeconds
        var recordCursor = 0.0
        var rate = 1.0

        for ev in events where ev.recordTime <= t {
            sourceTime += (ev.recordTime - recordCursor) * rate
            recordCursor = ev.recordTime
            switch ev.kind {
            case .play:           rate = 1.0
            case .pause:          rate = 0.0
            case .skip(let d):    sourceTime += d
            case .stroke, .clearAll: break
            }
        }
        sourceTime += (t - recordCursor) * rate
        return sourceTime
    }
}
```

**Step 4:** Run, expect pass.

**Step 5:** Commit:
```bash
git add VideoCoachCore
git commit -m "feat(core): Clip.sourceTime(atRecordTime:) reconstruction"
```

---

### Task 3.2: Build segment list for export compositing

**Files:**
- Modify: `VideoCoachCore/Sources/VideoCoachCore/PlaybackTimeline.swift`
- Modify: `VideoCoachCore/Tests/VideoCoachCoreTests/PlaybackTimelineTests.swift`

**Step 1:** Add tests for `playbackSegments(sourceDuration:)`:

```swift
func test_segments_simpleClip_oneSegmentEntireDuration() {
    let clip = makeClip(start: 10, events: [])
    let segs = clip.playbackSegments(sourceDuration: 1000)
    XCTAssertEqual(segs.count, 1)
    XCTAssertEqual(segs[0].kind, .play)
    XCTAssertEqual(segs[0].sourceStart, 10)
    XCTAssertEqual(segs[0].outDuration, 10) // recordingDuration
}

func test_segments_pauseProducesFreezeAndPlaySegments() {
    let clip = makeClip(start: 10, events: [
        .init(recordTime: 2, kind: .pause),
        .init(recordTime: 4, kind: .play),
    ])
    let segs = clip.playbackSegments(sourceDuration: 1000)
    XCTAssertEqual(segs.map(\.kind), [.play, .freeze, .play])
    XCTAssertEqual(segs[0].outDuration, 2)
    XCTAssertEqual(segs[1].outDuration, 2)
    XCTAssertEqual(segs[2].outDuration, 6)
}

func test_segments_clampSourceToBounds_onSkip() {
    let clip = makeClip(start: 998, events: [
        .init(recordTime: 1, kind: .skip(delta: 100)),
    ])
    let segs = clip.playbackSegments(sourceDuration: 1000)
    XCTAssertEqual(segs[1].sourceStart, 1000) // clamped at end
}
```

**Step 2:** Run, expect failure.

**Step 3:** Add `PlaybackSegment` and `playbackSegments`:

```swift
public struct PlaybackSegment: Equatable, Sendable {
    public enum Kind: Sendable { case play, freeze }
    public var kind: Kind
    public var sourceStart: Double      // source-video offset at segment start
    public var outDuration: Double      // duration in the recording timeline (seconds)
}

public extension Clip {
    func playbackSegments(sourceDuration: Double) -> [PlaybackSegment] {
        var segments: [PlaybackSegment] = []
        var sourceCursor = startSourceSeconds
        var recordCursor = 0.0
        var rate = 1.0

        func emit(to recordEnd: Double) {
            let dur = recordEnd - recordCursor
            if dur <= 0 { return }
            let kind: PlaybackSegment.Kind = (rate == 0.0) ? .freeze : .play
            segments.append(.init(kind: kind, sourceStart: sourceCursor, outDuration: dur))
            if rate == 1.0 { sourceCursor += dur }
            recordCursor = recordEnd
        }

        for ev in events {
            emit(to: ev.recordTime)
            switch ev.kind {
            case .play:           rate = 1.0
            case .pause:          rate = 0.0
            case .skip(let d):    sourceCursor = max(0, min(sourceDuration, sourceCursor + d))
            case .stroke, .clearAll: break
            }
        }
        emit(to: recordingDuration)
        return segments
    }
}
```

**Step 4:** Run, expect pass. Commit:
```bash
git add VideoCoachCore
git commit -m "feat(core): playbackSegments builder for export compositing"
```

---

### Task 3.3: `visibleStrokes(in:atRecordTime:)` shared replay helper (TDD)

The export compositor and Mode C stroke-replay layer must agree on which strokes are visible at any given record-time and how many of each stroke's points have been "drawn" by then. Single source of truth = pure function in core.

**Files:**
- Create: `VideoCoachCore/Sources/VideoCoachCore/StrokeReplay.swift`
- Create: `VideoCoachCore/Tests/VideoCoachCoreTests/StrokeReplayTests.swift`

**Step 1:** Write tests covering:
- A stroke is invisible before its `firstPointRecordTime`.
- A stroke is partially visible (correct `drawnPointCount`) mid-draw.
- A stroke with `autoClearAfterSeconds = 5` is invisible after `firstPointRecordTime + 5`.
- A `.clearAll` event clears strokes drawn before it but not after.
- Multiple strokes interleaved with `.clearAll` and auto-clear behave correctly.

**Step 2:** Implement:

```swift
public struct VisibleStroke: Equatable {
    public let stroke: Stroke
    public let firstPointRecordTime: Double
    public let drawnPointCount: Int
}

public func visibleStrokes(in clip: Clip, atRecordTime t: Double) -> [VisibleStroke] {
    var out: [VisibleStroke] = []
    var lastClearAllTime: Double = -.infinity
    for ev in clip.events {
        switch ev.kind {
        case .clearAll:
            lastClearAllTime = ev.recordTime
        case .stroke(let s):
            let firstT = ev.recordTime - (s.points.last?.t ?? 0)
            // Cleared by .clearAll between first-point and now?
            if lastClearAllTime > firstT && lastClearAllTime <= t { continue }
            // Auto-clear elapsed?
            if let auto = s.autoClearAfterSeconds, t >= firstT + auto { continue }
            // Not started yet?
            if t < firstT { continue }
            // Partial point count: largest k such that points[k-1].t <= (t - firstT).
            let elapsed = t - firstT
            let k = s.points.firstIndex(where: { $0.t > elapsed }) ?? s.points.count
            out.append(.init(stroke: s, firstPointRecordTime: firstT, drawnPointCount: k))
        case .play, .pause, .skip:
            break
        }
    }
    return out
}
```

**Step 3:** Run, expect pass. Commit.

---

## Phase 4 — Project file IO (TDD)

### Task 4.1: `ProjectStore.read` / `ProjectStore.write` with atomic write

**Files:**
- Create: `VideoCoachCore/Sources/VideoCoachCore/ProjectStore.swift`
- Create: `VideoCoachCore/Tests/VideoCoachCoreTests/ProjectStoreTests.swift`

**Step 1:** Write tests using a temp directory:

```swift
import XCTest
@testable import VideoCoachCore

final class ProjectStoreTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_writeThenReadRoundtripsProject() throws {
        var p = Project(name: "RoundTrip")
        p.preferences.scanVolume = 0.5
        try ProjectStore.write(p, to: tmp)
        let loaded = try ProjectStore.read(from: tmp)
        XCTAssertEqual(loaded.name, "RoundTrip")
        XCTAssertEqual(loaded.preferences.scanVolume, 0.5)
    }

    func test_writeCreatesRecordingsSubfolder() throws {
        try ProjectStore.write(Project(name: "x"), to: tmp)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmp.appendingPathComponent("recordings").path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func test_atomicWrite_doesNotCorruptOnSecondWrite() throws {
        let p1 = Project(name: "v1")
        var p2 = Project(name: "v2"); p2.formatVersion = 1
        try ProjectStore.write(p1, to: tmp)
        try ProjectStore.write(p2, to: tmp)
        XCTAssertEqual(try ProjectStore.read(from: tmp).name, "v2")
    }
}
```

**Step 2:** Run, expect failure.

**Step 3:** Implement:

```swift
import Foundation

public enum ProjectStoreError: Error {
    case missingProjectJSON
    case unsupportedFormatVersion(Int)
}

public enum ProjectStore {
    public static let projectFileName = "project.json"
    public static let recordingsDirName = "recordings"

    public static func read(from folder: URL) throws -> Project {
        let url = folder.appendingPathComponent(projectFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectStoreError.missingProjectJSON
        }
        let data = try Data(contentsOf: url)
        let project = try JSONDecoder().decode(Project.self, from: data)
        if project.formatVersion != 1 {
            throw ProjectStoreError.unsupportedFormatVersion(project.formatVersion)
        }
        return project
    }

    public static func write(_ project: Project, to folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: folder.appendingPathComponent(recordingsDirName),
            withIntermediateDirectories: true)

        let target = folder.appendingPathComponent(projectFileName)
        let tmp = folder.appendingPathComponent("project.json.tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.moveItem(at: tmp, to: target)
    }

    public static func recordingsDir(in folder: URL) -> URL {
        folder.appendingPathComponent(recordingsDirName, isDirectory: true)
    }
}
```

**Step 4:** Run, expect pass. Commit:
```bash
git add VideoCoachCore
git commit -m "feat(core): ProjectStore with atomic write and recordings dir"
```

---

### Task 4.2: Tag aggregation for the export sheet

**Files:**
- Create: `VideoCoachCore/Sources/VideoCoachCore/TagAggregation.swift`
- Create: `VideoCoachCore/Tests/VideoCoachCoreTests/TagAggregationTests.swift`

**Step 1:** Write tests:

```swift
import XCTest
@testable import VideoCoachCore

final class TagAggregationTests: XCTestCase {
    func test_aggregatesByTag_withCountAndDuration() {
        let project = makeProject(clips: [
            ("c1", ["attacking-chance", "wing"], 4.0),
            ("c2", ["attacking-chance"], 6.0),
            ("c3", ["transitions"], 3.0),
        ])
        let agg = TagAggregation.aggregate(project: project)
        XCTAssertEqual(Set(agg.map(\.tag)), ["attacking-chance", "transitions", "wing"])
        let attacking = agg.first(where: { $0.tag == "attacking-chance" })!
        XCTAssertEqual(attacking.clipCount, 2)
        XCTAssertEqual(attacking.totalDurationSeconds, 10.0)
    }

    func test_isAlphabeticallySorted() {
        let p = makeProject(clips: [
            ("c1", ["zebra"], 1), ("c2", ["alpha"], 1), ("c3", ["mango"], 1),
        ])
        XCTAssertEqual(TagAggregation.aggregate(project: p).map(\.tag), ["alpha", "mango", "zebra"])
    }

    private func makeProject(clips: [(String, [String], Double)]) -> Project {
        var p = Project(name: "t")
        for (i, c) in clips.enumerated() {
            p.clips.append(Clip(name: c.0, tags: c.1,
                                sourceIndex: 0, startSourceSeconds: 0,
                                recordingDuration: c.2, recordingFilename: "x.mov",
                                sortIndex: i))
        }
        return p
    }
}
```

**Step 2:** Run, expect failure.

**Step 3:** Implement:

```swift
import Foundation

public struct TagSummary: Hashable, Sendable {
    public var tag: String
    public var clipCount: Int
    public var totalDurationSeconds: Double
}

public enum TagAggregation {
    public static func aggregate(project: Project) -> [TagSummary] {
        var byTag: [String: (count: Int, dur: Double)] = [:]
        for clip in project.clips {
            for tag in clip.tags {
                let cur = byTag[tag] ?? (0, 0)
                byTag[tag] = (cur.count + 1, cur.dur + clip.recordingDuration)
            }
        }
        return byTag
            .map { TagSummary(tag: $0.key, clipCount: $0.value.count, totalDurationSeconds: $0.value.dur) }
            .sorted { $0.tag < $1.tag }
    }
}
```

**Step 4:** Run, expect pass. Commit:
```bash
git add VideoCoachCore
git commit -m "feat(core): TagAggregation for export sheet"
```

---

### Task 4.3: Bitrate table for export quality

**Files:**
- Create: `VideoCoachCore/Sources/VideoCoachCore/ExportSettings.swift`
- Create: `VideoCoachCore/Tests/VideoCoachCoreTests/ExportSettingsTests.swift`

**Step 1:** Write tests:

```swift
import XCTest
@testable import VideoCoachCore

final class ExportSettingsTests: XCTestCase {
    func test_bitrateForResolutionAndQuality() {
        XCTAssertEqual(ExportSettings.bitrate(resolution: .r1080, quality: .low), 6_000_000)
        XCTAssertEqual(ExportSettings.bitrate(resolution: .r1080, quality: .medium), 12_000_000)
        XCTAssertEqual(ExportSettings.bitrate(resolution: .r1080, quality: .high), 24_000_000)
        XCTAssertEqual(ExportSettings.bitrate(resolution: .r720, quality: .medium), 6_000_000)
    }

    func test_pixelSize_sourcePassesThrough() {
        XCTAssertEqual(ExportSettings.pixelSize(resolution: .r1080), .init(width: 1920, height: 1080))
        XCTAssertEqual(ExportSettings.pixelSize(resolution: .r720), .init(width: 1280, height: 720))
    }
}
```

**Step 2:** Run, expect failure.

**Step 3:** Implement:

```swift
import Foundation

public struct PixelSize: Equatable, Sendable {
    public var width: Int, height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

public enum ExportSettings {
    public static func bitrate(resolution: Resolution, quality: Quality) -> Int {
        let base1080: [Quality: Int] = [.low: 6_000_000, .medium: 12_000_000, .high: 24_000_000]
        let v = base1080[quality]!
        switch resolution {
        case .source, .r1080: return v
        case .r720:           return v / 2
        }
    }

    public static func pixelSize(resolution: Resolution) -> PixelSize {
        switch resolution {
        case .source: return .init(width: 1920, height: 1080) // overridden by source asset at export
        case .r1080:  return .init(width: 1920, height: 1080)
        case .r720:   return .init(width: 1280, height: 720)
        }
    }
}
```

**Step 4:** Run, expect pass. Commit:
```bash
git add VideoCoachCore
git commit -m "feat(core): ExportSettings bitrate + pixel size table"
```

---

## Phase 5 — App shell + virtual concat playback (manual verify)

This phase wires `AVPlayer` and the virtual-concat composition into the app. Tests are integration-style; primary verification is manual.

### Task 5.1: A minimal `Workspace` observable model

**Files:**
- Create: `App/Models/Workspace.swift`

**Step 1:** Write the workspace observable model. The asset loaders are properly async (the legacy synchronous `asset.duration` accessors are deprecated on macOS 13+ and removed on the latest macOS).

```swift
import Foundation
import VideoCoachCore
import AVFoundation
import Observation

enum WorkspaceError: Error {
    case noVideoTrack(URL)
    case bookmarkResolutionFailed(displayName: String)
}

@Observable
@MainActor
final class Workspace {
    var folder: URL?
    var project: Project = Project(name: "Untitled")
    var virtualPlayer: AVPlayer?
    var virtualComposition: AVMutableComposition?

    func openProject(folder: URL) async throws {
        self.folder = folder
        let p = (try? ProjectStore.read(from: folder)) ?? Project(name: folder.lastPathComponent)
        self.project = p
        try ProjectStore.write(p, to: folder)
        try await rebuildVirtualPlayer()
    }

    func saveProject() throws {
        guard let folder else { return }
        try ProjectStore.write(project, to: folder)
    }

    func rebuildVirtualPlayer() async throws {
        guard !project.sourceVideos.isEmpty else { virtualPlayer = nil; return }
        let comp = AVMutableComposition()
        guard let v = comp.addMutableTrack(withMediaType: .video,
                                           preferredTrackID: kCMPersistentTrackID_Invalid),
              let a = comp.addMutableTrack(withMediaType: .audio,
                                           preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return }

        var cursor = CMTime.zero
        for index in project.sourceVideos.indices {
            let url = try resolveAndRefreshBookmark(&project.sourceVideos[index])
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.load(.tracks)
            guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
                throw WorkspaceError.noVideoTrack(url)
            }
            let audioTrack = tracks.first(where: { $0.mediaType == .audio })
            let range = CMTimeRange(start: .zero, duration: duration)
            try v.insertTimeRange(range, of: videoTrack, at: cursor)
            if let audioTrack { try? a.insertTimeRange(range, of: audioTrack, at: cursor) }
            cursor = cursor + duration
        }
        self.virtualComposition = comp
        self.virtualPlayer = AVPlayer(playerItem: AVPlayerItem(asset: comp))
    }

    private func resolveBookmark(_ data: Data, displayName: String) throws -> (URL, isStale: Bool) {
        var stale = false
        // Plain (non-security-scoped) bookmarks: we run unsandboxed under hardened runtime.
        do {
            let url = try URL(resolvingBookmarkData: data,
                              options: [],
                              relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            return (url, isStale: stale)
        } catch {
            throw WorkspaceError.bookmarkResolutionFailed(displayName: displayName)
        }
    }

    /// Resolves and, if the bookmark went stale (e.g. the file was moved), regenerates and persists it.
    private func resolveAndRefreshBookmark(_ ref: inout SourceRef) throws -> URL {
        let (url, isStale) = try resolveBookmark(ref.bookmark, displayName: ref.displayName)
        if isStale {
            ref.bookmark = (try? url.bookmarkData(options: [])) ?? ref.bookmark
            try? saveProject()
        }
        return url
    }
}
```

**Step 2:** SwiftUI call sites bridge to async via `Task { }`:

```swift
Button("Open Project Folder…") {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    if panel.runModal() == .OK, let url = panel.url {
        Task { try? await workspace.openProject(folder: url) }
    }
}
```

**Step 3:** Build the app target (`⌘B` in Xcode). Expected: succeeds with no warnings. Commit:
```bash
git add App/Models/Workspace.swift
git commit -m "feat(app): async Workspace with virtual concat builder"
```

---

### Task 5.2: AVPlayerView wrapped for SwiftUI

**Files:**
- Create: `App/Views/PlayerSurface.swift`

**Step 1:** Implement the wrapper:

```swift
import SwiftUI
import AVKit

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}
```

**Step 2:** Wire into `ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    @State private var workspace = Workspace()

    var body: some View {
        VStack {
            PlayerSurface(player: workspace.virtualPlayer)
                .frame(minWidth: 640, minHeight: 360)
            Button("Open Project Folder…") {
                openProjectFolder()
            }
        }
        .padding()
    }

    private func openProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            Task { try? await workspace.openProject(folder: url) }
        }
    }
}
```

**Step 3:** Run the app. Click `Open Project Folder…`, pick a new empty folder. Expected: app shows blank player (no source videos yet). Commit:
```bash
git add App/Views/PlayerSurface.swift App/ContentView.swift
git commit -m "feat(app): PlayerSurface SwiftUI wrapper + open-project command"
```

---

### Task 5.3: Add Source Video command

**Files:**
- Modify: `App/Models/Workspace.swift`
- Modify: `App/ContentView.swift`

**Step 1:** Add to `Workspace` (note `async throws` and plain bookmark options):

```swift
func addSourceVideo(url: URL) async throws {
    let bookmark = try url.bookmarkData(options: [])  // plain — we're unsandboxed
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    project.sourceVideos.append(.init(
        bookmark: bookmark,
        displayName: url.lastPathComponent,
        durationSeconds: duration.seconds))
    try saveProject()
    try await rebuildVirtualPlayer()
}
```

**Step 2:** Add a button in `ContentView` next to Open Project:

```swift
Button("Add Source Video…") {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
        Task { try? await workspace.addSourceVideo(url: url) }
    }
}.disabled(workspace.folder == nil)
```

**Step 3:** Run. Open a project folder. Add a source video (any .mp4/.mov). Press play in the AVPlayerView controls. Expected: video plays. Commit:
```bash
git add App/Models/Workspace.swift App/ContentView.swift
git commit -m "feat(app): add source video command + virtual concat refresh"
```

---

### Task 5.4: Keyboard shortcuts for ±3s and play/pause

**Files:**
- Create: `App/Views/KeyCommandView.swift`
- Modify: `App/ContentView.swift`

**Step 1:** Add a custom NSView subclass that catches key equivalents and forwards to the player:

```swift
import SwiftUI
import AVFoundation

struct KeyCommandView: NSViewRepresentable {
    let player: AVPlayer?
    let onSkip: (Double) -> Void
    let onTogglePlay: () -> Void

    func makeNSView(context: Context) -> KeyCatchingView {
        let v = KeyCatchingView()
        v.onSkip = onSkip
        v.onTogglePlay = onTogglePlay
        return v
    }
    func updateNSView(_ v: KeyCatchingView, context: Context) {
        v.onSkip = onSkip; v.onTogglePlay = onTogglePlay
    }
}

final class KeyCatchingView: NSView {
    var onSkip: (Double) -> Void = { _ in }
    var onTogglePlay: () -> Void = {}

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
    }

    /// Position-based key codes (work across QWERTY, Dvorak, Colemak, etc).
    /// `kVK_ANSI_A` / `D` bind to the *physical* keys where A/D are on a standard ANSI layout —
    /// which is where transport controls conventionally live in video editors — not to whatever
    /// character those positions produce on the user's layout.
    private enum KeyCode {
        static let a: UInt16 = 0x00          // kVK_ANSI_A
        static let d: UInt16 = 0x02          // kVK_ANSI_D
        static let leftArrow: UInt16 = 0x7B  // kVK_LeftArrow
        static let rightArrow: UInt16 = 0x7C // kVK_RightArrow
        static let space: UInt16 = 0x31      // kVK_Space
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case KeyCode.leftArrow, KeyCode.a:  onSkip(-3)
        case KeyCode.rightArrow, KeyCode.d: onSkip(+3)
        case KeyCode.space:                 onTogglePlay()
        default: super.keyDown(with: event)
        }
    }
}
```

**Step 2:** Wire it into `ContentView` overlaying the player area:

```swift
ZStack {
    PlayerSurface(player: workspace.virtualPlayer)
    KeyCommandView(
        player: workspace.virtualPlayer,
        onSkip: { delta in
            guard let p = workspace.virtualPlayer else { return }
            let t = p.currentTime() + CMTime(seconds: delta, preferredTimescale: 600)
            p.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        },
        onTogglePlay: {
            guard let p = workspace.virtualPlayer else { return }
            p.rate == 0 ? p.play() : p.pause()
        }
    )
}
```

**Step 3:** Run. Verify: `space` toggles play, `←/a` jump back 3s, `→/d` jump forward 3s. Commit:
```bash
git add App/Views/KeyCommandView.swift App/ContentView.swift
git commit -m "feat(app): keyboard shortcuts space/arrows/AD for transport"
```

---

## Phase 6 — Three-pane layout, clip sidebar, mode handling

### Task 6.1: Three-pane `NavigationSplitView` layout

**Files:**
- Modify: `App/ContentView.swift`
- Create: `App/Views/ClipSidebar.swift`
- Create: `App/Views/ClipInspector.swift`
- Create: `App/Models/AppMode.swift`

**Step 1:** Implement `AppMode` (the `recordingStarting` state from Task 7.4 lives here too):

```swift
import Foundation
import VideoCoachCore

enum AppMode: Equatable {
    case scanning
    case recordingStarting
    case recording
    case previewClip(Clip.ID)
}
```

**Step 2:** Replace `ContentView` with the three-pane layout. The `selectedClipID` binding drives `appMode`: nil → `.scanning`, set → `.previewClip(id)`. Recording state is owned separately and overrides the mode while active.

```swift
import SwiftUI
import VideoCoachCore

struct ContentView: View {
    @State private var workspace = Workspace()
    @State private var selectedClipID: Clip.ID?
    @State private var appMode: AppMode = .scanning

    var body: some View {
        NavigationSplitView {
            ClipSidebar(workspace: $workspace, selectedClipID: $selectedClipID)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            VStack(spacing: 0) {
                ZStack {
                    PlayerSurface(player: currentPlayer)
                    KeyCommandView(
                        player: currentPlayer,
                        onSkip: handleSkip,
                        onTogglePlay: handleTogglePlay
                    )
                }
                TransportBar(workspace: $workspace, appMode: $appMode)
                    .frame(height: 56)
            }
        } detail: {
            ClipInspector(workspace: $workspace, selectedClipID: $selectedClipID)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        }
        .toolbar { /* New Project, Open Project, Add Source, Export… */ }
        .onChange(of: selectedClipID) { _, newID in
            appMode = newID.map { .previewClip($0) } ?? .scanning
        }
    }

    private var currentPlayer: AVPlayer? {
        switch appMode {
        case .previewClip(let id): return workspace.previewPlayer(for: id)
        default:                   return workspace.virtualPlayer
        }
    }
    // ... handleSkip / handleTogglePlay route through workspace + RecordingController.
}
```

**Step 3:** Implement `ClipSidebar` — project-name editor at the top, then a `List` of clips supporting drag-to-reorder (`onMove`) and `Cmd-Delete` to remove. List rows show name + duration. Selection binding goes to `selectedClipID`.

```swift
struct ClipSidebar: View {
    @Binding var workspace: Workspace
    @Binding var selectedClipID: Clip.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Project name", text: $workspace.project.name)
                .textFieldStyle(.plain)
                .font(.headline)
                .padding(8)
                .onSubmit { try? workspace.saveProject() }

            List(selection: $selectedClipID) {
                ForEach(workspace.project.clips.sorted(by: { $0.sortIndex < $1.sortIndex })) { clip in
                    HStack {
                        Text(clip.name).lineLimit(1)
                        Spacer()
                        Text(formatDuration(clip.recordingDuration)).font(.caption).foregroundStyle(.secondary)
                    }.tag(clip.id)
                }
                .onMove { indices, dest in workspace.reorderClips(from: indices, to: dest) }
            }
        }
    }
}
```

**Step 4:** Implement `ClipInspector` placeholder — reads the selected clip and shows its `name`, `notes`, `tags`. Tag editing comes in Task 6.2; for now plain `TextField`s wired with `.onSubmit { try? workspace.saveProject() }`.

**Step 5:** Run. Verify project name editable, empty clip list, player center, empty inspector when no clip selected. Add a stub clip programmatically to verify selection updates the inspector. Commit.

---

### Task 6.2: Clip metadata inspector with tag autocomplete

**Files:**
- Modify: `App/Views/ClipInspector.swift`
- Create: `App/Views/TagField.swift`

**Step 1:** Build a `TagField` that:
- Shows `clip.tags.joined(separator: ", ")` as text input
- Parses on commit via `Tag.normalize(input:)`
- Shows a popover suggestion list while typing, sourced from `Set(workspace.project.clips.flatMap(\.tags))`

**Step 2:** Wire `name`, `notes` (multi-line), `tags` into the inspector. Each edit updates `workspace.project.clips[…]` and calls `workspace.saveProject()`.

**Step 3:** Run. Manually add clips by stubbing `addStubClip` for testing. Verify edits persist across app relaunch. Commit.

---

## Phase 7 — Recording (capture session, events, drawing)

### Task 7.1: `CaptureSessionController` for camera + mic

**Files:**
- Create: `App/Capture/CaptureSessionController.swift`

Key behaviors:
- **Proper configuration order** (the canonical AVCam pattern): `beginConfiguration` → `sessionPreset = .inputPriority` → `addInput`/`addOutput` → `device.lockForConfiguration` + `device.activeFormat = ...` → `unlockForConfiguration` → `commitConfiguration` → `startRunning`. Setting `activeFormat` *before* `addInput` would be silently undone (notably to 1920×1440 4:3 on Continuity Camera).
- Pick a deterministic `AVCaptureDevice.Format` — prefer 1280×720 @ 30fps 16:9; fall back to the closest 720p-or-lower 16:9 30fps the device exposes. Do **not** use `sessionPreset = .high`.
- Two outputs:
  - `AVCaptureMovieFileOutput` for the recorded `.mov`.
  - `AVCaptureVideoDataOutput` companion that exists only to deliver per-frame `CMSampleBuffer`s. We grab the first one delivered after each `startRecording` call, capture its host-time PTS as `t = 0`, and discard the rest.
- `startRecording(to:)` returns an async `t0Seconds: Double` anchored to the first sample buffer's PTS (NOT to the `didStartRecordingTo` callback). The `RecordingController` (Task 7.2) awaits this anchor before accepting any event.

**Step 1:** Implement the controller. Note the canonical `addInput → setPreferredFormat → commit` order — setting `activeFormat` before `addInput` would be silently overridden.

```swift
import AVFoundation
import Observation

enum CaptureError: Error {
    case noVideoDevice
    case noAudioDevice
    case noSuitableFormat
    case permissionDenied(media: AVMediaType)
    case alreadyRecording
    case firstSampleTimeout
    case unsynchronizedClock     // synchronizationClock differs from host clock — refusing to start
}

@Observable
final class CaptureSessionController: NSObject,
    AVCaptureFileOutputRecordingDelegate,
    AVCaptureVideoDataOutputSampleBufferDelegate
{
    private(set) var isReady = false
    private(set) var isRecording = false

    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let dataOutput = AVCaptureVideoDataOutput()
    private let dataQueue = DispatchQueue(label: "videoCoach.capture.data")

    /// Resumed with the host-time PTS (in seconds) of the first sample buffer that lands
    /// AFTER the file output has opened the recording. nil between recordings.
    /// All access to these three fields is on dataQueue.
    private var t0Continuation: CheckedContinuation<Double, Error>?
    private var awaitingFirstSample = false
    private var firstSampleTimeoutTask: Task<Void, Never>?

    private var stopContinuation: CheckedContinuation<Double, Error>?
    private var videoDevice: AVCaptureDevice?

    func configure() async throws {
        try await ensurePermission(.video)
        try await ensurePermission(.audio)

        guard let video = AVCaptureDevice.default(for: .video) else { throw CaptureError.noVideoDevice }
        guard let audio = AVCaptureDevice.default(for: .audio) else { throw CaptureError.noAudioDevice }
        self.videoDevice = video

        let videoInput = try AVCaptureDeviceInput(device: video)
        let audioInput = try AVCaptureDeviceInput(device: audio)

        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        if session.canAddInput(videoInput) { session.addInput(videoInput) }
        if session.canAddInput(audioInput) { session.addInput(audioInput) }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        if session.canAddOutput(dataOutput) {
            dataOutput.setSampleBufferDelegate(self, queue: dataQueue)
            dataOutput.alwaysDiscardsLateVideoFrames = true
            session.addOutput(dataOutput)
        }
        try setPreferredFormat(on: video)        // AFTER addInput — the canonical order
        session.commitConfiguration()
        session.startRunning()
        isReady = true
    }

    private func ensurePermission(_ media: AVMediaType) async throws {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: media)
            if !granted { throw CaptureError.permissionDenied(media: media) }
        default:
            throw CaptureError.permissionDenied(media: media)
        }
    }

    private func setPreferredFormat(on device: AVCaptureDevice) throws {
        let candidates = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let aspect = Double(dims.width) / Double(max(dims.height, 1))
            return abs(aspect - 16.0/9.0) < 0.01
                && dims.width <= 1280
                && format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 })
        }
        let best = candidates.max(by: { a, b in
            CMVideoFormatDescriptionGetDimensions(a.formatDescription).width
            < CMVideoFormatDescriptionGetDimensions(b.formatDescription).width
        })
        guard let chosen = best else { throw CaptureError.noSuitableFormat }
        try device.lockForConfiguration()
        device.activeFormat = chosen
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        device.unlockForConfiguration()
    }

    /// Returns the host-time PTS (seconds) of the first frame that lands in the recorded file.
    /// This is our event-log t = 0.
    ///
    /// Implementation notes:
    /// - We arm the continuation on dataQueue BEFORE calling startRecording, but we only flip
    ///   `awaitingFirstSample` AFTER `didStartRecordingTo` confirms the file is open.
    ///   Otherwise we'd anchor to a buffer captured before the file actually started,
    ///   producing a t0 that's earlier than the first frame in the recording.
    /// - 2-second timeout protects the UI from hanging forever if the camera fails.
    /// - Refuses re-entry if a recording is already pending or running.
    func startRecording(to url: URL) async throws -> Double {
        try checkSessionClock()
        try dataQueue.sync {
            guard t0Continuation == nil, !isRecording else { throw CaptureError.alreadyRecording }
        }
        return try await withCheckedThrowingContinuation { cont in
            dataQueue.sync {
                self.t0Continuation = cont
                self.awaitingFirstSample = false   // armed in didStartRecordingTo
            }
            movieOutput.startRecording(to: url, recordingDelegate: self)
            isRecording = true
            firstSampleTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.dataQueue.async {
                    guard let self, let cont = self.t0Continuation else { return }
                    self.t0Continuation = nil
                    self.awaitingFirstSample = false
                    cont.resume(throwing: CaptureError.firstSampleTimeout)
                    self.movieOutput.stopRecording()
                }
            }
        }
    }

    /// AVCaptureSession's master clock is normally CMClockGetHostTimeClock(), matching CACurrentMediaTime().
    /// On certain Continuity Camera or external pro-capture paths it's a device-derived clock; we
    /// refuse to record in that case rather than silently producing misaligned timestamps.
    /// (A future v2 can convert PTS via CMSyncConvertTime instead of refusing.)
    private func checkSessionClock() throws {
        let clock: CMClock? = session.synchronizationClock
        if let c = clock, c !== CMClockGetHostTimeClock() {
            throw CaptureError.unsynchronizedClock
        }
    }

    func stopRecording() async throws -> Double {
        try await withCheckedThrowingContinuation { cont in
            self.stopContinuation = cont
            movieOutput.stopRecording()
        }
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Runs on dataQueue.
        guard awaitingFirstSample, let cont = t0Continuation else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        awaitingFirstSample = false
        t0Continuation = nil
        firstSampleTimeoutTask?.cancel()
        firstSampleTimeoutTask = nil
        cont.resume(returning: pts.seconds)   // host-time clock; same as CACurrentMediaTime()
    }

    // MARK: AVCaptureFileOutputRecordingDelegate

    func fileOutput(_ output: AVCaptureFileOutput,
                    didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        // The file is now open. Arm the data-output sample-buffer delegate to capture the
        // FIRST buffer that arrives AFTER this point (any buffers in flight before this
        // are pre-recording and must be ignored). We dispatch to dataQueue so the flag
        // flip is serialized against the delegate's reads.
        dataQueue.async { [weak self] in
            self?.awaitingFirstSample = true
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        isRecording = false
        if let error {
            stopContinuation?.resume(throwing: error)
            stopContinuation = nil
            return
        }
        let cont = stopContinuation
        stopContinuation = nil
        Task {
            // .duration is async-only on the latest macOS; load it off the delegate thread.
            let asset = AVURLAsset(url: outputFileURL)
            do {
                let dur = try await asset.load(.duration)
                cont?.resume(returning: dur.seconds)
            } catch {
                cont?.resume(throwing: error)
            }
        }
    }
}
```

**Step 2:** Call `configure()` from the app on first launch. Add a debug "Test Capture" button that records 3 seconds to a temp `.mov`, prints the `t0Seconds` returned from `startRecording`, and prints the resulting duration. Verify `t0Seconds` lags the call site by 80–300ms (camera warm-up + first-frame latency, now correctly accounted for).

**Step 3:** Commit.

---

### Task 7.2: `RecordingController` driving the event log

**Files:**
- Create: `App/Recording/RecordingController.swift`

**Step 1:** Implement an observable that:
- Owns an `events: [CommentaryEvent]` array.
- Receives `t0Seconds: Double` returned from `CaptureSessionController.startRecording(to:)`, which is the host-time PTS of the first sample buffer in the recording. Stored as `let` in the initializer — never mutated. A new recording = a new `RecordingController` instance.
- Has methods: `appendPlay()`, `appendPause()`, `appendSkip(delta:)`, `appendStroke(Stroke)`, `appendClearAll()` — each computes `recordTime = CACurrentMediaTime() - t0Seconds` and appends.
- The R / space / arrow keys ignore presses until the controller exists (i.e. until the first sample buffer has landed). The UI key handler observes `recording != nil`.
- On `finish()`, returns the events array for assembly into a `Clip`.

**Step 2:** Add minimal unit tests in the app target's test bundle: instantiate a controller with `t0Seconds = CACurrentMediaTime() - 1.0`, append a few events, verify timestamps are monotonically increasing and within the expected ~1.0+ second range. Commit.

---

### Task 7.3: Drawing overlay with 60Hz throttle

**Files:**
- Create: `App/Drawing/DrawingOverlayView.swift`
- Create: `App/Drawing/Denormalize.swift`

**Step 1:** Implement the shared coordinate helper used by overlay, Mode C preview, and export compositor. Strokes are stored with a top-left origin (we flip Y on capture). Both render call sites also use top-left: `CAShapeLayer` in a normal AppKit view requires a Y flip from the bottom-left view origin, and the export compositor's `CGContext` (wrapping a `CVPixelBuffer`) defaults to bottom-left and the compositor flips via `translateBy + scaleBy(1, -1)`. So both call sites pass `flipY: true`.

```swift
import CoreGraphics

enum Denormalize {
    /// Converts a normalized point (top-left origin) into a target size,
    /// optionally flipping Y for a bottom-left coordinate system.
    static func point(_ x: Double, _ y: Double, into size: CGSize, flipY: Bool) -> CGPoint {
        let px = CGFloat(x) * size.width
        let py = CGFloat(y) * size.height
        return flipY ? CGPoint(x: px, y: size.height - py) : CGPoint(x: px, y: py)
    }
}
```

**Step 2:** `NSView` subclass over the AVPlayerLayer. The overlay uses one `CAShapeLayer` per stroke — appending to its `path` directly, so Core Animation composites on the GPU and there's no whole-overlay repaint per drag event.

```swift
import AppKit
import VideoCoachCore

final class DrawingOverlayView: NSView {
    var onStrokeFinished: (Stroke) -> Void = { _ in }
    var autoClearAfterSeconds: Double? = 5.0

    private struct InProgress {
        var startedAt: TimeInterval
        var points: [StrokePoint]
        var lastTime: TimeInterval
        var lastPxPoint: NSPoint
        var layer: CAShapeLayer
        var path: CGMutablePath        // grown incrementally with addLine(to:); never re-walked
    }

    private var inProgress: InProgress?
    private var liveLayers: [CAShapeLayer] = []
    private let minDt: TimeInterval = 1.0 / 60.0
    private let minPx: CGFloat = 1.0

    override var isFlipped: Bool { false }    // bottom-left origin (default AppKit)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        // Defensive: discard any abandoned in-progress stroke (e.g. from a synthesized
        // mouseDown during a window resize). Otherwise its CAShapeLayer leaks.
        if let prior = inProgress {
            prior.layer.removeFromSuperlayer()
            inProgress = nil
        }
        let p = convert(event.locationInWindow, from: nil)
        let now = CACurrentMediaTime()
        let layer = CAShapeLayer()
        // Match the saved Stroke.color = RGBA.red exactly, so the live drawing matches export.
        layer.strokeColor = NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 1.0).cgColor
        layer.fillColor = nil
        // CAShapeLayer.lineWidth is in points; Core Animation handles the Retina backing-store
        // upscale automatically. Do NOT multiply by backingScaleFactor — that produces 2x overdraw.
        layer.lineWidth = 0.005 * bounds.height
        layer.lineCap = .round
        layer.lineJoin = .round
        self.layer?.addSublayer(layer)
        let path = CGMutablePath()
        let firstSP = pointFromView(p, sinceStart: 0)
        path.move(to: Denormalize.point(firstSP.x, firstSP.y, into: bounds.size, flipY: true))
        layer.path = path
        inProgress = InProgress(
            startedAt: now,
            points: [firstSP],
            lastTime: now,
            lastPxPoint: p,
            layer: layer,
            path: path
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard var ip = inProgress else { return }
        let p = convert(event.locationInWindow, from: nil)
        let now = CACurrentMediaTime()
        if now - ip.lastTime < minDt { return }
        if hypot(p.x - ip.lastPxPoint.x, p.y - ip.lastPxPoint.y) < minPx { return }
        let strokeT = now - ip.startedAt
        let newSP = pointFromView(p, sinceStart: strokeT)
        ip.points.append(newSP)
        ip.lastTime = now
        ip.lastPxPoint = p
        // O(1) path growth — no re-walk of all prior points.
        ip.path.addLine(to: Denormalize.point(newSP.x, newSP.y, into: bounds.size, flipY: true))
        ip.layer.path = ip.path
        inProgress = ip
    }

    override func mouseUp(with event: NSEvent) {
        guard let ip = inProgress else { return }
        let stroke = Stroke(
            color: .red,
            lineWidth: 0.005,
            points: ip.points,
            autoClearAfterSeconds: autoClearAfterSeconds
        )
        onStrokeFinished(stroke)
        liveLayers.append(ip.layer)
        inProgress = nil
        // Caller handles auto-clear timing for the layer (mirroring the export-side logic).
    }

    func clearAll() {
        for layer in liveLayers { layer.removeFromSuperlayer() }
        liveLayers.removeAll()
    }

    private func pointFromView(_ p: NSPoint, sinceStart strokeT: Double) -> StrokePoint {
        StrokePoint(
            x: p.x / bounds.width,
            y: 1.0 - p.y / bounds.height,    // flip Y so 0 = top
            t: strokeT
        )
    }

    // (Path is now grown incrementally in mouseDragged; no rebuild-on-every-event needed.)
}
```

**Step 3:** Run. Toggle a debug "drawing mode" and verify strokes draw smoothly. Run Instruments' Core Animation template; confirm `mouseDragged:` only updates the existing `CAShapeLayer.path` (single layer redraw, no overlay-wide invalidation). Commit.

---

### Task 7.4: Wire Mode B end-to-end

**Files:**
- Modify: `App/ContentView.swift`
- Modify: `App/Models/Workspace.swift`
- Modify: `App/Views/KeyCommandView.swift`
- Modify: `App/Models/AppMode.swift`

**Step 1:** Extend `AppMode` to include the in-flight state:

```swift
enum AppMode: Equatable {
    case scanning
    case recordingStarting    // R pressed; awaiting first sample buffer
    case recording
    case previewClip(Clip.ID)
}
```

**Step 2:** When `R` is pressed in Mode A:
- Set `appMode = .recordingStarting` immediately. Disable subsequent R/space/arrow inputs and show a subtle "preparing recording…" indicator (REC dot in yellow).
- Generate a UUID + filename: `clip-<uuid>.mov`.
- `Task { let t0 = try await capture.startRecording(to: recordingsDir/filename); ...continue on main actor }`
- When the `t0Seconds` is returned (i.e. first sample buffer landed), construct a fresh `RecordingController(t0Seconds: t0)`, append initial `.play` event at `recordTime = 0`, set `appMode = .recording`, set `virtualPlayer.rate = 1.0`, show drawing overlay, flip the REC dot to red.

**Step 3:** While `appMode == .recording`, the key handler routes:
- `space` → toggle player rate AND append `.play` or `.pause` to RecordingController.
- arrows/AD → seek + append `.skip(delta:)`.
- `R` / `esc` → stop recording.

While `appMode == .recordingStarting`, the key handler ignores all keys (no events captured before t=0).

**Step 4:** On stop:
- `stopRecording()` → returns duration.
- Build `Clip` from RecordingController's events + capture metadata. Set `recordingFilename` to `"clip-\(id).mov"`.
- `workspace.project.clips.append(clip)`.
- `saveProject()`.
- Return to Mode A.

**Step 4:** Run a full manual test:
- Open project, add source video, press play, scrub, press R, talk for 5s with one pause + one skip + one drawing, press R.
- Verify a new clip appears in the sidebar with non-zero duration.
- Quit + relaunch + reopen project. Verify clip persists with all events serialized in `project.json`.

**Step 5:** Commit.

---

## Phase 8 — Mode C clip preview compositor

### Task 8.1: Layered Mode C clip preview

The export compositor draws strokes + CoreText per frame, which won't sustain 30fps live playback. Mode C uses a layered preview: native `AVPlayerLayer` for source-with-freezes + PiP via built-in layer instructions; `CAShapeLayer` overlay for strokes; SwiftUI `Text` for the text bar. Audio mix on the player item.

This means the preview is intentionally NOT pixel-identical to the export. Stroke widths and text rendering may differ by a pixel or two. Trade-off accepted for real-time playback at any clip duration.

**Files:**
- Create: `App/Preview/PreviewCompositor.swift`
- Create: `App/Preview/ClipPreviewBuilder.swift`
- Create: `App/Preview/StrokeReplayLayer.swift`
- Modify: `App/ContentView.swift`

**Step 1:** Implement `PreviewCompositor` — minimal `AVVideoCompositing` that handles ONLY freeze segments.

**Backward-scrub correctness.** AVPlayer can call `startRequest` out of temporal order (during seeks, scrubbing, reverse playback). A naive `lastSourceFrame` updated only on forward `.play` requests would display a *future* frame during a freeze if the user scrubs backward. The fix: at composition build time, **pre-decode** one source frame per `.freeze` segment — the source-time at the END of the immediately preceding `.play` segment — and stash these `[FreezeSegmentKey: CVPixelBuffer]` on the instruction (reachable from the compositor via `request.videoCompositionInstruction as? PreviewInstruction`). At render time, freeze frames come from this map by key, never from a runtime cache.

For `.play` segments: return the source frame from `request.sourceFrame(byTrackID:)` directly. The compositor does NOT draw strokes, text, or PiP — those are handled in the view hierarchy or by AVFoundation's built-in layer instructions.

```swift
import AVFoundation

final class PreviewCompositor: NSObject, AVVideoCompositing {
    var sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    var requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    private var renderContext: AVVideoCompositionRenderContext?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderContext = newRenderContext
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let inst = request.videoCompositionInstruction as? PreviewInstruction else {
            fatalError("PreviewCompositor received a non-PreviewInstruction")
        }
        let recordTime = (request.compositionTime - inst.clipCompositionStart).seconds
        let segIndex = inst.segmentIndex(forRecordTime: recordTime)
        let segment = inst.segments[segIndex]

        let buf: CVPixelBuffer?
        if segment.kind == .freeze {
            // Pre-decoded frozen frame keyed by segment index. Survives backward seeks.
            buf = inst.frozenFrames[segIndex]
        } else if let live = request.sourceFrame(byTrackID: inst.sourceTrackID) {
            buf = live
        } else {
            buf = nil   // gap before first sample — render black
        }

        if let buf {
            request.finish(withComposedVideoFrame: buf)
        } else if let pb = renderContext?.newPixelBuffer() {
            // Black: pixelBufferPool buffers are zero-initialized when freshly created from BGRA pool.
            request.finish(withComposedVideoFrame: pb)
        } else {
            request.finishCancelledRequest()
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}

final class PreviewInstruction: AVMutableVideoCompositionInstruction {
    var clipIndex: Int = 0
    var sourceTrackID: CMPersistentTrackID = 1
    var clipCompositionStart: CMTime = .zero
    var segments: [PlaybackSegment] = []
    /// Pre-decoded frozen frame per segment index where segments[i].kind == .freeze.
    /// Built once at composition build time; never mutated at render time, so it's safe under
    /// backward scrubbing or out-of-order render requests.
    var frozenFrames: [Int: CVPixelBuffer] = [:]

    func segmentIndex(forRecordTime t: Double) -> Int {
        var elapsed = 0.0
        for (i, seg) in segments.enumerated() {
            let next = elapsed + seg.outDuration
            if t < next { return i }
            elapsed = next
        }
        return max(0, segments.count - 1)
    }
}
```

The `frozenFrames` map is populated at composition build time by `ClipPreviewBuilder` using `AVAssetImageGenerator.copyCGImage(at: sourceTimeAtEndOfPriorPlay)` → `CGImage` → `CVPixelBuffer`. One generation per freeze segment per clip, off the render thread, before playback starts. The same approach can be applied to the export's `CompilationCompositor` if any user reports incorrect freeze frames during forward export (the export pipeline calls in temporal order so the runtime cache happens to work, but pre-decode is safer).

**Step 2:** Implement `ClipPreviewBuilder` — produces an `AVPlayerItem` for a single clip:

```swift
func buildPreviewItem(for clip: Clip, project: Project) async throws -> AVPlayerItem {
    let comp = AVMutableComposition()
    let srcVideoTrackID: CMPersistentTrackID = 1
    let webcamTrackID: CMPersistentTrackID  = 1000
    // ... insert source video segments (.play only) into composition track id 1
    // ... insert webcam video continuously into composition track id 1000
    // ... insert source audio (.play only) and mic audio continuously, with 5ms boundary ramps
    let videoComp = AVMutableVideoComposition()
    videoComp.customVideoCompositorClass = PreviewCompositor.self
    videoComp.renderSize = CGSize(width: 1280, height: 720)
    videoComp.frameDuration = CMTime(value: 1, timescale: 30)
    // build [PreviewInstruction] with built-in layer instructions for the PiP transform
    // ... layerInstructions: source full-frame + webcam transformed to 22% bottom-right
    let item = AVPlayerItem(asset: comp)
    item.videoComposition = videoComp
    item.audioMix = buildAudioMix(...)
    return item
}
```

**Step 3:** Implement `StrokeReplayLayer` — a `CALayer` overlay that observes player time at 60Hz via `AVPlayer.addPeriodicTimeObserver` and maintains one `CAShapeLayer` per visible stroke:

- On each tick, compute `recordTime = playerTime - clipCompositionStart`.
- Call `visibleStrokes(in: clip, atRecordTime: recordTime)` (the shared helper from Task 3.3).
- Diff the result against the currently-displayed `[strokeID: CAShapeLayer]`: add layers for newly visible strokes, remove layers for now-hidden ones, update `path` for partially-drawn strokes whose `drawnPointCount` changed.
- **Wrap every layer mutation in `CATransaction.begin(); CATransaction.setDisableActions(true); ...; CATransaction.commit()`** so adding/removing a `CAShapeLayer` doesn't trigger the implicit `kCAOnOrderIn` fade animation (strokes should pop in/out instantly, not fade).
- Handles scrubbing correctly because diff-against-current works for both forward play and backward seek.

**Step 4:** ContentView wiring — when `appMode == .previewClip(id)`, swap `PlayerSurface` for a `ZStack` containing:
- `PlayerSurface(player: previewPlayer)` (built from `buildPreviewItem`)
- `StrokeReplayLayer(player: previewPlayer, clip: clip)` overlay
- `Text(clip.textBarLine).background(Color.black.opacity(0.6))` pinned to bottom 8%

Wire source/commentary volume sliders to debounced re-builds of `AVMutableAudioMix`. On change, build a fresh `AVMutableAudioMix` with the new volumes and assign `previewPlayer.currentItem?.audioMix = newMix`. Mutating an existing mix in place does not take effect on a playing item.

**Step 5:** Run. Click a recorded clip. Verify the layered preview plays at full rate, freeze segments hold, strokes replay at original tempo, text bar shows, both volume sliders update audio live. Commit.

---

## Phase 9 — Export pipeline

The design explicitly chooses a **custom `AVVideoCompositing` compositor** (handles freeze frames + PiP + strokes + text bar in one place) inside an **`AVAssetExportSession`** pipeline. The freeze-frame work is done by re-emitting the last decoded `CVPixelBuffer` for the duration of the freeze segment — not by `scaleTimeRange`.

### Task 9.0: AVAssetExportSession spike — does the risky combination actually work?

**Goal:** confirm `AVAssetExportSession` honors a `customVideoCompositorClass` AND a custom `audioMix` AND a non-default frame rate when paired with HEVC presets. Empty-composition tests don't exercise the risk; we need a stub compositor that proves the compositor is actually called, plus a non-1.0 audio mix that proves the mix is honored, plus bitrate measurement.

**Files:**
- Create: `App/Export/ExportSpike.swift` (deletable scratch file)

**Step 1:** Build a stub compositor that paints every frame solid red:

```swift
final class RedCompositor: NSObject, AVVideoCompositing {
    var sourcePixelBufferAttributes: [String : Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    var requiredPixelBufferAttributesForRenderContext: [String : Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    private var ctx: AVVideoCompositionRenderContext?
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) { ctx = newRenderContext }
    func cancelAllPendingVideoCompositionRequests() {}
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let pb = ctx?.newPixelBuffer() else { request.finishCancelledRequest(); return }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmap = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                               width: CVPixelBufferGetWidth(pb),
                               height: CVPixelBufferGetHeight(pb),
                               bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                               space: cs,
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
        bitmap?.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        bitmap?.fill(CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb)))
        request.finish(withComposedVideoFrame: pb)
    }
}
```

**Step 2:** Run an export with: a 10-second silent test `.mov` (`AVAssetWriter` from a green pixel buffer, plus 1kHz tone audio), `AVMutableVideoComposition.customVideoCompositorClass = RedCompositor.self`, `AVMutableAudioMix` with `setVolume(0.25, at: .zero)` on the audio track, `AVAssetExportPresetHEVC1920x1080`, output `.mov`.

**Step 3:** Verify with `ffprobe` and `afinfo`:
```bash
# Video: HEVC at expected bitrate
ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,bit_rate,width,height output.mov

# Spot-check frames are red, not green (proves compositor was called)
ffmpeg -i output.mov -vf "select=eq(n\,30)" -vframes 1 -y frame30.png
# Inspect frame30.png — should be solid red.

# Audio: confirm 0.25 attenuation took effect (proves audio mix honored)
ffmpeg -i output.mov -af "volumedetect" -f null - 2>&1 | grep mean_volume
# Compare to source — should be ~12 dB lower (≈ 0.25 linear).
```

**Step 4:** Decision matrix:
- All three checks pass → ExportSession path is safe. Proceed with 9.1–9.5 as written. Skip 9.6.
- Frames are green (compositor not called) → preset is taking a fast-path. Switch the entire export to `AVAssetReader`/`AVAssetWriter` (Task 9.6 promoted to mandatory).
- Audio not attenuated (mix not honored) → same fallback.
- HEVC bitrate too high or too low for 6/12/24 Mbps targets → switch to `AVAssetWriter` for video output settings control (9.6 mandatory) but consider keeping ExportSession for audio.

**Step 5:** Record the outcome in the design's **Spike outcomes** section (replace the empty checkbox). Delete the spike file:
```bash
git rm App/Export/ExportSpike.swift
git commit -m "chore: spike AVAssetExportSession + custom compositor + audio mix (outcome recorded in design)"
```

---

### Task 9.1: `CompilationPlan` — pure-logic plan builder (TDD)

**Files:**
- Create: `VideoCoachCore/Sources/VideoCoachCore/CompilationPlan.swift`
- Create: `VideoCoachCore/Tests/VideoCoachCoreTests/CompilationPlanTests.swift`

**Step 1:** Define an in-memory plan describing the output composition. Pure data, no AVFoundation.

```swift
public struct CompilationPlan: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var clipID: UUID
        public var indexInOutput: Int           // 0-based, for "1/N" overlay
        public var compositionStart: Double     // seconds in output
        public var segments: [PlaybackSegment]  // walked source segments
        public var recordingDuration: Double
    }
    public var totalDurationSeconds: Double
    public var entries: [Entry]
}

public extension Project {
    func compilationPlan(for tag: String, sourceDurations: [Int: Double]) -> CompilationPlan
    func allClipsCompilationPlan(sourceDurations: [Int: Double]) -> CompilationPlan
}
```

**Step 2:** Write tests covering: filtering by tag, sort order, accumulating `compositionStart`, all-clips ordering by `sortIndex`, empty-tag handling. Implement to make them pass.

**Step 3:** Commit.

---

### Task 9.2: Primary-track helper (defensive asset access)

**Files:**
- Create: `VideoCoachCore/Sources/VideoCoachCore/AssetTracks.swift`
- Create: `VideoCoachCore/Tests/VideoCoachCoreTests/AssetTracksTests.swift`

This helper lets the compositor handle multi-track or no-audio assets without force-unwrapping.

**Step 1:** Implement:

```swift
import AVFoundation

public enum AssetTrackError: Error {
    case noVideoTrack(URL)
}

public extension AVAsset {
    func primaryVideoTrack() async throws -> AVAssetTrack {
        let tracks = try await loadTracks(withMediaType: .video)
        if let first = tracks.first(where: { $0.isEnabled }) ?? tracks.first {
            return first
        }
        throw AssetTrackError.noVideoTrack((self as? AVURLAsset)?.url ?? URL(fileURLWithPath: "/"))
    }

    func optionalAudioTrack() async throws -> AVAssetTrack? {
        let tracks = try await loadTracks(withMediaType: .audio)
        return tracks.first(where: { $0.isEnabled }) ?? tracks.first
    }
}
```

**Step 2:** Write integration tests using a tiny fixture asset bundled in the test resources (a 1-second silent MOV plus a 1-second video-only MOV without audio). Verify the helpers find video and gracefully handle missing audio.

**Step 3:** Commit.

---

### Task 9.3: Custom `AVVideoCompositing` compositor + per-instruction context

**Files:**
- Create: `App/Export/CompilationInstruction.swift`
- Create: `App/Export/CompilationCompositor.swift`

The compositor is registered via `customVideoCompositorClass` and instantiated by AVFoundation — we cannot pass per-clip context through `init`. The standard pattern is to **subclass `AVMutableVideoCompositionInstruction`** and thread the per-clip data on the subclass; the compositor casts on the way in.

**Step 1:** Define `CompilationInstruction` (one per clip in the output composition). Note: every instance MUST have `timeRange` set to the clip's compositional range, AND `requiredSourceTrackIDs` set with `NSNumber`-boxed track IDs.

```swift
import AVFoundation
import VideoCoachCore

final class CompilationInstruction: AVMutableVideoCompositionInstruction {
    var clipIndex: Int = 0
    var indexInOutput: Int = 0
    var totalClips: Int = 0
    var sourceTrackID: CMPersistentTrackID = 1
    var webcamTrackID: CMPersistentTrackID = 1000
    var clipCompositionStart: CMTime = .zero
    var segments: [PlaybackSegment] = []   // walked playback segments (.play / .freeze)
    var strokes: [Stroke] = []              // strokes from the clip's events
    var textBarLine: String = ""            // "i/N, name, tags joined by space"

    /// Builder helper. Always use this rather than the bare initializer to ensure timeRange
    /// + requiredSourceTrackIDs are populated.
    static func make(
        clipIndex: Int,
        indexInOutput: Int,
        totalClips: Int,
        compositionStart: CMTime,
        clipDuration: CMTime,
        sourceTrackID: CMPersistentTrackID = 1,
        webcamTrackID: CMPersistentTrackID,
        segments: [PlaybackSegment],
        strokes: [Stroke],
        textBarLine: String
    ) -> CompilationInstruction {
        let i = CompilationInstruction()
        i.timeRange = CMTimeRange(start: compositionStart, duration: clipDuration)
        i.requiredSourceTrackIDs = [
            NSNumber(value: sourceTrackID),
            NSNumber(value: webcamTrackID)
        ]
        i.clipIndex = clipIndex
        i.indexInOutput = indexInOutput
        i.totalClips = totalClips
        i.sourceTrackID = sourceTrackID
        i.webcamTrackID = webcamTrackID
        i.clipCompositionStart = compositionStart
        i.segments = segments
        i.strokes = strokes
        i.textBarLine = textBarLine
        return i
    }
}
```

**Step 2:** Implement `CompilationCompositor: AVVideoCompositing`. Track-ID strategy: source video = `1`, source audio = `2`, webcam video = `1000 + clipIndex`, mic audio = `2000 + clipIndex`. Reset `lastSourceFrame` on every clip-index change.

```swift
final class CompilationCompositor: NSObject, AVVideoCompositing {
    var sourcePixelBufferAttributes: [String : Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    var requiredPixelBufferAttributesForRenderContext: [String : Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]

    private var renderContext: AVVideoCompositionRenderContext?
    private var lastSourceFrame: CVPixelBuffer?
    private var lastClipIndex: Int = -1

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderContext = newRenderContext
    }
    func cancelAllPendingVideoCompositionRequests() {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let inst = request.videoCompositionInstruction as? CompilationInstruction else {
            // The subclass-passthrough is documented behavior; failing here would mean a
            // future macOS regressed it. Crash visibly rather than silently render black.
            fatalError("CompilationCompositor received a non-CompilationInstruction")
        }
        if inst.clipIndex != lastClipIndex {
            lastClipIndex = inst.clipIndex
            lastSourceFrame = nil
        }
        let recordTime = (request.compositionTime - inst.clipCompositionStart).seconds
        let isFreeze = currentSegmentIsFreeze(inst: inst, recordTime: recordTime)

        // 1. Base: source frame (live or cached).
        var base: CVPixelBuffer?
        if isFreeze {
            base = lastSourceFrame
        } else if let sf = request.sourceFrame(byTrackID: inst.sourceTrackID) {
            lastSourceFrame = sf
            base = sf
        } else {
            base = lastSourceFrame
        }

        // 2. Output buffer + CG context (flip Y to top-left origin).
        guard let out = renderContext?.newPixelBuffer() else { request.finishCancelledRequest(); return }
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        let w = CVPixelBufferGetWidth(out), h = CVPixelBufferGetHeight(out)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let cg = CGContext(
            data: CVPixelBufferGetBaseAddress(out),
            width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(out),
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                       | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { request.finishCancelledRequest(); return }
        // newPixelBuffer() doesn't guarantee zeroed memory. Clear to black before drawing
        // so a missing base (e.g. clip starts paused with no cached frame) renders cleanly.
        cg.setFillColor(CGColor(gray: 0, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
        cg.translateBy(x: 0, y: CGFloat(h))
        cg.scaleBy(x: 1, y: -1)

        // 3. Draw base full-frame (only if we have one — otherwise the black fill remains).
        if let base, let img = makeCGImage(base) {
            cg.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }

        // 4. Webcam PiP, bottom-right at 22% width.
        if let webcam = request.sourceFrame(byTrackID: inst.webcamTrackID),
           let wImg = makeCGImage(webcam) {
            let pipW = CGFloat(w) * 0.22
            let pipH = pipW * CGFloat(CVPixelBufferGetHeight(webcam)) / CGFloat(CVPixelBufferGetWidth(webcam))
            let margin = CGFloat(h) * 0.022
            let rect = CGRect(x: CGFloat(w) - pipW - margin,
                              y: CGFloat(h) - pipH - margin,
                              width: pipW, height: pipH)
            cg.draw(wImg, in: rect)
        }

        // 5. Strokes.
        for stroke in inst.strokes where strokeIsVisible(stroke, atRecordTime: recordTime) {
            drawStroke(stroke, atRecordTime: recordTime, into: cg, size: CGSize(width: w, height: h))
        }

        // 6. Text bar via CoreText (handles emoji/RTL/CJK correctly; CGContext.draw(text:) doesn't).
        drawTextBar(inst.textBarLine, into: cg, size: CGSize(width: w, height: h))

        request.finish(withComposedVideoFrame: out)
    }

    // ... helpers: currentSegmentIsFreeze, strokeIsVisible, drawStroke (CGPath via Denormalize, flipY: true),
    // drawTextBar (CTFramesetterCreateWithAttributedString + CTFrameDraw), makeCGImage (CIImage roundtrip).
}
```

**Step 3:** Write a 1-second smoke test:
- Use `AVAssetWriter` to generate a synthetic 1-second 1080p source `.mov` of a solid green color.
- Build a `CompilationInstruction` with one stroke and a known text-bar string.
- Wrap in an `AVMutableVideoComposition` with `customVideoCompositorClass = CompilationCompositor.self`, instructions = `[that one instruction]`.
- Run an `AVAssetExportSession` with HEVC preset, output to a temp `.mov`.
- Read back via `AVAssetReader` → for frame N, wrap in `CIImage(cvPixelBuffer:)`, run `CIAreaAverage` on a sample region inside the stroke's bounding box, render via `CIContext.render(_:toBitmap:...)` to inspect a 4-byte RGBA value. Assert R > 200 (red stroke) within tolerance.
- Sample another region inside the text bar's bounding box; assert the average is darker than green (text bar's translucent black darkens the source).
- Tolerance ~10/255 to absorb HEVC compression noise.

**Step 4:** Commit.

---

### Task 9.4: `CompilationExporter` actor

**Files:**
- Create: `App/Export/CompilationExporter.swift`

**Step 1:** Implement an actor that takes a `CompilationPlan` and produces one `.mov` via `AVAssetExportSession`:

1. Builds `AVMutableComposition` with explicit track IDs:
   - Source video: `addMutableTrack(withMediaType: .video, preferredTrackID: 1)`. Insert `.play` segments only.
   - Source audio: `preferredTrackID: 2`. Insert `.play` segments only.
   - Per-clip webcam video: `preferredTrackID: 1000 + clipIndex`. Insert continuously.
   - Per-clip mic audio: `preferredTrackID: 2000 + clipIndex`. Insert continuously.
   - Verify each `addMutableTrack` returned a non-nil track and the track's `trackID` matches what we requested (it always will, because we asked for unique unused IDs).
2. Builds `AVMutableVideoComposition`:
   - `customVideoCompositorClass = CompilationCompositor.self`
   - `renderSize = ExportSettings.pixelSize(...)` (override to the source asset's natural size for `.source`)
   - `frameDuration = CMTime(value: 1, timescale: 30)` — note Task 9.0 spike confirms whether the preset overrides this; if so, set to the preset's actual rate.
   - `instructions = [CompilationInstruction]` — one per clip, populated with all per-clip context (segments, strokes, track IDs, text bar string).
   - For each `CompilationInstruction`, also build `layerInstructions` if needed (we don't strictly need them since the compositor draws everything, but declaring `requiredSourceTrackIDs` correctly via `instruction.requiredSourceTrackIDs = [sourceTrackID, webcamTrackID]` is critical so AVFoundation provides the right `sourceFrame(byTrackID:)`s).
3. Builds `AVMutableAudioMix` with `inputParameters` per audio track:
   - Source audio (track `2`): `setVolume(prefs.previewSourceVolume, at: .zero)`.
   - Each per-clip mic audio: `setVolume(prefs.previewCommentaryVolume, at: .zero)`.
   - **5ms volume ramps at every internal source-audio segment boundary**: for each clip's `playbackSegments`, every time we hit a `.play → .freeze` or `.freeze → .play` boundary at output time `T`, call:
     ```swift
     params.setVolumeRamp(fromStartVolume: prefs.previewSourceVolume,
                          toEndVolume: 0,
                          timeRange: CMTimeRange(start: T - 0.005s, duration: 0.005s))
     params.setVolumeRamp(fromStartVolume: 0,
                          toEndVolume: prefs.previewSourceVolume,
                          timeRange: CMTimeRange(start: T, duration: 0.005s))
     ```
   - This eliminates AAC click artifacts at interior cuts (priming compensation only applies at file start; interior slices are hard cuts at non-zero amplitude).
4. Configures `AVAssetExportSession`:
   - `outputFileType = .mov`
   - `outputURL = outputFolder/<tag> - <projectName>.mov`
   - `videoComposition = ourVideoComposition`
   - `audioMix = ourAudioMix`
   - `presetName` chosen by `Quality` (subject to Task 9.0 spike outcome).
5. Progress: poll `exportSession.progress` (a `Float`) at 5Hz on a `Task`, expose via `AsyncStream<Float>`. Stop polling when `exportSession.status` becomes `.completed`/`.failed`/`.cancelled`. Polling is more reliable across macOS versions than KVO on `progress`.

**Step 2:** Smoke test — export a small project with one clip containing two pause boundaries + one stroke + one skip. Inspect in QuickTime: verify source plays, freezes hold the right frame, PiP webcam bottom-right, audio mix balances, text bar renders correctly (try a tag with an emoji like `⚽` to confirm CoreText shaping), stroke replays at natural tempo, **no audible click at the pause boundaries** (the volume ramps doing their job).

**Step 3:** Commit.

---

### Task 9.5: Export sheet UI

**Files:**
- Create: `App/Export/ExportSheet.swift`

**Step 1:** Build a SwiftUI sheet that:
- Reads `TagAggregation.aggregate(project:)` for rows.
- Adds a synthetic `all-clips` row at top.
- Shows checkboxes, Select All / None, Resolution + Quality dropdowns.
- Project name field (prefilled from folder name), output folder picker.
- Export button → kicks off `CompilationExporter` per checked row sequentially, shows progress per tag.

**Step 2:** Manual test the full path: open a project with several clips and varied tags → Export → pick output folder → run. Verify per-tag `.mov` files appear with the expected filenames and contents.

**Step 3:** Commit.

---

### Task 9.6 (conditional, only if 9.0 says so): Reader/Writer fallback

If the spike (Task 9.0) shows `AVAssetExportSession` cannot deliver the bitrate range we want, replace the export-session call in `CompilationExporter` with an `AVAssetReader` → `AVAssetWriter` pipeline. Reuses the same custom compositor (the writer's `AVAssetWriterInput.requestMediaDataWhenReady(on:)` pull loop reads from an `AVAssetReaderVideoCompositionOutput` configured with our compositor). Audio uses a parallel `AVAssetReaderAudioMixOutput` → `AVAssetWriterInput`. Progress is computed from the latest appended PTS divided by the plan's `totalDurationSeconds`.

Skip this task if 9.0 confirms ExportSession is sufficient.

---

## Phase 10 — Polish & integration pass

### Task 10.1: Mode-aware keyboard shortcuts

Verify all shortcuts work in their correct modes; reject conflicting events. Manual test pass.

### Task 10.2: Drag-to-reorder clip list

Implement reorder, persist new `sortIndex` on drop. Manual test export sequence reflects new order.

### Task 10.3: Clip preview drawings replay

Reuse the export's stroke layer code in Mode C preview. Verify strokes animate at their natural tempo and disappear at the right time.

### Task 10.4: Empty/error states

- "No source video added" empty state.
- "Source video missing" with Relink button.
- Export errors surfaced as alerts.

### Task 10.5: Manual integration checklist

End-to-end smoke test, including:
- 1 source / 2 sources scenarios.
- Pause + skip + draw + clear within a single recording.
- Auto-clear toggle behavior during recording.
- Export at every Resolution × Quality combo.
- Reopen project after restart, edit metadata, re-export.
- **Clap-sync test for A/V alignment**: record one clip with a visible+audible clap mid-clip, plus a `.skip(+3)` later in the recording. After export, single-frame-step the result and confirm visual clap and audio clap align within one frame, and that the skip event correctly jumps the source video without desyncing the webcam PiP from the mic audio.
- **Internal-cut click test**: record a clip with TWO pause/play boundaries in close succession. Listen carefully to the export at each boundary — confirm there's no audible click in the source audio (proving the 5ms volume ramps from Task 9.4 are doing their job).
- **Continuity Camera path**: pair an iPhone via Continuity Camera, record one clip, verify capture format and the resulting PiP geometry in the export. (Confirms the explicit `device.activeFormat` selection from Task 7.1 actually yielded a 16:9 720p capture rather than a 4:3 1440p Continuity default.)
- **Permission denial path**: revoke camera or microphone in System Settings, relaunch, verify the empty state from Task 1.4 shows correctly.

Each item gets a verification commit message.

---

## Open follow-ups (after v1)

Synced with the design doc's Open items (single canonical list there).

## Spike outcomes

(populated as Phase 9.0 runs)

- **AVAssetExportSession + custom compositor + custom audioMix + HEVC preset** (the risky combination from Task 9.0):
  - ☐ Compositor invoked (frames are red, not green).
  - ☐ Audio mix honored (output ~12dB attenuated).
  - ☐ HEVC bitrate brackets 6/12/24 Mbps targets.
  - ☐ `frameDuration = 30fps` honored (vs preset override).
  - **Decision**: ☐ proceed with ExportSession (Tasks 9.1–9.5 only) / ☐ promote Task 9.6 to mandatory and use `AVAssetReader`/`AVAssetWriter`.

---

## Reference skills

- @superpowers:test-driven-development for the Phase 2–4 logic tasks.
- @superpowers:systematic-debugging when AVFoundation behavior surprises you (it will).
- @superpowers:verification-before-completion before claiming any task done.
