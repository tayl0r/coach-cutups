# Clip Transcript + Summary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-transcribe every new recording's mic audio via macOS 26 `SpeechAnalyzer`, summarize via `FoundationModels`, and store both on `Clip` as user-editable fields. Manual "Transcribe" button in the inspector for backfill / re-run.

**Architecture:** A `ClipIntelligence` protocol in `VideoCoachCore` with a concrete `AppleClipIntelligence` (App target — imports Speech/FoundationModels) and a `FakeClipIntelligence` (Core test helpers). The pipeline orchestrator (`TranscriptionCoordinator`) and the `applyAIWrite` mutation helper both live in `VideoCoachCore` — they're pure logic and headless-testable via `swift test`. Coordinator depends on `Workspace` only through a small `TranscriptionWorkspace` protocol; the real `Workspace` conforms in the App target. The inspector grows transcript + summary `TextEditor`s with their own focus snapshots, identical to how `notes` works today.

**Tech Stack:** Swift 5.9, SwiftUI, AVFoundation, `Speech` (macOS 26 `SpeechAnalyzer` / `SpeechTranscriber`), `FoundationModels` (macOS 26 on-device LLM), `VideoCoachCore` Swift Package, XCTest, `xcodebuild`, `xcodegen`.

**Spec:** `docs/superpowers/specs/2026-05-21-clip-transcript-and-summary-design.md`.

**Working branch:** create `clip-ai-transcript` at execution time via the `superpowers:using-git-worktrees` skill.

**Preconditions:**
- Xcode + SDK with macOS 26 support installed.
- Swift toolchain that recognizes `.macOS(.v26)` in `Package.swift` (verified at Task 1).

**Canonical test commands:**

- Core package: `swift test --package-path apple/VideoCoachCore`
- App unit tests: `cd apple && xcodebuild -project VideoCoach.xcodeproj -scheme VideoCoach -only-testing:VideoCoachTests test`
- App full build: `cd apple && xcodegen generate && cd .. && xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build`

---

## Task 1: Bump deployment target + Info.plist + verify toolchain

**Files:**

- Modify: `apple/project.yml`
- Modify: `apple/VideoCoachCore/Package.swift`

- [ ] **Step 1: Verify the local toolchain has macOS 26 SDK**

```bash
xcodebuild -showsdks | grep -i macos
```

Expected: a `macOS 26.x` entry. If only `macos15.x` / earlier appears, STOP — install a newer Xcode before proceeding. The plan's `.macOS(.v26)` and `MACOSX_DEPLOYMENT_TARGET = 26.0` will fail to compile otherwise.

- [ ] **Step 2: Bump deployment target in `apple/project.yml`**

In every `MACOSX_DEPLOYMENT_TARGET: "14.0"` line, replace `"14.0"` with `"26.0"`. Also update `LSMinimumSystemVersion: "14.0"` to `"26.0"`, and the top-level `deploymentTarget.macOS: "14.0"` to `"26.0"`.

Add `NSSpeechRecognitionUsageDescription` to the `info.properties` block for the `VideoCoach` app target:

```yaml
NSSpeechRecognitionUsageDescription: Video Coach transcribes your recorded commentary on-device so you can review and search what you said.
```

**Do not** add anything to the `VideoCoachTests.sources` list in this task. The new App-side source files (Workspace conformance, AppleClipIntelligence) will be added when they're created in Task 6. The coordinator + helper live in `VideoCoachCore` and are tested via `swift test`, not via the app test target.

- [ ] **Step 3: Bump `Package.swift`**

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

- [ ] **Step 4: Regenerate the Xcode project and verify everything still builds + tests pass**

```bash
cd apple && xcodegen generate && cd ..
xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build
swift test --package-path apple/VideoCoachCore
```

