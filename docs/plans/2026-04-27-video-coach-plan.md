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
- Create: `VideoCoachCore/Sources/VideoCoachCore/.gitkeep`
- Create: `VideoCoachCore/Tests/VideoCoachCoreTests/.gitkeep`

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

**Step 2:** Touch placeholder source files so the package builds:
```bash
mkdir -p VideoCoachCore/Sources/VideoCoachCore VideoCoachCore/Tests/VideoCoachCoreTests
touch VideoCoachCore/Sources/VideoCoachCore/.gitkeep VideoCoachCore/Tests/VideoCoachCoreTests/.gitkeep
```

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
    func test_normalizeTags_lowercasesAndTrimsAndDropsCommas() {
        XCTAssertEqual(
            Tag.normalize(input: " Attacking-Chance, transitions , set,piece "),
            ["attacking-chance", "transitions", "setpiece"]
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
        input
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ",", with: "") }
            .filter { !$0.isEmpty }
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

**Step 1:** Write the workspace observable model:

```swift
import Foundation
import VideoCoachCore
import AVFoundation
import Observation

@Observable
final class Workspace {
    var folder: URL?
    var project: Project = Project(name: "Untitled")
    var virtualPlayer: AVPlayer?
    var virtualComposition: AVMutableComposition?

    func openProject(folder: URL) throws {
        self.folder = folder
        let p = (try? ProjectStore.read(from: folder)) ?? Project(name: folder.lastPathComponent)
        self.project = p
        try ProjectStore.write(p, to: folder)
        try rebuildVirtualPlayer()
    }

    func saveProject() throws {
        guard let folder else { return }
        try ProjectStore.write(project, to: folder)
    }

    func rebuildVirtualPlayer() throws {
        guard !project.sourceVideos.isEmpty else { virtualPlayer = nil; return }
        let urls = try project.sourceVideos.map { try resolveBookmark($0.bookmark) }
        let comp = AVMutableComposition()
        let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let a = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            let dur = try await? asset.load(.duration)
            let tr = try await? asset.load(.tracks).first { $0.mediaType == .video }
            // Simpler synchronous path for v1: use legacy API
            let videoTrack = asset.tracks(withMediaType: .video).first!
            let audioTrack = asset.tracks(withMediaType: .audio).first
            let range = CMTimeRange(start: .zero, duration: asset.duration)
            try v.insertTimeRange(range, of: videoTrack, at: cursor)
            if let audioTrack { try? a.insertTimeRange(range, of: audioTrack, at: cursor) }
            cursor = cursor + asset.duration
        }
        let item = AVPlayerItem(asset: comp)
        self.virtualComposition = comp
        self.virtualPlayer = AVPlayer(playerItem: item)
    }

    private func resolveBookmark(_ data: Data) throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: data,
                          options: [.withSecurityScope],
                          relativeTo: nil,
                          bookmarkDataIsStale: &stale)
        _ = url.startAccessingSecurityScopedResource()
        return url
    }
}
```

(Note: simplified synchronous AVAsset API is fine for v1; revisit async loading for performance later.)

