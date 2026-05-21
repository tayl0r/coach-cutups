# Clip Transcript + Summary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-transcribe every new recording's mic audio via macOS 26 `SpeechAnalyzer`, summarize via `FoundationModels`, and store both on `Clip` as user-editable fields. Manual "Transcribe" button in the inspector for backfill / re-run.

**Architecture:** A `ClipIntelligence` protocol in `VideoCoachCore` with a concrete `AppleClipIntelligence` (real) and a `FakeClipIntelligence` (tests). A `@MainActor @Observable TranscriptionCoordinator` in the app owns a serial async Task chain, drives the protocol, and writes results into `Workspace.project.clips[i]` via a new `applyAIWrite` helper that saves but **does not push undo**. The inspector grows transcript + summary TextEditors with their own focus snapshots, identical to how `notes` works today.

**Tech Stack:** Swift 5.9, SwiftUI, AVFoundation, `Speech` (macOS 26 `SpeechAnalyzer` / `SpeechTranscriber`), `FoundationModels` (macOS 26 on-device LLM), `VideoCoachCore` Swift Package, XCTest, `xcodebuild`, `xcodegen`.

**Spec:** `docs/superpowers/specs/2026-05-21-clip-transcript-and-summary-design.md`.

**Working branch:** create `clip-ai-transcript` at execution time via the `superpowers:using-git-worktrees` skill.

**Canonical test commands:**

- Core package: `swift test --package-path apple/VideoCoachCore`
- App unit tests: `cd apple && xcodebuild -project VideoCoach.xcodeproj -scheme VideoCoach -only-testing:VideoCoachTests test`
- App full build: `cd apple && xcodegen generate && cd .. && xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build`

---

## Task 1: Bump deployment target + Info.plist + project config

**Files:**

- Modify: `apple/project.yml`
- Modify: `apple/VideoCoachCore/Package.swift`

- [ ] **Step 1: Bump deployment target in `apple/project.yml`**

In every `MACOSX_DEPLOYMENT_TARGET: "14.0"` line, replace `"14.0"` with `"26.0"`. Also update `LSMinimumSystemVersion: "14.0"` to `"26.0"`, and the top-level `deploymentTarget.macOS: "14.0"` to `"26.0"`.

Add `NSSpeechRecognitionUsageDescription` to the `info.properties` block for the `VideoCoach` app target (it currently contains `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `CFBundleDisplayName`, `LSMinimumSystemVersion`):

```yaml
NSSpeechRecognitionUsageDescription: Video Coach transcribes your recorded commentary on-device so you can review and search what you said.
```

Add `App/Intelligence/TranscriptionCoordinator.swift` to the `VideoCoachTests.sources` list (matches the existing `App/Recording/RecordingController.swift` include). The final `sources` block should be:

```yaml
sources:
  - path: Tests/AppTests
  - path: App/Recording/RecordingController.swift
  - path: App/Intelligence/TranscriptionCoordinator.swift
  - path: App/Preview/ClipPreviewBuilder.swift
  - path: VideoCoachCore/Tests/VideoCoachCoreTests/Helpers/SyntheticAsset.swift
```

- [ ] **Step 2: Bump `Package.swift`**

Replace `platforms: [.macOS(.v14)]` with `platforms: [.macOS(.v26)]`:

```swift
let package = Package(
    name: "VideoCoachCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "VideoCoachCore", targets: ["VideoCoachCore"]),
    ],
    targets: [
        .target(name: "VideoCoachCore"),
        .testTarget(name: "VideoCoachCoreTests", dependencies: ["VideoCoachCore"]),
    ]
)
```

- [ ] **Step 3: Regenerate the Xcode project and verify it still builds**

```bash
cd apple && xcodegen generate && cd ..
xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build
```

Expected: build SUCCEEDED. No source files have changed yet — only project config — so any error is a config issue.

- [ ] **Step 4: Verify Core tests still pass**

```bash
swift test --package-path apple/VideoCoachCore
```

Expected: all existing tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apple/project.yml apple/VideoCoachCore/Package.swift apple/VideoCoach.xcodeproj
git commit -m "config: bump macOS deployment target to 26 for Speech + FoundationModels"
```

---

## Task 2: Clip v5 — `transcript` + `summary` fields with custom Codable + migration test

**Files:**

- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/Project.swift`
- Test: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ProjectTests.swift`
- Test: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ProjectStoreTests.swift`

- [ ] **Step 1: Write the failing v4-fixture migration test in `ProjectTests.swift`**

Append:

```swift
func test_v4ClipMissingTranscriptAndSummary_decodesToEmptyStrings() throws {
    // Hand-written v4 JSON: full Clip with no `transcript` and no `summary`
    // keys. This is the canonical regression test for additive Clip-field
    // migrations going forward.
    let v4JSON = """
    {
      "formatVersion": 4,
      "name": "LegacyV4",
      "sourceVideos": [],
      "clips": [{
        "id": "11111111-2222-3333-4444-555555555555",
        "name": "old clip",
        "notes": "hand-written notes",
        "tags": ["legacy"],
        "sourceIndex": 0,
        "startSourceSeconds": 0,
        "recordingDuration": 1.5,
        "recordingFilename": "c.mov",
        "events": [],
        "showPiP": true,
        "sortIndex": 0,
        "createdAt": "2025-01-01T00:00:00Z"
      }],
      "preferences": {
        "scanVolume": 1.0,
        "previewSourceVolume": 1.0,
        "previewCommentaryVolume": 1.0,
        "lastExportResolution": "r1080",
        "lastExportQuality": "medium",
        "pipForNewRecordings": true
      },
      "matchEvents": []
    }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let p = try decoder.decode(Project.self, from: v4JSON)
    XCTAssertEqual(p.clips.count, 1)
    XCTAssertEqual(p.clips[0].transcript, "")
    XCTAssertEqual(p.clips[0].summary, "")
    XCTAssertEqual(p.clips[0].notes, "hand-written notes",
                   "existing user-written notes must survive untouched")
}

func test_transcriptAndSummaryRoundtripThroughJSON() throws {
    var p = Project(name: "M")
    p.clips.append(Clip(
        name: "c", sourceIndex: 0, startSourceSeconds: 0,
        recordingDuration: 1, recordingFilename: "c.mov",
        sortIndex: 0
    ))
    p.clips[0].transcript = "okay so right here the through-ball really opens up the line"
    p.clips[0].summary = "Coach praises the through-ball that opens the line."

    let data = try JSONEncoder().encode(p)
    let decoded = try JSONDecoder().decode(Project.self, from: data)
    XCTAssertEqual(decoded.clips[0].transcript,
                   "okay so right here the through-ball really opens up the line")
    XCTAssertEqual(decoded.clips[0].summary,
                   "Coach praises the through-ball that opens the line.")
}

func test_freshProjectFormatVersionIs5() throws {
    XCTAssertEqual(Project.currentFormatVersion, 5)
    XCTAssertEqual(Project(name: "M").formatVersion, 5)
}
```

- [ ] **Step 2: Update the existing `test_emptyProjectRoundtripsThroughJSON` and `test_freshProjectHasShowPiPDefaultsAndFormatVersion` assertions**

In `ProjectTests.swift`, change both occurrences of `XCTAssertEqual(decoded.formatVersion, 4)` / `XCTAssertEqual(p.formatVersion, 4)` to `5`. Same for `test_projectStore_writeBumpsFormatVersionToCurrent` (`XCTAssertEqual(reread.formatVersion, 4, ...)` → `5`).

- [ ] **Step 3: Run the new tests, confirm FAIL**

```bash
swift test --package-path apple/VideoCoachCore --filter "ProjectTests.test_v4ClipMissingTranscriptAndSummary_decodesToEmptyStrings" --filter "ProjectTests.test_transcriptAndSummaryRoundtripThroughJSON" --filter "ProjectTests.test_freshProjectFormatVersionIs5"
```

Expected: all three FAIL — `transcript`/`summary` don't exist, `currentFormatVersion` is 4.

- [ ] **Step 4: Add the new fields to `Clip` and bump `currentFormatVersion`**

In `apple/VideoCoachCore/Sources/VideoCoachCore/Project.swift`, change `Clip` to add the two fields **with default values in declaration** (defaults are used by the memberwise init; the custom decoder added next is what handles missing-key decode):

```swift
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
    public var showPiP: Bool
    public var sortIndex: Int
    public var createdAt: Date

    public var transcript: String
    public var summary: String

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
        showPiP: Bool = true,
        sortIndex: Int,
        createdAt: Date = .init(),
        transcript: String = "",
        summary: String = ""
    ) {
        self.id = id; self.name = name; self.notes = notes; self.tags = tags
        self.sourceIndex = sourceIndex; self.startSourceSeconds = startSourceSeconds
        self.recordingDuration = recordingDuration; self.recordingFilename = recordingFilename
        self.events = events
        self.showPiP = showPiP
        self.sortIndex = sortIndex; self.createdAt = createdAt
        self.transcript = transcript
        self.summary = summary
    }
}
```

Bump `currentFormatVersion`:

```swift
public extension Project {
    /// Schema version history:
    /// - v1: original schema (no formatVersion field)
    /// - v2: added `.zoom` event variant
    /// - v3: added per-clip PiP visibility
    /// - v4: added `scoreboard` (TeamConfig + MatchFormat) and `matchEvents`
    /// - v5: added per-clip `transcript` + `summary` (auto-populated by
    ///       AppleClipIntelligence; user-editable)
    static let currentFormatVersion: Int = 5
}
```

- [ ] **Step 5: Add the custom `Clip.init(from:)` so missing keys default to `""`**

Swift's synthesized `Decodable` does NOT honour stored-property defaults — it always calls `decode`, never `decodeIfPresent`. So we need a custom decoder ONLY for the read side. Encoding stays synthesised.

Append to `apple/VideoCoachCore/Sources/VideoCoachCore/Project.swift`:

```swift
public extension Clip {
    private enum CodingKeys: String, CodingKey {
        case id, name, notes, tags, sourceIndex, startSourceSeconds,
             recordingDuration, recordingFilename, events, showPiP,
             sortIndex, createdAt, transcript, summary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id                  = try c.decode(UUID.self,              forKey: .id)
        self.name                = try c.decode(String.self,            forKey: .name)
        self.notes               = try c.decode(String.self,            forKey: .notes)
        self.tags                = try c.decode([String].self,          forKey: .tags)
        self.sourceIndex         = try c.decode(Int.self,               forKey: .sourceIndex)
        self.startSourceSeconds  = try c.decode(Double.self,            forKey: .startSourceSeconds)
        self.recordingDuration   = try c.decode(Double.self,            forKey: .recordingDuration)
        self.recordingFilename   = try c.decode(String.self,            forKey: .recordingFilename)
        self.events              = try c.decode([CommentaryEvent].self, forKey: .events)
        self.showPiP             = try c.decode(Bool.self,              forKey: .showPiP)
        self.sortIndex           = try c.decode(Int.self,               forKey: .sortIndex)
        self.createdAt           = try c.decode(Date.self,              forKey: .createdAt)
        self.transcript          = try c.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        self.summary             = try c.decodeIfPresent(String.self, forKey: .summary)    ?? ""
    }
}
```

- [ ] **Step 6: Update `ProjectStoreTests.test_unsupportedFutureFormatVersion_isRejected` if needed**

That test reads `Project.currentFormatVersion + 1` so it is self-updating — no code change. Confirm by re-reading the test.

- [ ] **Step 7: Run Core tests, confirm all PASS**

```bash
swift test --package-path apple/VideoCoachCore
```

Expected: all PASS, including the three new tests and every previously-existing test (notably the round-trip tests with the new memberwise init parameters).

- [ ] **Step 8: Commit**

```bash
git add apple/VideoCoachCore
git commit -m "model: v5 — add Clip.transcript + .summary with v4 decode migration"
```

---

## Task 3: `ClipIntelligence` protocol + `FakeClipIntelligence` (Core)

**Files:**

- Create: `apple/VideoCoachCore/Sources/VideoCoachCore/Intelligence/ClipIntelligence.swift`
- Create: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/Helpers/FakeClipIntelligence.swift`
- Test: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/FakeClipIntelligenceTests.swift`

- [ ] **Step 1: Create the protocol**

Create `apple/VideoCoachCore/Sources/VideoCoachCore/Intelligence/ClipIntelligence.swift`:

```swift
import Foundation

/// Pure-logic seam for the on-device transcription + summarization
/// pipeline. The real implementation (`AppleClipIntelligence`) imports
/// `Speech` and `FoundationModels`; the test fake returns canned
/// strings so coordinator tests are deterministic and run headlessly.
public protocol ClipIntelligence: Sendable {
    /// Transcribes the audio track of the file at `audioURL`. Returns the
    /// full transcript as a single string. Newlines are preserved between
    /// recognized segments so a future viewer can render with breaks.
    func transcribe(audioURL: URL) async throws -> String

    /// Returns a 1–2 sentence summary of `transcript`. The implementation
    /// is responsible for shaping the prompt; callers pass raw text only.
    func summarize(_ transcript: String) async throws -> String
}
```

- [ ] **Step 2: Create the test fake**

Create `apple/VideoCoachCore/Tests/VideoCoachCoreTests/Helpers/FakeClipIntelligence.swift`:

```swift
import Foundation
@testable import VideoCoachCore

/// Test fake. Returns whatever was configured. Records every call.
/// Supports per-call delay so tests can assert serial-queue behavior.
final class FakeClipIntelligence: ClipIntelligence, @unchecked Sendable {
    var transcriptToReturn: String = "fake transcript"
    var summaryToReturn: String = "fake summary."
    var transcribeError: Error?
    var summarizeError: Error?
    var transcribeDelaySeconds: Double = 0
    var summarizeDelaySeconds: Double = 0

    private(set) var transcribeCalls: [URL] = []
    private(set) var summarizeCalls: [String] = []

    /// If true, asserts that transcribe + summarize calls never overlap.
    /// Used by the "serial queue" test.
    var assertNoOverlap = false
    private var inFlightCount = 0
    private let inFlightLock = NSLock()

    func transcribe(audioURL: URL) async throws -> String {
        try await beginWork(); defer { endWork() }
        transcribeCalls.append(audioURL)
        if transcribeDelaySeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(transcribeDelaySeconds * 1_000_000_000))
        }
        if let e = transcribeError { throw e }
        return transcriptToReturn
    }

    func summarize(_ transcript: String) async throws -> String {
        try await beginWork(); defer { endWork() }
        summarizeCalls.append(transcript)
        if summarizeDelaySeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(summarizeDelaySeconds * 1_000_000_000))
        }
        if let e = summarizeError { throw e }
        return summaryToReturn
    }

    private func beginWork() async throws {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        if assertNoOverlap && inFlightCount > 0 {
            throw NSError(
                domain: "FakeClipIntelligence", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "overlapping work detected (jobs should be serial)"])
        }
        inFlightCount += 1
    }

    private func endWork() {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        inFlightCount -= 1
    }
}
```

- [ ] **Step 3: Write a smoke test for the fake itself**

Create `apple/VideoCoachCore/Tests/VideoCoachCoreTests/FakeClipIntelligenceTests.swift`:

```swift
import XCTest
@testable import VideoCoachCore

final class FakeClipIntelligenceTests: XCTestCase {
    func test_returnsConfiguredStrings() async throws {
        let fake = FakeClipIntelligence()
        fake.transcriptToReturn = "T"
        fake.summaryToReturn = "S"
        let t = try await fake.transcribe(audioURL: URL(fileURLWithPath: "/tmp/x.mov"))
        let s = try await fake.summarize(t)
        XCTAssertEqual(t, "T")
        XCTAssertEqual(s, "S")
        XCTAssertEqual(fake.transcribeCalls.first?.lastPathComponent, "x.mov")
        XCTAssertEqual(fake.summarizeCalls.first, "T")
    }

    func test_throwsConfiguredErrorOnTranscribe() async {
        let fake = FakeClipIntelligence()
        fake.transcribeError = NSError(domain: "T", code: 42)
        do {
            _ = try await fake.transcribe(audioURL: URL(fileURLWithPath: "/x"))
            XCTFail("expected throw")
        } catch let e as NSError {
            XCTAssertEqual(e.domain, "T")
            XCTAssertEqual(e.code, 42)
        }
    }
}
```

- [ ] **Step 4: Run Core tests, confirm PASS**

```bash
swift test --package-path apple/VideoCoachCore
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add apple/VideoCoachCore
git commit -m "core: ClipIntelligence protocol + FakeClipIntelligence test seam"
```

---

## Task 4: `Workspace.applyAIWrite` helper

**Files:**

- Modify: `apple/App/Models/Workspace.swift`
- Test: `apple/Tests/AppTests/WorkspaceAIWriteTests.swift` (new)

- [ ] **Step 1: Write the failing test**

Create `apple/Tests/AppTests/WorkspaceAIWriteTests.swift`:

```swift
import XCTest
import VideoCoachCore
@testable import VideoCoach

@MainActor
final class WorkspaceAIWriteTests: XCTestCase {
    private func makeWorkspace(withClip clipID: UUID = UUID()) -> Workspace {
        let ws = Workspace()
        var p = Project(name: "T")
        p.clips.append(Clip(
            id: clipID, name: "c",
            sourceIndex: 0, startSourceSeconds: 0,
            recordingDuration: 1, recordingFilename: "c.mov",
            sortIndex: 0
        ))
        ws.project = p
        return ws
    }

    func test_applyAIWrite_mutatesClipAndPreservesOtherFields() {
        let id = UUID()
        let ws = makeWorkspace(withClip: id)
        ws.project.clips[0].notes = "user-written"

        ws.applyAIWrite(id: id) { $0.transcript = "hello world" }

        XCTAssertEqual(ws.project.clips[0].transcript, "hello world")
        XCTAssertEqual(ws.project.clips[0].notes, "user-written",
                       "notes must not be touched by an AI write")
    }

    func test_applyAIWrite_shortCircuitsOnMissingClipID() {
        let ws = makeWorkspace()
        let bogus = UUID()
        ws.applyAIWrite(id: bogus) { $0.transcript = "X" }
        XCTAssertEqual(ws.project.clips[0].transcript, "",
                       "missing clip ID must be a no-op, not a crash")
    }

    func test_applyAIWrite_doesNotPushUndo() {
        let id = UUID()
        let ws = makeWorkspace(withClip: id)
        XCTAssertFalse(ws.canUndo)
        ws.applyAIWrite(id: id) { $0.summary = "anything" }
        XCTAssertFalse(ws.canUndo, "AI writes must not push undo entries")
    }
}
```

- [ ] **Step 2: Run the test, confirm it FAILs to compile (no `applyAIWrite` yet)**

```bash
cd apple && xcodebuild -project VideoCoach.xcodeproj -scheme VideoCoach -only-testing:VideoCoachTests/WorkspaceAIWriteTests test
```

Expected: compile error — `applyAIWrite` doesn't exist.

- [ ] **Step 3: Add the helper to `Workspace.swift`**

Append a new `extension Workspace` to `apple/App/Models/Workspace.swift` (or add inside the class body; either works). Place it near `addClip` so AI-write helpers are visually grouped with other clip-mutating helpers:

```swift
// MARK: - AI-driven writes (transcript / summary)

extension Workspace {
    /// Apply an AI-generated mutation directly to a clip. Saves the
    /// project. Does NOT push an undo entry — AI writes are not user
    /// actions and don't participate in the undo stack.
    ///
    /// Why no undo push: the inspector's focus-snapshot pattern
    /// (ClipInspector.EditorView) diffs the WHOLE Clip on focus-loss.
    /// If we pushed undo entries from out-of-band AI writes, a
    /// concurrent user edit's focus-loss flush would bundle the AI
    /// write into the user's undo step — cmd-z of (say) a notes edit
    /// would silently revert the AI write. Routing AI writes around
    /// the undo stack avoids this. Users who want different transcript
    /// or summary content can edit the fields directly; those edits DO
    /// go through the standard focus-snapshot undo path.
    func applyAIWrite(id: Clip.ID, _ mutate: (inout Clip) -> Void) {
        guard let i = project.clips.firstIndex(where: { $0.id == id })
        else { return }
        mutate(&project.clips[i])
        try? saveProject()
    }
}
```

- [ ] **Step 4: Run tests, confirm PASS**

```bash
cd apple && xcodebuild -project VideoCoach.xcodeproj -scheme VideoCoach -only-testing:VideoCoachTests/WorkspaceAIWriteTests test
```

Expected: all three tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apple/App/Models/Workspace.swift apple/Tests/AppTests/WorkspaceAIWriteTests.swift
git commit -m "workspace: applyAIWrite — non-undo helper for transcript/summary writes"
```

---

## Task 5: `TranscriptionCoordinator` — App-side serial pipeline

**Files:**

- Create: `apple/App/Intelligence/TranscriptionCoordinator.swift`
- Test: `apple/Tests/AppTests/TranscriptionCoordinatorTests.swift` (new)
- Modify: `apple/project.yml` (already includes the new path from Task 1; if not, add now)

- [ ] **Step 1: Write the failing happy-path test**

Create `apple/Tests/AppTests/TranscriptionCoordinatorTests.swift`:

```swift
import XCTest
import VideoCoachCore
@testable import VideoCoach

@MainActor
final class TranscriptionCoordinatorTests: XCTestCase {

    /// Build a workspace with one clip + a recordings dir + an empty stub
    /// .mov so the coordinator's `recordingURL(for:)` lookup succeeds.
    /// (Speech APIs aren't called — `FakeClipIntelligence` short-circuits.)
    private func makeFixture() throws -> (ws: Workspace, clipID: UUID, fake: FakeClipIntelligence) {
        let id = UUID()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vc-tc-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Minimal project.json so Workspace will save without errors.
        var p = Project(name: "T")
        p.clips.append(Clip(
            id: id, name: "c",
            sourceIndex: 0, startSourceSeconds: 0,
            recordingDuration: 1, recordingFilename: "c.mov",
            sortIndex: 0
        ))
        try ProjectStore.write(p, to: tmp)
        // Stub recording so recordingURL points at a real file.
        let recDir = tmp.appendingPathComponent("recordings")
        try Data("stub".utf8).write(to: recDir.appendingPathComponent("c.mov"))

        let ws = Workspace()
        ws.folder = tmp
        ws.project = p
        return (ws, id, FakeClipIntelligence())
    }

    /// Spin until predicate true or timeout — keeps each test deterministic
    /// without sprinkling fixed sleeps. Cooperative-scheduler friendly.
    private func waitUntil(timeout: TimeInterval = 2,
                           _ predicate: @autoclosure @escaping () -> Bool) async {
        let start = Date()
        while !predicate() {
            if Date().timeIntervalSince(start) > timeout { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func test_happyPath_writesBothFields_noUndoPushed() async throws {
        let (ws, id, fake) = try makeFixture()
        fake.transcriptToReturn = "t"
        fake.summaryToReturn = "s"
        let tc = TranscriptionCoordinator(workspace: ws, intelligence: fake)

        XCTAssertFalse(ws.canUndo)
        tc.enqueue(clipID: id)
        await waitUntil(tc.state(for: id) == .idle)

        XCTAssertEqual(ws.project.clips[0].transcript, "t")
        XCTAssertEqual(ws.project.clips[0].summary, "s")
        XCTAssertEqual(fake.transcribeCalls.count, 1)
        XCTAssertEqual(fake.summarizeCalls.first, "t")
        XCTAssertFalse(ws.canUndo, "AI pipeline must not push undo entries")
        XCTAssertEqual(tc.state(for: id), .idle)
    }
}
```

- [ ] **Step 2: Run the test, confirm compile FAIL (no `TranscriptionCoordinator` yet)**

```bash
cd apple && xcodebuild -project VideoCoach.xcodeproj -scheme VideoCoach -only-testing:VideoCoachTests/TranscriptionCoordinatorTests test
```

Expected: compile error — `TranscriptionCoordinator` undefined.

- [ ] **Step 3: Create the coordinator**

Create `apple/App/Intelligence/TranscriptionCoordinator.swift`:

```swift
import Foundation
import Observation
import VideoCoachCore

/// Drives the per-recording transcribe-then-summarize pipeline.
///
/// Serial: at most one job runs at a time. Two recordings stopped in
/// quick succession queue rather than race — avoids two concurrent
/// `SpeechAnalyzer` instances and two concurrent `LanguageModelSession`
/// responses.
///
/// Writes results into the workspace via `applyAIWrite`, which saves
/// but never pushes undo. See the docstring on `applyAIWrite` for why.
@MainActor
@Observable
final class TranscriptionCoordinator {
    enum Phase { case transcribing, summarizing }

    enum State: Equatable {
        case idle
        case transcribing
        case summarizing
        case failed(Error)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.transcribing, .transcribing), (.summarizing, .summarizing):
                return true
            case (.failed(let l), .failed(let r)):
                return (l as NSError) == (r as NSError)
            default:
                return false
            }
        }
    }

    private let workspace: Workspace
    private let intelligence: ClipIntelligence

    /// The single in-flight clip ID, if any.
    private(set) var inFlightClipID: Clip.ID?

    /// Which phase of the in-flight job is currently active. Only
    /// meaningful when `inFlightClipID != nil`.
    private(set) var currentPhase: Phase = .transcribing

    /// The most recent failure: which clip it belonged to, and the
    /// error. In-memory only — app relaunch starts every clip in
    /// `.idle`.
    private(set) var lastFailure: (clipID: Clip.ID, error: Error)?

    /// FIFO queue of clip IDs awaiting their turn behind `inFlightClipID`.
    private var queue: [Clip.ID] = []

    init(workspace: Workspace, intelligence: ClipIntelligence) {
        self.workspace = workspace
        self.intelligence = intelligence
    }

    /// Idempotent. If a job for this clip is already running OR already
    /// queued, returns. Otherwise enqueues. The runner advances itself.
    func enqueue(clipID: Clip.ID) {
        if inFlightClipID == clipID { return }
        if queue.contains(clipID) { return }
        queue.append(clipID)
        runNextIfIdle()
    }

    /// Derived state for the inspector to drive its UI. Reads only the
    /// three @Observable scalars — no per-clip dictionary.
    func state(for id: Clip.ID) -> State {
        if inFlightClipID == id {
            return currentPhase == .transcribing ? .transcribing : .summarizing
        }
        if let f = lastFailure, f.clipID == id { return .failed(f.error) }
        return .idle
    }

    // MARK: - Runner

    private func runNextIfIdle() {
        guard inFlightClipID == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        inFlightClipID = id
        currentPhase = .transcribing
        // Starting a job on this clip clears its prior failure (if any).
        if lastFailure?.clipID == id { lastFailure = nil }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runJob(clipID: id)
            self.inFlightClipID = nil
            self.runNextIfIdle()
        }
    }

    private func runJob(clipID: Clip.ID) async {
        guard let fname = filename(for: clipID),
              let url = workspace.recordingURL(for: fname)
        else {
            lastFailure = (clipID, MissingRecordingError())
            return
        }
        do {
            let text = try await intelligence.transcribe(audioURL: url)
            workspace.applyAIWrite(id: clipID) { $0.transcript = text }

            currentPhase = .summarizing
            let summary = try await intelligence.summarize(text)
            workspace.applyAIWrite(id: clipID) { $0.summary = summary }
        } catch {
            lastFailure = (clipID, error)
        }
    }

    private func filename(for id: Clip.ID) -> String? {
        workspace.project.clips.first(where: { $0.id == id })?.recordingFilename
    }

    struct MissingRecordingError: LocalizedError {
        var errorDescription: String? {
            "Recording file is missing or inaccessible."
        }
    }
}
```

- [ ] **Step 4: Run the happy-path test, confirm PASS**

```bash
cd apple && xcodebuild -project VideoCoach.xcodeproj -scheme VideoCoach -only-testing:VideoCoachTests/TranscriptionCoordinatorTests/test_happyPath_writesBothFields_noUndoPushed test
```

Expected: PASS.

- [ ] **Step 5: Add failure + idempotency + serial-queue tests**

Append to `TranscriptionCoordinatorTests.swift`:

```swift
func test_transcribeFailure_leavesBothFieldsEmpty_failedState() async throws {
    let (ws, id, fake) = try makeFixture()
    fake.transcribeError = NSError(domain: "X", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "boom"])
    let tc = TranscriptionCoordinator(workspace: ws, intelligence: fake)

    tc.enqueue(clipID: id)
    await waitUntil(tc.inFlightClipID == nil)

    XCTAssertEqual(ws.project.clips[0].transcript, "")
    XCTAssertEqual(ws.project.clips[0].summary, "")
    if case .failed = tc.state(for: id) { /* ok */ } else {
        XCTFail("expected .failed state, got \(tc.state(for: id))")
    }
    XCTAssertEqual(fake.summarizeCalls.count, 0,
                   "summarize must NOT run after transcribe failed")
}

func test_summarizeFailure_keepsTranscript_failedState() async throws {
    let (ws, id, fake) = try makeFixture()
    fake.transcriptToReturn = "kept"
    fake.summarizeError = NSError(domain: "X", code: 1)
    let tc = TranscriptionCoordinator(workspace: ws, intelligence: fake)

    tc.enqueue(clipID: id)
    await waitUntil(tc.inFlightClipID == nil)

    XCTAssertEqual(ws.project.clips[0].transcript, "kept",
                   "transcript must persist even if summary fails")
    XCTAssertEqual(ws.project.clips[0].summary, "")
    if case .failed = tc.state(for: id) { /* ok */ } else {
        XCTFail("expected .failed state")
    }
}

func test_doubleEnqueue_isNoop() async throws {
    let (ws, id, fake) = try makeFixture()
    fake.transcribeDelaySeconds = 0.05
    let tc = TranscriptionCoordinator(workspace: ws, intelligence: fake)

    tc.enqueue(clipID: id)
    tc.enqueue(clipID: id)
    tc.enqueue(clipID: id)
    await waitUntil(tc.state(for: id) == .idle)

    XCTAssertEqual(fake.transcribeCalls.count, 1,
                   "repeat enqueues during/after job must be no-ops")
}

func test_twoClips_runSeriallyNotConcurrently() async throws {
    let (ws, id1, fake) = try makeFixture()
    let id2 = UUID()
    ws.project.clips.append(Clip(
        id: id2, name: "c2",
        sourceIndex: 0, startSourceSeconds: 0,
        recordingDuration: 1, recordingFilename: "c2.mov",
        sortIndex: 1
    ))
    let rec = ws.folder!.appendingPathComponent("recordings")
    try Data("stub".utf8).write(to: rec.appendingPathComponent("c2.mov"))
    fake.transcribeDelaySeconds = 0.05
    fake.summarizeDelaySeconds = 0.05
    fake.assertNoOverlap = true

    let tc = TranscriptionCoordinator(workspace: ws, intelligence: fake)
    tc.enqueue(clipID: id1)
    tc.enqueue(clipID: id2)

    await waitUntil(timeout: 5, tc.inFlightClipID == nil && fake.transcribeCalls.count == 2)
    XCTAssertEqual(fake.transcribeCalls.count, 2)
    // No throw from fake.assertNoOverlap ⇒ work was serial.
}

func test_clipDeletedMidJob_helperShortCircuitsCleanly() async throws {
    let (ws, id, fake) = try makeFixture()
    fake.transcribeDelaySeconds = 0.05
    let tc = TranscriptionCoordinator(workspace: ws, intelligence: fake)

    tc.enqueue(clipID: id)
    // Remove the clip while transcribe is in flight.
    try? await Task.sleep(nanoseconds: 10_000_000)
    ws.project.clips.removeAll()

    await waitUntil(tc.inFlightClipID == nil)
    // No assertion on writes — the workspace has no matching clip, so
    // both applyAIWrite calls short-circuit. Test passes by virtue of
    // not crashing and reaching .idle.
}
```

- [ ] **Step 6: Run all TranscriptionCoordinatorTests, confirm PASS**

```bash
cd apple && xcodebuild -project VideoCoach.xcodeproj -scheme VideoCoach -only-testing:VideoCoachTests/TranscriptionCoordinatorTests test
```

Expected: all six tests PASS.

- [ ] **Step 7: Commit**

```bash
git add apple/App/Intelligence/TranscriptionCoordinator.swift apple/Tests/AppTests/TranscriptionCoordinatorTests.swift
git commit -m "app: TranscriptionCoordinator — serial AI pipeline driven by Workspace.applyAIWrite"
```

---

## Task 6: Inspector UI + ContentView wiring (build stays green)

**Files:**

- Create: `apple/App/Intelligence/AppleClipIntelligence.swift` (stub — real impl in Task 8)
- Modify: `apple/App/ContentView.swift`
- Modify: `apple/App/Views/ClipInspector.swift`

This task combines the inspector UI changes with the ContentView wiring so the build stays green at task end. The full enqueue path lands in Task 7; here we just create the coordinator and pass it through to the inspector.

- [ ] **Step 1: Create the stub `AppleClipIntelligence`**

We need a concrete `ClipIntelligence` to inject. The stub throws "not implemented" — the app builds and runs; transcription jobs land in `.failed` until Task 8.

Create `apple/App/Intelligence/AppleClipIntelligence.swift`:

```swift
import Foundation
import VideoCoachCore

/// Real implementation. Currently a stub — Task 8 fills in the Speech
/// + FoundationModels integration. Until that lands, every job lands
/// in the coordinator's `.failed` state, which is the correct behavior
/// on machines where Apple Intelligence is unavailable.
struct AppleClipIntelligence: ClipIntelligence {
    func transcribe(audioURL: URL) async throws -> String {
        throw NSError(
            domain: "AppleClipIntelligence", code: -1,
            userInfo: [NSLocalizedDescriptionKey:
                "Transcription not yet implemented (Task 8)."])
    }

    func summarize(_ transcript: String) async throws -> String {
        throw NSError(
            domain: "AppleClipIntelligence", code: -1,
            userInfo: [NSLocalizedDescriptionKey:
                "Summarization not yet implemented (Task 8)."])
    }
}
```

- [ ] **Step 2: Add the coordinator `@State` to `ContentView`**

In `apple/App/ContentView.swift`, find the line:

```swift
@State private var workspace = Workspace()
```

Add right after it:

```swift
/// AI pipeline. Initialized with a placeholder workspace because
/// `@State` initializers can't reference each other; rebound to the
/// real workspace in Task 7's `.task` step. The placeholder is never
/// driven because `enqueue` is only called from `stopRecording` (user
/// action), which happens long after `.task` has rebound.
@State private var transcription: TranscriptionCoordinator =
    TranscriptionCoordinator(
        workspace: Workspace(),
        intelligence: AppleClipIntelligence()
    )
```

- [ ] **Step 3: Pass the coordinator into `ClipInspector`**

Find the `ClipInspector(...)` invocation in `ContentView.swift` (search `ClipInspector(`). Add `coordinator: transcription,` to the argument list:

```swift
ClipInspector(
    workspace: workspace,
    coordinator: transcription,
    selectedClipID: $selectedClipID,
    selectedTagFilter: $selectedTagFilter
)
```

- [ ] **Step 4: Add the coordinator parameter to `ClipInspector` and pass it down**

In `apple/App/Views/ClipInspector.swift`, near the top of `ClipInspector`:

```swift
struct ClipInspector: View {
    @Bindable var workspace: Workspace
    let coordinator: TranscriptionCoordinator
    @Binding var selectedClipID: Clip.ID?
    @Binding var selectedTagFilter: String?
    @State private var tagOverviewSort: TagOverviewSortMode = .alpha
    // ...
}
```

And in `ClipInspector.body`, change the `EditorView(...)` instantiation to pass `coordinator`:

```swift
EditorView(
    workspace: workspace,
    coordinator: coordinator,
    clip: binding,
    suggestions: tagSuggestions
)
.id(id)
```

- [ ] **Step 5: Extend `EditorView` to take a coordinator and gain two snapshots**

Modify `apple/App/Views/ClipInspector.swift`:

Add a coordinator parameter and two new snapshot state variables. The signature change cascades to the `ClipInspector.body` call site below — handle that in the same edit. Replace the `private struct EditorView` declaration and its `@State` block:

```swift
private struct EditorView: View {
    let workspace: Workspace
    let coordinator: TranscriptionCoordinator
    @Binding var clip: Clip
    let suggestions: Set<String>

    @FocusState private var nameFocused: Bool
    @FocusState private var notesFocused: Bool
    @FocusState private var transcriptFocused: Bool
    @FocusState private var summaryFocused: Bool

    /// Per-field snapshots taken on focus-gain. Each field commits its
    /// own undo step on focus-loss. AI writes do NOT participate in this
    /// pattern (see Workspace.applyAIWrite). User edits to transcript /
    /// summary DO — same pattern as `notes`.
    @State private var nameSnapshot: Clip?
    @State private var tagsSnapshot: Clip?
    @State private var notesSnapshot: Clip?
    @State private var transcriptSnapshot: Clip?
    @State private var summarySnapshot: Clip?
```

- [ ] **Step 6: Add transcript, summary, and Transcribe button to `EditorView.body`**

Inside the `VStack` in `EditorView.body`, between the existing PiP `Group` and the Notes `Group`, insert two new `Group`s (Summary first since the spec layout puts the headline above the long-form transcript). Replace the existing single Notes `Group` with this expanded sequence:

```swift
Group {
    Text("Summary").font(.caption).foregroundStyle(.secondary)
    TextEditor(text: $clip.summary)
        .font(.body)
        .frame(minHeight: 40)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .focused($summaryFocused)
        .onChange(of: summaryFocused) { _, focused in
            handleFocusChange(focused: focused, snapshot: $summarySnapshot)
        }
}

Group {
    Text("Transcript").font(.caption).foregroundStyle(.secondary)
    TextEditor(text: $clip.transcript)
        .font(.body)
        .frame(minHeight: 120)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .focused($transcriptFocused)
        .onChange(of: transcriptFocused) { _, focused in
            handleFocusChange(focused: focused, snapshot: $transcriptSnapshot)
        }
    transcribeRow
}

Group {
    Text("Notes").font(.caption).foregroundStyle(.secondary)
    TextEditor(text: $clip.notes)
        .font(.body)
        .frame(minHeight: 120)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .focused($notesFocused)
        .onChange(of: notesFocused) { _, focused in
            handleFocusChange(focused: focused, snapshot: $notesSnapshot)
        }
}
```

Add the `transcribeRow` computed view at the bottom of `EditorView`:

```swift
@ViewBuilder
private var transcribeRow: some View {
    let state = coordinator.state(for: clip.id)
    HStack(spacing: 8) {
        Button("Transcribe") {
            coordinator.enqueue(clipID: clip.id)
        }
        .disabled(stateIsInFlight(state))

        if stateIsInFlight(state) {
            ProgressView()
                .controlSize(.small)
            Text(captionFor(state))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Spacer()
    }
    if case .failed(let err) = state {
        Text(err.localizedDescription)
            .font(.callout)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func stateIsInFlight(_ state: TranscriptionCoordinator.State) -> Bool {
    switch state {
    case .transcribing, .summarizing: return true
    default: return false
    }
}

private func captionFor(_ state: TranscriptionCoordinator.State) -> String {
    switch state {
    case .transcribing: return "Transcribing…"
    case .summarizing:  return "Summarizing…"
    default:            return ""
    }
}
```

Update the `.onDisappear` flush block to cover the two new snapshots:

```swift
.onDisappear {
    flush(&nameSnapshot)
    flush(&tagsSnapshot)
    flush(&notesSnapshot)
    flush(&transcriptSnapshot)
    flush(&summarySnapshot)
}
```

- [ ] **Step 7: Build the app and run all tests**

```bash
cd apple && xcodegen generate && cd ..
xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build
swift test --package-path apple/VideoCoachCore
cd apple && xcodebuild -project VideoCoach.xcodeproj -scheme VideoCoach -only-testing:VideoCoachTests test
```

Expected: build SUCCEEDED, all tests PASS. The Transcribe button is now visible in the inspector but produces "not implemented" inline errors when clicked — Task 8 fixes that.

- [ ] **Step 8: Commit**

```bash
git add apple/App/Intelligence/AppleClipIntelligence.swift \
        apple/App/ContentView.swift \
        apple/App/Views/ClipInspector.swift
git commit -m "ui: inspector gains transcript + summary editors + Transcribe button; coordinator wired through"
```

---

## Task 7: Rebind coordinator to real workspace + enqueue on recording finish

**Files:**

- Modify: `apple/App/ContentView.swift`

- [ ] **Step 1: Rebind `transcription` to the real workspace in `.task`**

The Task 6 `@State` initializer used a placeholder `Workspace()` because `@State` initializers can't reference each other. Now we rebind to the real `workspace` instance once SwiftUI has run init.

Find the existing top-level `.task` modifier on `ContentView`'s outermost view (search `.task {`). If multiple exist, pick the one attached to the same view as the project-open / scene-bootstrap logic (the one that runs at app startup).

Insert this line at the TOP of that task body (so the rebind happens before any other startup work that might depend on the coordinator):

```swift
transcription = TranscriptionCoordinator(
    workspace: workspace,
    intelligence: AppleClipIntelligence()
)
```

If `ContentView` has NO existing `.task` modifier, add one to the outermost view in `body`:

```swift
.task {
    transcription = TranscriptionCoordinator(
        workspace: workspace,
        intelligence: AppleClipIntelligence()
    )
}
```

- [ ] **Step 2: Enqueue transcription after `workspace.addClip`**

Find `private func stopRecording()` in `ContentView.swift` (around line 1050). Inside the `await MainActor.run { … }` block where the new clip is added, locate:

```swift
workspace.addClip(clip)
self.recordingController = nil
workspace.recordingController = nil
```

Insert one line right after `addClip`:

```swift
workspace.addClip(clip)
transcription.enqueue(clipID: clip.id)
self.recordingController = nil
workspace.recordingController = nil
```

- [ ] **Step 3: Build + tests**

```bash
cd apple && xcodegen generate && cd ..
xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build
swift test --package-path apple/VideoCoachCore
cd apple && xcodebuild -project VideoCoach.xcodeproj -scheme VideoCoach -only-testing:VideoCoachTests test
```

Expected: build SUCCEEDED, all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add apple/App/ContentView.swift
git commit -m "app: rebind transcription coordinator in .task; enqueue on recording finish"
```

---

## Task 8: `AppleClipIntelligence` real implementation

**Files:**

- Modify: `apple/App/Intelligence/AppleClipIntelligence.swift` (move from App target to Core, or keep in App)

Decision: keep `AppleClipIntelligence` in the App target rather than Core, so `VideoCoachCore` doesn't pick up an indirect dep on `Speech` + `FoundationModels` (frameworks that won't link cleanly in headless `swift test`). Core stays headless-testable; the real impl lives next to the coordinator.

**The two API points below could not be fully verified from public docs at spec-time and need eyeball confirmation against the live macOS 26 SDK headers in Xcode while writing this code.** See the spec's "Apple API surface needs eyeball confirmation" risk. If the symbols differ from what's written here, adjust and proceed — the surrounding architecture doesn't depend on the exact spelling.

- [ ] **Step 1: Replace the stub `AppleClipIntelligence` with the real implementation**

Replace the file contents:

```swift
import Foundation
import AVFoundation
import Speech
import FoundationModels
import VideoCoachCore

/// On-device transcription via macOS 26 `SpeechAnalyzer` +
/// `SpeechTranscriber`, summarization via `LanguageModelSession`. Both
/// purely local; no network, no API keys.
///
/// First-run on a fresh machine downloads the locale's speech model via
/// `AssetInventory.assetInstallationRequest(supporting:)` — that call
/// returns nil when the assets are already installed (API-level
/// idempotency, so no app-level cache).
struct AppleClipIntelligence: ClipIntelligence {

    // MARK: - Transcription

    func transcribe(audioURL: URL) async throws -> String {
        try await requestSpeechAuthorizationIfNeeded()

        let locale = Self.resolvedLocale()
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .offlineTranscription
        )

        // Install per-locale assets on first use. Idempotent: returns nil
        // when already installed.
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Audio-feeding path. AVAudioFile path is the simplest if mov audio
        // decodes — Apple's examples show `start(inputAudioFile:finishAfterFile:)`.
        // EYEBALL CONFIRM in Xcode: if .mov doesn't open as AVAudioFile,
        // switch to AVAssetReader + AsyncStream<AnalyzerInput>.
        let audioFile = try AVAudioFile(forReading: audioURL)
        try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)

        var parts: [String] = []
        for try await result in transcriber.results {
            if result.isFinal {
                parts.append(String(result.text.characters))
            }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Summarization

    func summarize(_ transcript: String) async throws -> String {
        // Availability gate. `.available` ⇒ proceed; anything else throws
        // a localized error the inspector surfaces inline.
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw SummarizationError.unavailable(reason: String(describing: reason))
        }

        let session = LanguageModelSession {
            """
            You are a coaching analyst. Summarize the following coaching
            commentary in one or two short sentences. Focus on the coach's
            main point. Do not invent details. Output plain text only.
            """
        }
        let response = try await session.respond(to: transcript)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private static func resolvedLocale() -> Locale {
        let candidate = Locale.current
        // Future-proofing: if Apple ships per-locale support checks, gate
        // here. For now we trust system locale and fall back to en-US.
        return candidate.identifier.isEmpty ? Locale(identifier: "en-US") : candidate
    }

    private func requestSpeechAuthorizationIfNeeded() async throws {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return }
        let status = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw SpeechAuthError.denied(status: status)
        }
    }

    enum SpeechAuthError: LocalizedError {
        case denied(status: SFSpeechRecognizerAuthorizationStatus)
        var errorDescription: String? {
            "Speech recognition not authorized. Enable it in System Settings → Privacy & Security → Speech Recognition."
        }
    }

    enum SummarizationError: LocalizedError {
        case unavailable(reason: String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let reason):
                return "On-device language model unavailable: \(reason)."
            }
        }
    }
}
```

- [ ] **Step 2: Build the app**

```bash
cd apple && xcodegen generate && cd ..
xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build 2>&1 | tail -60
```

Expected: build SUCCEEDED. If any of the Apple symbols differ (e.g. `SpeechTranscriber.Preset.offlineTranscription` is named differently, or `LanguageModelSession`'s `respond(to:)` returns a different shape), the compiler will pinpoint each call site. Adjust the symbol per the SDK headers and re-build. Do NOT speculate — read the header errors and match.

- [ ] **Step 3: Run all tests one more time**

```bash
swift test --package-path apple/VideoCoachCore
cd apple && xcodebuild -project VideoCoach.xcodeproj -scheme VideoCoach -only-testing:VideoCoachTests test
```

Expected: all PASS. (No new unit tests for `AppleClipIntelligence` — its dependencies require a real ML stack and live audio, so it's covered by the manual smoke test in Task 9.)

- [ ] **Step 4: Commit**

```bash
git add apple/App/Intelligence/AppleClipIntelligence.swift
git commit -m "app: AppleClipIntelligence — real SpeechAnalyzer + LanguageModelSession impl"
```

---

## Task 9: Manual smoke test + final commit

**Files:** none (manual validation only)

- [ ] **Step 1: Launch the app + open a project**

```bash
xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -configuration Debug -derivedDataPath /tmp/vc-build build
open /tmp/vc-build/Build/Products/Debug/VideoCoach.app
```

Open or create a project folder. Add a source video.

- [ ] **Step 2: Smoke step — new recording auto-transcribes**

Record a short (5–10 second) clip narrating something simple ("This is a test of the transcription feature."). Confirm:

1. Sidebar shows the clip immediately after stop.
2. Inspector's transcript area shows "Transcribing…" caption + spinner next to the Transcribe button.
3. Caption switches to "Summarizing…" once transcript text appears.
4. After a few more seconds, summary text appears above the transcript.
5. On a fresh machine, the first run shows "Downloading speech model…" — wait for it; this is documented first-run UX.

- [ ] **Step 3: Smoke step — manual editing of AI fields**

Click into the Summary or Transcript field. Edit the text. Click out (focus-loss). Press `cmd-z`. Confirm: the edit is reverted, leaving the AI-written text intact.

Then click into Notes. Type something. Click out. Press `cmd-z`. Confirm: only the notes edit is reverted; transcript and summary are unchanged (because AI writes are not in the undo stack).

- [ ] **Step 4: Smoke step — persistence across launch**

Quit and re-open the app + project. Confirm both fields are still populated on the clip.

- [ ] **Step 5: Smoke step — manual re-run via Transcribe button**

Select the clip. Click Transcribe. Confirm: the button disables; "Transcribing…" then "Summarizing…" captions; both fields refresh with fresh AI output (likely the same since input audio hasn't changed).

- [ ] **Step 6: Smoke step — failure path (optional but recommended)**

Temporarily revoke Speech Recognition in System Settings → Privacy & Security → Speech Recognition for VideoCoach. Click Transcribe again. Confirm: inline red error text appears under the Transcribe button with the localized message.

Restore the permission afterwards.

- [ ] **Step 7: Commit any final fix-ups discovered during smoke**

If the smoke test surfaced anything (UI gaps, error wording, layout), fix inline and commit. Otherwise tag the PR ready for review.

```bash
git status   # confirm clean
```

---

## Out of scope (for backlog)

- Live partial-transcript streaming into the inspector while recording.
- Searching clips by transcript content.
- Translating non-English transcripts.
- Background asset pre-download on app launch.
- Cancelling an in-flight job when a clip is deleted (the `firstIndex(where:)` short-circuit on write is enough).