Expected: build SUCCEEDED. All existing Core tests PASS. No source files have changed yet — only project config — so any error here is a config issue.

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
```

- [ ] **Step 2: Update the existing `formatVersion` assertions**

In `ProjectTests.swift`, change every `XCTAssertEqual(decoded.formatVersion, 4)` / `XCTAssertEqual(p.formatVersion, 4)` to `5`. Same for `test_projectStore_writeBumpsFormatVersionToCurrent` (`XCTAssertEqual(reread.formatVersion, 4, ...)` → `5`).

- [ ] **Step 3: Run the new tests, confirm FAIL**

```bash
swift test --package-path apple/VideoCoachCore --filter "ProjectTests.test_v4ClipMissingTranscriptAndSummary_decodesToEmptyStrings" --filter "ProjectTests.test_transcriptAndSummaryRoundtripThroughJSON"
```

Expected: both FAIL — `transcript`/`summary` don't exist.

- [ ] **Step 4: Add the new fields + custom `init(from:)` + bump `currentFormatVersion`**

In `apple/VideoCoachCore/Sources/VideoCoachCore/Project.swift`, modify `Clip` IN ITS PRIMARY DECLARATION (not via extension). This mirrors `Project.init(from:)`'s placement in the same file. Replace the `struct Clip` block with:

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

    // Custom decoder so existing v4 JSON (which lacks `transcript` /
    // `summary`) loads cleanly with both fields defaulting to "".
    // Swift's synthesised `Decodable` does NOT honour stored-property
    // defaults for missing keys — it always calls `decode`. So we
    // intercept reads here. Encoding stays synthesised via `Encodable`.
    // Matches the pattern `Project.init(from:)` already uses below.
    private enum CodingKeys: String, CodingKey {
        case id, name, notes, tags, sourceIndex, startSourceSeconds,
             recordingDuration, recordingFilename, events, showPiP,
             sortIndex, createdAt, transcript, summary
    }

    public init(from decoder: Decoder) throws {
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

- [ ] **Step 5: Verify `test_unsupportedFutureFormatVersion_isRejected` still passes**

That test reads `Project.currentFormatVersion + 1` and so is self-updating — no code change needed.

- [ ] **Step 6: Run Core tests, confirm all PASS**

```bash
swift test --package-path apple/VideoCoachCore
```

Expected: all PASS, including the two new tests and every previously-existing test.

- [ ] **Step 7: Commit**

```bash
git add apple/VideoCoachCore
git commit -m "model: v5 — add Clip.transcript + .summary with v4 decode migration"
```

---

## Task 3: `ClipIntelligence` protocol + `FakeClipIntelligence` (Core)

**Files:**

- Create: `apple/VideoCoachCore/Sources/VideoCoachCore/Intelligence/ClipIntelligence.swift`
- Create: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/Helpers/FakeClipIntelligence.swift`

- [ ] **Step 1: Create the protocol**

Create `apple/VideoCoachCore/Sources/VideoCoachCore/Intelligence/ClipIntelligence.swift`:

```swift
import Foundation

/// Pure-logic seam for the on-device transcription + summarization
/// pipeline. The real implementation (`AppleClipIntelligence`) lives
/// in the App target because it imports `Speech` and `FoundationModels`
/// (frameworks that don't link in headless `swift test`). The test fake
/// in this package returns canned strings so coordinator tests are
/// deterministic and run headlessly.
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

- [ ] **Step 2: Create the test fake (lean version — no overlap-detection machinery)**

Create `apple/VideoCoachCore/Tests/VideoCoachCoreTests/Helpers/FakeClipIntelligence.swift`:

```swift
import Foundation
@testable import VideoCoachCore

/// Test fake. Returns whatever was configured. Records every call.
/// Supports per-call delay so tests can observe in-flight state.
final class FakeClipIntelligence: ClipIntelligence, @unchecked Sendable {
    var transcriptToReturn: String = "fake transcript"
    var summaryToReturn: String = "fake summary."
    var transcribeError: Error?
    var summarizeError: Error?
    var transcribeDelaySeconds: Double = 0
    var summarizeDelaySeconds: Double = 0

    private let lock = NSLock()
    private var _transcribeCalls: [URL] = []
    private var _summarizeCalls: [String] = []

    var transcribeCalls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return _transcribeCalls
    }
    var summarizeCalls: [String] {
        lock.lock(); defer { lock.unlock() }
        return _summarizeCalls
    }

    func transcribe(audioURL: URL) async throws -> String {
        lock.lock(); _transcribeCalls.append(audioURL); lock.unlock()
        if transcribeDelaySeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(transcribeDelaySeconds * 1_000_000_000))
        }
        if let e = transcribeError { throw e }
        return transcriptToReturn
    }

    func summarize(_ transcript: String) async throws -> String {
        lock.lock(); _summarizeCalls.append(transcript); lock.unlock()
        if summarizeDelaySeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(summarizeDelaySeconds * 1_000_000_000))
        }
        if let e = summarizeError { throw e }
        return summaryToReturn
    }
}
```

No standalone tests for the fake — it's exercised end-to-end by `TranscriptionCoordinatorTests` (Task 5). A bug in the fake would surface as a coordinator-test failure.

- [ ] **Step 3: Run Core tests, confirm PASS**

```bash
swift test --package-path apple/VideoCoachCore
```

Expected: all PASS (no new tests yet — just confirms the new files compile and don't break anything).

- [ ] **Step 4: Commit**

```bash
git add apple/VideoCoachCore
git commit -m "core: ClipIntelligence protocol + FakeClipIntelligence test seam"
```

---

## Task 4: `Project.applyAIWrite` helper in Core

**Files:**

- Create: `apple/VideoCoachCore/Sources/VideoCoachCore/Intelligence/ProjectAIWrite.swift`
- Test: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ProjectAIWriteTests.swift`

This helper lives on `Project` (the pure data model) so Core can test it headlessly. The App-side `Workspace` will gain a one-line wrapper in Task 6 that calls this helper then `saveProject()`.

- [ ] **Step 1: Write the failing test**

Create `apple/VideoCoachCore/Tests/VideoCoachCoreTests/ProjectAIWriteTests.swift`:

```swift
import XCTest
@testable import VideoCoachCore

final class ProjectAIWriteTests: XCTestCase {
    private func makeProject(withClipID id: UUID) -> Project {
        var p = Project(name: "T")
        p.clips.append(Clip(
            id: id, name: "c",
            sourceIndex: 0, startSourceSeconds: 0,
            recordingDuration: 1, recordingFilename: "c.mov",
            sortIndex: 0
        ))
        return p
    }

    func test_applyAIWrite_mutatesClipAndPreservesOtherFields() {
        let id = UUID()
        var p = makeProject(withClipID: id)
        p.clips[0].notes = "user-written"

        p.applyAIWrite(id: id) { $0.transcript = "hello world" }

        XCTAssertEqual(p.clips[0].transcript, "hello world")
        XCTAssertEqual(p.clips[0].notes, "user-written",
                       "notes must not be touched by an AI write")
    }

    func test_applyAIWrite_shortCircuitsOnMissingClipID() {
        var p = makeProject(withClipID: UUID())
        p.applyAIWrite(id: UUID()) { $0.transcript = "X" }
        XCTAssertEqual(p.clips[0].transcript, "",
                       "missing clip ID must be a no-op, not a crash")
    }
}
```

- [ ] **Step 2: Run, confirm FAIL**

```bash
swift test --package-path apple/VideoCoachCore --filter "ProjectAIWriteTests"
```

Expected: compile error — `applyAIWrite` doesn't exist.

- [ ] **Step 3: Add the helper**

Create `apple/VideoCoachCore/Sources/VideoCoachCore/Intelligence/ProjectAIWrite.swift`:

```swift
import Foundation

public extension Project {
    /// Apply an AI-generated mutation to a single clip in place.
    /// No-op if the clip ID isn't found (deleted between enqueue and write).
    /// Pure data — Workspace's matching wrapper handles persistence;
    /// neither this nor the wrapper push undo. See the spec's
    /// "Persistence + undo" section for the rationale.
    mutating func applyAIWrite(id: Clip.ID, _ mutate: (inout Clip) -> Void) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        mutate(&clips[i])
    }
}
```

- [ ] **Step 4: Run, confirm PASS**

```bash
swift test --package-path apple/VideoCoachCore --filter "ProjectAIWriteTests"
```

Expected: both tests PASS.

- [ ] **Step 5: Commit**

```bash
git add apple/VideoCoachCore
git commit -m "core: Project.applyAIWrite — AI-mutation helper, no-op on missing clip"
```

---

## Task 5: `TranscriptionWorkspace` protocol + `TranscriptionCoordinator` (Core)

**Files:**

- Create: `apple/VideoCoachCore/Sources/VideoCoachCore/Intelligence/TranscriptionWorkspace.swift`
- Create: `apple/VideoCoachCore/Sources/VideoCoachCore/Intelligence/TranscriptionCoordinator.swift`
- Create: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/Helpers/FakeTranscriptionWorkspace.swift`
- Create: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/TranscriptionCoordinatorTests.swift`

Coordinator lives in Core so it's testable headlessly. It depends on `Workspace` only through a tiny protocol; the real `Workspace` conforms in the App target (Task 6).

- [ ] **Step 1: Create the protocol**

Create `apple/VideoCoachCore/Sources/VideoCoachCore/Intelligence/TranscriptionWorkspace.swift`:

```swift
import Foundation

/// Narrow seam between `TranscriptionCoordinator` and the App-side
/// `Workspace`. Two methods is everything the coordinator needs:
/// the URL to read audio from, and how to apply the AI-generated
/// mutation. The real `Workspace` conforms in the App target;
/// `FakeTranscriptionWorkspace` (tests) holds an in-memory `Project`.
@MainActor
public protocol TranscriptionWorkspace: AnyObject {
    /// Absolute file URL of the recording for `clipID`. Returns nil if
    /// the clip is not in the project, or if no project is open.
    func recordingURL(forClip clipID: Clip.ID) -> URL?

    /// Apply an AI-generated mutation to a clip and persist. No-op if
    /// the clip is gone. MUST NOT push an undo entry.
    func applyAIWrite(id: Clip.ID, _ mutate: (inout Clip) -> Void)
}
```

- [ ] **Step 2: Create the file-scope state enum**