**Step 2:** Build the app target (`⌘B` in Xcode). Expected: succeeds. Commit:
```bash
git add App/Models/Workspace.swift
git commit -m "feat(app): Workspace observable model + virtual concat builder"
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
            try? workspace.openProject(folder: url)
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

**Step 1:** Add to `Workspace`:

```swift
func addSourceVideo(url: URL) throws {
    let bookmark = try url.bookmarkData(options: .withSecurityScope)
    let asset = AVURLAsset(url: url)
    let dur = asset.duration.seconds
    project.sourceVideos.append(.init(
        bookmark: bookmark,
        displayName: url.lastPathComponent,
        durationSeconds: dur))
    try saveProject()
    try rebuildVirtualPlayer()
}
```

**Step 2:** Add a button in `ContentView` next to Open Project:

```swift
Button("Add Source Video…") {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
        try? workspace.addSourceVideo(url: url)
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

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers ?? ""
        switch (event.keyCode, chars) {
        case (123 /* ← */, _), (_, "a"): onSkip(-3)
        case (124 /* → */, _), (_, "d"): onSkip(+3)
        case (49  /* space */, _):       onTogglePlay()
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

**Step 1:** Implement `AppMode`:

```swift
import Foundation
enum AppMode: Equatable { case scanning, recording, previewClip(Clip.ID) }
```

**Step 2:** Implement empty `ClipSidebar`/`ClipInspector` placeholders that read from `Workspace`. Switch `ContentView` to a three-pane `NavigationSplitView` with the player surface in the detail column.

(Skipping verbatim UI Swift here — straightforward NavigationSplitView + List(workspace.project.clips).)

**Step 3:** Run. Verify 3-pane layout shows project name top-left, empty clip list, player center, empty inspector right. Commit.

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

**Step 1:** Implement a class wrapping `AVCaptureSession` + `AVCaptureMovieFileOutput`. It exposes:

```swift
@Observable
final class CaptureSessionController {
    private(set) var isReady = false
    private(set) var isRecording = false
    let session: AVCaptureSession
    private let output = AVCaptureMovieFileOutput()
    private var delegate: Delegate?

    init() {
        session = AVCaptureSession()
        session.sessionPreset = .high
    }

    func configure() async throws { /* request perms, add inputs, add output */ }
    func startRecording(to url: URL) async throws -> Date { /* returns wall-clock start */ }
    func stopRecording() async throws -> Double { /* returns recording duration seconds */ }
}
```

**Step 2:** Call `configure()` from the app on first launch. Add a debug "Test Capture" button that records 3 seconds to a temp `.mov` and prints duration. Commit.

---

### Task 7.2: `RecordingController` driving the event log

**Files:**
- Create: `App/Recording/RecordingController.swift`

**Step 1:** Implement an observable that:
- Owns an `events: [CommentaryEvent]` array.
- Tracks `startTime: CFTimeInterval = CACurrentMediaTime()` set on `start()`.
- Has methods: `appendPlay()`, `appendPause()`, `appendSkip(delta:)`, `appendStroke(Stroke)`, `appendClearAll()` — each computes `recordTime = CACurrentMediaTime() - startTime` and appends.
- On `finish()`, returns the events array for assembly into a `Clip`.

**Step 2:** Add minimal unit tests in the app target's test bundle: simulate a sequence of calls, verify `recordTime` is monotonically increasing. Commit.

---

### Task 7.3: Drawing overlay with 60Hz throttle

**Files:**
- Create: `App/Drawing/DrawingOverlayView.swift`

**Step 1:** `NSView` subclass over the AVPlayerLayer. On `mouseDown:` start a stroke; on `mouseDragged:` consider committing a new point; on `mouseUp:` emit the stroke through a callback.

Throttle:
```swift
private var lastPointTime: TimeInterval = 0
private var lastPointPx: NSPoint = .zero
private let minDt: TimeInterval = 1.0 / 60.0
private let minPx: CGFloat = 1.0

override func mouseDragged(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    let now = CACurrentMediaTime()
    if now - lastPointTime < minDt { return }
    if hypot(p.x - lastPointPx.x, p.y - lastPointPx.y) < minPx { return }
    let nx = p.x / bounds.width
    let ny = 1.0 - p.y / bounds.height   // flip Y so 0 = top
    let stroke_t = now - strokeStartTime
    inProgressPoints.append(.init(x: nx, y: ny, t: stroke_t))
    lastPointTime = now; lastPointPx = p
    setNeedsDisplay(bounds)
}
```

**Step 2:** Render in-progress stroke + finished strokes via `draw(_:)` using NSBezierPath converted from normalized points.

**Step 3:** Run. Toggle a debug "drawing mode" and verify strokes draw smoothly and survive when toggled off. Commit.

---

### Task 7.4: Wire Mode B end-to-end

**Files:**
- Modify: `App/ContentView.swift`
- Modify: `App/Models/Workspace.swift`
- Modify: `App/Views/KeyCommandView.swift`

**Step 1:** When `R` is pressed in Mode A:
- Generate a UUID + filename.
- Start `CaptureSessionController.startRecording(to: recordingsDir/clip-<uuid>.mov)`.
- Start `RecordingController`. Append initial `.play` event at `recordTime = 0`.
- Set `appMode = .recording`.
- Set `virtualPlayer.rate = 1.0`.
- Show drawing overlay.

**Step 2:** While `appMode == .recording`, the key handler routes:
- `space` → toggle player rate AND append `.play` or `.pause` to RecordingController.
- arrows/AD → seek + append `.skip(delta:)`.
- `R` / `esc` → stop recording.

**Step 3:** On stop:
- `stopRecording()` → returns duration.
- Build `Clip` from RecordingController's events + capture metadata.
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

### Task 8.1: Compositional `AVPlayer` for a clip

**Files:**
- Create: `App/Preview/ClipPreviewBuilder.swift`

**Step 1:** Implement a function `func buildPreviewItem(for clip: Clip, project: Project) throws -> AVPlayerItem` that:
- Uses the same `playbackSegments(sourceDuration:)` logic from `VideoCoachCore`.
- Builds `AVMutableComposition` with source-video segments + freeze segments + webcam PiP video track + source audio + mic audio.
- Builds `AVMutableVideoComposition` with PiP transform.
- Builds `AVMutableAudioMix` reflecting `preferences.previewSourceVolume` + `preferences.previewCommentaryVolume`.
- Adds a `Core Animation` overlay layer for strokes (reuse builder from Phase 9).

**Step 2:** When a clip is selected in the sidebar, replace the player's `AVPlayerItem` with the preview item.

**Step 3:** Run. Click a recorded clip. Verify it plays back as composited. Toggle volume sliders → live mix updates. Commit.

---

## Phase 9 — Export pipeline

### Task 9.1: `CompilationBuilder` for one tag (TDD on the math)

**Files:**
- Create: `VideoCoachCore/Sources/VideoCoachCore/CompilationPlan.swift`
- Create: `VideoCoachCore/Tests/VideoCoachCoreTests/CompilationPlanTests.swift`

**Step 1:** Define an in-memory plan describing the output composition (clip ranges, segment lists, total duration). Pure data, no AVFoundation.

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
    func compilationPlan(for tag: String, sourceDurations: [Int: Double]) -> CompilationPlan { /*…*/ }
    func allClipsCompilationPlan(sourceDurations: [Int: Double]) -> CompilationPlan { /*…*/ }
}
```

**Step 2:** Write tests covering: filtering by tag, sort order, accumulating compositionStart, all-clips ordering. Implement to make them pass.

**Step 3:** Commit.

---

### Task 9.2: `AVAssetWriter` exporter

**Files:**
- Create: `App/Export/CompilationExporter.swift`

**Step 1:** Implement an actor that takes a `CompilationPlan` and:
1. Builds `AVMutableComposition` per the plan (using `playbackSegments`, including the time-stretched freeze trick).
2. Builds `AVMutableVideoComposition` with PiP transform per entry.
3. Builds `AVMutableAudioMix`.
4. Builds the Core Animation layer hierarchy with stroke `CAShapeLayer`s + per-clip text bar.
5. Configures `AVAssetWriter` with HEVC settings from `ExportSettings.bitrate` and `ExportSettings.pixelSize`.
6. Drives `AVAssetReader` → `AVAssetWriter` pipeline. Reports progress via an `AsyncStream<Double>`.

**Step 2:** Smoke test by exporting a single 5-second compilation manually. Inspect the output in QuickTime: verify source plays, PiP webcam shows bottom-right, audio mixes correctly, text bar renders, strokes animate at the same speed they were drawn.

**Step 3:** Commit.

---

### Task 9.3: Export sheet UI

**Files:**
- Create: `App/Export/ExportSheet.swift`

**Step 1:** Build a SwiftUI sheet that:
- Reads `TagAggregation.aggregate(project:)` for rows.
- Adds a synthetic "all-clips" row at top.
- Shows checkboxes, Select All / None, Resolution + Quality dropdowns.
- Project name field (prefilled), output folder picker.
- Export button → kicks off `CompilationExporter` per checked row, shows progress.

**Step 2:** Manual test the full path: open a project with several clips and varied tags → Export → pick output folder → run. Verify per-tag MP4s appear with the expected filenames and contents.

**Step 3:** Commit.

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

Each item gets a verification commit message.

---

## Open follow-ups (after v1)

These are explicitly out of scope for this plan; track them as later issues.

- Re-trim a clip's start/end after creation.
- Color/width pickers for drawings.
- Camera + mic device selection in Preferences.
- Per-clip volume overrides.
- Crash-safe partial-recording recovery sidecar.
- Configurable PiP corner / size.
- Tag rename / merge across all clips.
- Export preview thumbnail + duration estimate before encode.
- Async `AVAsset.load(.duration)` modernization.

---

## Reference skills

- @superpowers:test-driven-development for the Phase 2–4 logic tasks.
- @superpowers:systematic-debugging when AVFoundation behavior surprises you (it will).
- @superpowers:verification-before-completion before claiming any task done.