Create `apple/VideoCoachCore/Sources/VideoCoachCore/Intelligence/TranscriptionCoordinator.swift` (we'll fill in the coordinator class below). For now:

```swift
import Foundation
import Observation

/// Phase-of-job + result state for a single clip's transcription
/// pipeline. File-scope (not nested in `TranscriptionCoordinator`) so
/// `Equatable`'s nonisolated `==` requirement isn't in conflict with
/// the coordinator's `@MainActor` isolation. Payload on `.failed` is a
/// localized message string, not an `Error` — equality is then trivial
/// and the inspector only ever renders the string anyway.
public enum TranscriptionState: Equatable, Sendable {
    case idle
    case transcribing
    case summarizing
    case failed(String)
}
```

- [ ] **Step 3: Write the failing happy-path test**

Create `apple/VideoCoachCore/Tests/VideoCoachCoreTests/Helpers/FakeTranscriptionWorkspace.swift`:

```swift
import Foundation
@testable import VideoCoachCore

/// Test fake for `TranscriptionWorkspace`. Holds a `Project` and a
/// recordings-dir URL; `applyAIWrite` mutates the project in place.
@MainActor
final class FakeTranscriptionWorkspace: TranscriptionWorkspace {
    var project: Project
    var recordingsDir: URL

    init(project: Project, recordingsDir: URL) {
        self.project = project
        self.recordingsDir = recordingsDir
    }

    func recordingURL(forClip clipID: Clip.ID) -> URL? {
        guard let clip = project.clips.first(where: { $0.id == clipID })
        else { return nil }
        return recordingsDir.appendingPathComponent(clip.recordingFilename)
    }

    func applyAIWrite(id: Clip.ID, _ mutate: (inout Clip) -> Void) {
        project.applyAIWrite(id: id, mutate)
    }
}
```

Create `apple/VideoCoachCore/Tests/VideoCoachCoreTests/TranscriptionCoordinatorTests.swift`:

```swift
import XCTest
@testable import VideoCoachCore

@MainActor
final class TranscriptionCoordinatorTests: XCTestCase {

    private func makeFixture() throws -> (ws: FakeTranscriptionWorkspace,
                                          clipID: UUID,
                                          fake: FakeClipIntelligence) {
        let id = UUID()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tc-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Stub recording file so resolved URL points at a real path.
        try Data("stub".utf8).write(to: tmp.appendingPathComponent("c.mov"))

        var p = Project(name: "T")
        p.clips.append(Clip(
            id: id, name: "c",
            sourceIndex: 0, startSourceSeconds: 0,
            recordingDuration: 1, recordingFilename: "c.mov",
            sortIndex: 0
        ))
        let ws = FakeTranscriptionWorkspace(project: p, recordingsDir: tmp)
        return (ws, id, FakeClipIntelligence())
    }

    /// Spin until predicate true or timeout. Calls XCTFail on timeout
    /// (NOT a silent return) so a misbehaving coordinator surfaces a
    /// proper test failure rather than fall-through assertion errors.
    private func waitUntil(timeout: TimeInterval = 2,
                           file: StaticString = #filePath,
                           line: UInt = #line,
                           _ predicate: @autoclosure @escaping () -> Bool) async {
        let start = Date()
        while !predicate() {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("waitUntil timed out after \(timeout)s",
                        file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func test_happyPath_writesBothFields() async throws {
        let (ws, id, fake) = try makeFixture()
        fake.transcriptToReturn = "t"
        fake.summaryToReturn = "s"
        let tc = TranscriptionCoordinator(workspace: ws, intelligence: fake)

        tc.enqueue(clipID: id)
        await waitUntil(tc.state(for: id) == .idle)

        XCTAssertEqual(ws.project.clips[0].transcript, "t")
        XCTAssertEqual(ws.project.clips[0].summary, "s")
        XCTAssertEqual(fake.transcribeCalls.count, 1)
        XCTAssertEqual(fake.summarizeCalls.first, "t")
        XCTAssertEqual(tc.state(for: id), .idle)
    }
}
```

- [ ] **Step 4: Run, confirm compile FAIL**

```bash
swift test --package-path apple/VideoCoachCore --filter "TranscriptionCoordinatorTests"
```

Expected: compile error — `TranscriptionCoordinator` undefined.

- [ ] **Step 5: Implement the coordinator**

Replace the contents of `apple/VideoCoachCore/Sources/VideoCoachCore/Intelligence/TranscriptionCoordinator.swift`:

```swift
import Foundation
import Observation

/// Phase-of-job + result state for a single clip's transcription
/// pipeline. File-scope (not nested in `TranscriptionCoordinator`) so
/// `Equatable`'s nonisolated `==` requirement isn't in conflict with
/// the coordinator's `@MainActor` isolation. Payload on `.failed` is a
/// localized message string, not an `Error` — equality is then trivial
/// and the inspector only ever renders the string anyway.
public enum TranscriptionState: Equatable, Sendable {
    case idle
    case transcribing
    case summarizing
    case failed(String)
}

/// Drives the per-recording transcribe-then-summarize pipeline.
///
/// Serial: at most one job runs at a time. Two recordings stopped in
/// quick succession queue rather than race — avoids two concurrent
/// `SpeechAnalyzer` instances and two concurrent `LanguageModelSession`
/// responses.
///
/// Writes results into the workspace via `applyAIWrite`, which saves
/// but never pushes undo. See the spec's "Persistence + undo" section.
@MainActor
@Observable
public final class TranscriptionCoordinator {

    enum Phase { case transcribing, summarizing }

    private let workspace: TranscriptionWorkspace
    private let intelligence: ClipIntelligence

    /// The single in-flight clip ID, if any.
    public private(set) var inFlightClipID: Clip.ID?

    /// Which phase of the in-flight job is currently active. Only
    /// meaningful when `inFlightClipID != nil`.
    private(set) var currentPhase: Phase = .transcribing

    /// The most recent failure: which clip it belonged to, and a
    /// localized message. In-memory only — relaunching the app starts
    /// every clip in `.idle`.
    public private(set) var lastFailure: (clipID: Clip.ID, message: String)?

    /// FIFO queue of clip IDs awaiting their turn behind `inFlightClipID`.
    private var queue: [Clip.ID] = []

    public init(workspace: TranscriptionWorkspace, intelligence: ClipIntelligence) {
        self.workspace = workspace
        self.intelligence = intelligence
    }

    /// Idempotent. If a job for this clip is already running OR already
    /// queued, returns. Otherwise enqueues. The runner advances itself.
    public func enqueue(clipID: Clip.ID) {
        if inFlightClipID == clipID { return }
        if queue.contains(clipID) { return }
        queue.append(clipID)
        runNextIfIdle()
    }

    /// Derived state for the inspector to drive its UI. Reads only the
    /// three @Observable scalars — no per-clip dictionary.
    public func state(for id: Clip.ID) -> TranscriptionState {
        if inFlightClipID == id {
            return currentPhase == .transcribing ? .transcribing : .summarizing
        }
        if let f = lastFailure, f.clipID == id { return .failed(f.message) }
        return .idle
    }

    // MARK: - Runner

    private func runNextIfIdle() {
        guard inFlightClipID == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        inFlightClipID = id
        currentPhase = .transcribing
        // Starting a job on this clip clears its prior failure.
        if lastFailure?.clipID == id { lastFailure = nil }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runJob(clipID: id)
            self.inFlightClipID = nil
            self.runNextIfIdle()
        }
    }

    private func runJob(clipID: Clip.ID) async {
        guard let url = workspace.recordingURL(forClip: clipID) else {
            lastFailure = (clipID, "Recording file is missing or inaccessible.")
            return
        }
        do {
            let text = try await intelligence.transcribe(audioURL: url)
            workspace.applyAIWrite(id: clipID) { $0.transcript = text }

            currentPhase = .summarizing
            let summary = try await intelligence.summarize(text)
            workspace.applyAIWrite(id: clipID) { $0.summary = summary }
        } catch {
            // Log the structured error for debugging; surface the
            // localized message to the UI.
            NSLog("[Transcription] failed for clip \(clipID): \(error)")
            lastFailure = (clipID, error.localizedDescription)
        }
    }
}
```

- [ ] **Step 6: Run the happy-path test, confirm PASS**

```bash
swift test --package-path apple/VideoCoachCore --filter "TranscriptionCoordinatorTests.test_happyPath_writesBothFields"
```

Expected: PASS.

- [ ] **Step 7: Add the remaining coordinator tests**

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
    XCTAssertEqual(tc.state(for: id), .failed("boom"))
    XCTAssertEqual(fake.summarizeCalls.count, 0,
                   "summarize must NOT run after transcribe failed")
}

func test_summarizeFailure_keepsTranscript_failedState() async throws {
    let (ws, id, fake) = try makeFixture()
    fake.transcriptToReturn = "kept"
    fake.summarizeError = NSError(domain: "X", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "blammo"])
    let tc = TranscriptionCoordinator(workspace: ws, intelligence: fake)

    tc.enqueue(clipID: id)
    await waitUntil(tc.inFlightClipID == nil)

    XCTAssertEqual(ws.project.clips[0].transcript, "kept",
                   "transcript must persist even if summary fails")
    XCTAssertEqual(ws.project.clips[0].summary, "")
    XCTAssertEqual(tc.state(for: id), .failed("blammo"))
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

func test_twoClips_runSeriallyInEnqueueOrder() async throws {
    let (ws, id1, fake) = try makeFixture()
    let id2 = UUID()
    ws.project.clips.append(Clip(
        id: id2, name: "c2",
        sourceIndex: 0, startSourceSeconds: 0,
        recordingDuration: 1, recordingFilename: "c2.mov",
        sortIndex: 1
    ))
    try Data("stub".utf8).write(
        to: ws.recordingsDir.appendingPathComponent("c2.mov"))
    fake.transcribeDelaySeconds = 0.02

    let tc = TranscriptionCoordinator(workspace: ws, intelligence: fake)
    tc.enqueue(clipID: id1)
    tc.enqueue(clipID: id2)

    await waitUntil(timeout: 5,
                    fake.transcribeCalls.count == 2 && tc.inFlightClipID == nil)
    // Seriality is proven by call ordering: the coordinator's single
    // `inFlightClipID` guarantees at-most-one job, so the two recorded
    // calls must be in enqueue order.
    XCTAssertEqual(fake.transcribeCalls.map(\.lastPathComponent),
                   ["c.mov", "c2.mov"])
    XCTAssertEqual(fake.summarizeCalls.count, 2)
}

func test_clipDeletedMidJob_drainsToIdle() async throws {
    let (ws, id, fake) = try makeFixture()
    fake.transcribeDelaySeconds = 0.05
    let tc = TranscriptionCoordinator(workspace: ws, intelligence: fake)

    tc.enqueue(clipID: id)
    try? await Task.sleep(nanoseconds: 10_000_000)
    ws.project.clips.removeAll()

    await waitUntil(tc.inFlightClipID == nil)
    XCTAssertTrue(ws.project.clips.isEmpty)
    XCTAssertNil(tc.inFlightClipID,
                 "coordinator must drain the job even when target clip vanishes")
}
```

- [ ] **Step 8: Run all coordinator tests, confirm PASS**

```bash
swift test --package-path apple/VideoCoachCore --filter "TranscriptionCoordinatorTests"
```

Expected: all six tests PASS.

- [ ] **Step 9: Commit**

```bash
git add apple/VideoCoachCore
git commit -m "core: TranscriptionCoordinator — serial AI pipeline behind TranscriptionWorkspace seam"
```

---

## Task 6: App-side wiring — Workspace conformance, app ownership, inspector UI, stub AppleClipIntelligence

**Files:**

- Create: `apple/App/Intelligence/AppleClipIntelligence.swift` (stub — Task 8 fills in)
- Create: `apple/App/Intelligence/Workspace+TranscriptionWorkspace.swift`
- Modify: `apple/App/Models/Workspace.swift` (add one-line `applyAIWrite` wrapper)
- Modify: `apple/App/VideoCoachApp.swift` (own workspace + coordinator)
- Modify: `apple/App/ContentView.swift` (accept injected workspace + coordinator)
- Modify: `apple/App/Views/ClipInspector.swift` (transcript + summary editors + Transcribe button)

- [ ] **Step 1: Stub `AppleClipIntelligence` so the app builds**

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

- [ ] **Step 2: Make `Workspace` conform to `TranscriptionWorkspace`**

Create `apple/App/Intelligence/Workspace+TranscriptionWorkspace.swift`:

```swift
import Foundation
import VideoCoachCore

extension Workspace: TranscriptionWorkspace {
    func recordingURL(forClip clipID: Clip.ID) -> URL? {
        guard let filename = project.clips
            .first(where: { $0.id == clipID })?.recordingFilename
        else { return nil }
        return recordingURL(for: filename)
    }
}
```

- [ ] **Step 3: Add the `applyAIWrite` wrapper to `Workspace`**

In `apple/App/Models/Workspace.swift`, add this near `addClip` (search `func addClip`):

```swift
// MARK: - AI-driven writes (transcript / summary)

/// Apply an AI-generated mutation to a clip and persist. Calls the
/// pure-data `Project.applyAIWrite` then `saveProject()`. Does NOT
/// push an undo entry — AI writes are not user actions and don't
/// participate in the undo stack.
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
    project.applyAIWrite(id: id, mutate)
    try? saveProject()
}
```

- [ ] **Step 4: Move workspace + coordinator ownership to `VideoCoachApp`**

Replace the contents of `apple/App/VideoCoachApp.swift`:

```swift
import SwiftUI
import VideoCoachCore

@main
struct VideoCoachApp: App {
    /// Owns the live device list + the menu's selection state. Created here
    /// so the same instance is shared between the menu (via `.commands`) and
    /// `ContentView`.
    @State private var deviceCatalog: DeviceCatalog

    /// Project + recording state. Owned at the App level so the
    /// transcription coordinator can be constructed with a reference to
    /// it AT INIT TIME (no placeholder + rebind pattern).
    @State private var workspace: Workspace

    /// AI transcription pipeline. Built once at app launch with the
    /// real `AppleClipIntelligence`; bound to the workspace owned above.
    @State private var transcription: TranscriptionCoordinator

    init() {
        let catalog = DeviceCatalog()
        let ws = Workspace()
        let tc = TranscriptionCoordinator(
            workspace: ws,
            intelligence: AppleClipIntelligence()
        )
        _deviceCatalog = State(initialValue: catalog)
        _workspace     = State(initialValue: ws)
        _transcription = State(initialValue: tc)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                deviceCatalog: deviceCatalog,
                workspace: workspace,
                transcription: transcription
            )
            .frame(minWidth: 1100, minHeight: 700)
        }
        .commands {
            DevicesCommands(catalog: deviceCatalog)
            ClipCommands()
            ProjectCommands()
            DebugMenu()
        }

        Window("MPV Bring-up", id: "mpv-debug") {
            MPVDebugWindow()
        }
    }
}

struct DebugMenu: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Debug") {
            Button("Open MPV Bring-up Window") {
                openWindow(id: "mpv-debug")
            }
        }
    }
}
```

- [ ] **Step 5: Update `ContentView` to accept injected workspace + coordinator**

In `apple/App/ContentView.swift`, change the top of the struct. Find:

```swift
@State private var workspace = Workspace()
```

Replace with:

```swift
@Bindable var workspace: Workspace
let transcription: TranscriptionCoordinator
```

Add `transcription:` as a new parameter to ContentView (the @Bindable workspace replaces the @State one).

- [ ] **Step 6: Pass `transcription` into `ClipInspector`**

Find the `ClipInspector(...)` invocation in `ContentView.swift`. Add `coordinator: transcription,`:

```swift
ClipInspector(
    workspace: workspace,
    coordinator: transcription,
    selectedClipID: $selectedClipID,
    selectedTagFilter: $selectedTagFilter
)
```

- [ ] **Step 7: Extend `ClipInspector` + `EditorView` for transcript + summary**

In `apple/App/Views/ClipInspector.swift`:

1. Top of `ClipInspector`:

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

2. In `ClipInspector.body`, where `EditorView` is created:

```swift
EditorView(
    workspace: workspace,
    coordinator: coordinator,
    clip: binding,
    suggestions: tagSuggestions
)
.id(id)
```

3. Top of `private struct EditorView`:

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

    @State private var nameSnapshot: Clip?
    @State private var tagsSnapshot: Clip?
    @State private var notesSnapshot: Clip?
    @State private var transcriptSnapshot: Clip?
    @State private var summarySnapshot: Clip?
```

4. In `EditorView.body`, replace the existing single `Group { Text("Notes")…}` block with this sequence (Summary first, then Transcript with the Transcribe button, then Notes):

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

5. Add the `transcribeRow` computed view + helpers at the bottom of `EditorView`:

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
    if case .failed(let msg) = state {
        Text(msg)
            .font(.callout)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func stateIsInFlight(_ state: TranscriptionState) -> Bool {
    switch state {
    case .transcribing, .summarizing: return true
    default: return false
    }
}

private func captionFor(_ state: TranscriptionState) -> String {
    switch state {
    case .transcribing: return "Transcribing…"
    case .summarizing:  return "Summarizing…"
    default:            return ""
    }
}
```

6. Update the `.onDisappear` flush block:

```swift
.onDisappear {
    flush(&nameSnapshot)
    flush(&tagsSnapshot)
    flush(&notesSnapshot)
    flush(&transcriptSnapshot)
    flush(&summarySnapshot)
}
```

- [ ] **Step 8: Build + run all tests**

```bash
cd apple && xcodegen generate && cd ..
xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build
swift test --package-path apple/VideoCoachCore
cd apple && xcodebuild -project VideoCoach.xcodeproj -scheme VideoCoach -only-testing:VideoCoachTests test
```

Expected: build SUCCEEDED, all tests PASS. The Transcribe button is now visible in the inspector but produces "not implemented" inline errors when clicked — Task 8 fixes that.

- [ ] **Step 9: Commit**

```bash
git add apple/App/Intelligence/ \
        apple/App/Models/Workspace.swift \
        apple/App/VideoCoachApp.swift \
        apple/App/ContentView.swift \
        apple/App/Views/ClipInspector.swift
git commit -m "app: workspace+coordinator wired through VideoCoachApp; inspector gets transcript/summary editors"
```

---

## Task 7: Enqueue transcription on recording finish

**Files:**

- Modify: `apple/App/ContentView.swift`

- [ ] **Step 1: Insert the enqueue call**

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

- [ ] **Step 2: Build + tests**

```bash
xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build
swift test --package-path apple/VideoCoachCore
cd apple && xcodebuild -project VideoCoach.xcodeproj -scheme VideoCoach -only-testing:VideoCoachTests test
```

Expected: build SUCCEEDED, all tests PASS.

- [ ] **Step 3: Commit**

```bash
git add apple/App/ContentView.swift
git commit -m "app: enqueue transcription on recording finish"
```

---

## Task 8: `AppleClipIntelligence` real implementation

**Files:**

- Modify: `apple/App/Intelligence/AppleClipIntelligence.swift`

**The Apple API points below could not be fully verified from public docs at spec-time.** If the symbols differ from what's written here, read Xcode's compiler errors and adjust — the surrounding architecture doesn't depend on the exact spelling.

- [ ] **Step 1: Replace the stub with the real implementation**

```swift
import Foundation
import AVFoundation
import Speech
import FoundationModels
import VideoCoachCore

/// On-device transcription via macOS 26 `SpeechAnalyzer` +
/// `SpeechTranscriber`, summarization via `LanguageModelSession`. Both
/// purely local; no network, no API keys.
struct AppleClipIntelligence: ClipIntelligence {

    // MARK: - Transcription

    func transcribe(audioURL: URL) async throws -> String {
        try await requestSpeechAuthorizationIfNeeded()

        let locale = Self.resolvedLocale()
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .offlineTranscription
        )

        // Install per-locale assets on first use. Apple's API returns
        // nil when the locale's assets are already installed — that's
        // the framework's idempotency mechanism, so no app-level cache.
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await request.downloadAndInstall()
        }

        // Feed audio from the .mov via AVAssetReader. AVAudioFile cannot
        // open .mov containers (it's for plain audio files like .wav /
        // .caf / .m4a); the .mov has a multi-track container with one
        // audio track that we need to extract via AssetReader and feed
        // the PCM buffers into the analyzer's input stream.
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        try await analyzer.start(inputSequence: stream)

        // Producer task: read audio buffers off the asset and push into
        // the analyzer's input stream. When the asset ends, finish the
        // stream so the analyzer terminates.
        let producer = Task<Void, Error> {
            let asset = AVURLAsset(url: audioURL)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let audioTrack = tracks.first else {
                throw NSError(domain: "AppleClipIntelligence", code: -2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Recording has no audio track."])
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            )
            reader.add(output)
            reader.startReading()

            while let buffer = output.copyNextSampleBuffer() {
                continuation.yield(AnalyzerInput(buffer: buffer))
            }
            continuation.finish()
        }

        var parts: [String] = []
        for try await result in transcriber.results {
            if result.isFinal {
                parts.append(String(result.text.characters))
            }
        }
        try await producer.value
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
            throw NSError(
                domain: "AppleClipIntelligence", code: -3,
                userInfo: [NSLocalizedDescriptionKey:
                    "On-device language model unavailable: \(String(describing: reason))."])
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
        return candidate.identifier.isEmpty ? Locale(identifier: "en-US") : candidate
    }

    private func requestSpeechAuthorizationIfNeeded() async throws {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return }
        let status = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw NSError(
                domain: "AppleClipIntelligence", code: -4,
                userInfo: [NSLocalizedDescriptionKey:
                    "Speech recognition not authorized. Enable it in System Settings → Privacy & Security → Speech Recognition."])
        }
    }
}
```

- [ ] **Step 2: Build the app**

```bash
cd apple && xcodegen generate && cd ..
xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build 2>&1 | tail -60
```

Expected: build SUCCEEDED. If any Apple symbols differ (e.g. `SpeechTranscriber.Preset.offlineTranscription` is named differently, `AnalyzerInput` initializer signature differs, or `LanguageModelSession`'s closure shape doesn't match), the compiler will pinpoint each call site. Read the header errors and match the actual symbol. Do NOT speculate.

- [ ] **Step 3: Run all tests**

```bash
swift test --package-path apple/VideoCoachCore
cd apple && xcodebuild -project VideoCoach.xcodeproj -scheme VideoCoach -only-testing:VideoCoachTests test
```

Expected: all PASS. (No unit tests for `AppleClipIntelligence` itself — it requires a real ML stack and live audio. Manual smoke covers it in Task 9.)

- [ ] **Step 4: Commit**

```bash
git add apple/App/Intelligence/AppleClipIntelligence.swift
git commit -m "app: AppleClipIntelligence — real SpeechAnalyzer + LanguageModelSession impl"
```

---

## Task 9: Manual smoke test

**Files:** none (manual validation only)

- [ ] **Step 1: Launch the app + open a project**

```bash
xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -configuration Debug -derivedDataPath /tmp/vc-build build
open /tmp/vc-build/Build/Products/Debug/VideoCoach.app
```

Open or create a project folder. Add a source video.

- [ ] **Step 2: New recording auto-transcribes**

Record a short (5–10 second) clip narrating something simple. Confirm:

1. Sidebar shows the clip immediately after stop.
2. Inspector's transcript area shows "Transcribing…" caption + spinner next to the Transcribe button.
3. Caption switches to "Summarizing…" once transcript text appears.
4. After a few more seconds, summary text appears above the transcript.
5. On a fresh machine, the first run may take noticeably longer (speech-model download). Documented first-run UX.

- [ ] **Step 3: Manual editing of AI fields**

Click into the Summary or Transcript field. Edit the text. Click out (focus-loss). Press `cmd-z`. Confirm: the edit is reverted, leaving the AI-written text intact.

Then click into Notes. Type something. Click out. Press `cmd-z`. Confirm: only the notes edit is reverted; transcript and summary are unchanged (AI writes are not in the undo stack).

- [ ] **Step 4: Persistence across launch**

Quit and re-open the app + project. Confirm both fields are still populated on the clip.

- [ ] **Step 5: Manual re-run via Transcribe button**

Select an existing clip. Click Transcribe. Confirm: the button disables; "Transcribing…" then "Summarizing…" captions; both fields refresh with fresh AI output.

If smoke surfaced fixes, commit them. Otherwise the PR is ready for review.

---

## Out of scope (for backlog)

- Live partial-transcript streaming into the inspector while recording.
- Searching clips by transcript content.
- Translating non-English transcripts.
- Background asset pre-download on app launch.
- Cancelling an in-flight job when a clip is deleted (the `firstIndex(where:)` short-circuit on write is enough).
