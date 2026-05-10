# Back Button + Robust Esc + Project-wide Undo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a top-left BACK button to exit clip preview, make Esc reliably exit preview even when text fields have focus, and add Cmd+Z/Shift+Cmd+Z that walks a per-project undo/redo stack of clip edits and deletes (capped at 100, with at most one delete on the stacks).

**Architecture:** A new `UndoAction` enum on `Workspace` with two cases (`.editClip(before, after)` and `.deleteClip(DeletedClip)`), backed by `undoStack` + `redoStack` arrays. The inspector pushes `.editClip` actions on field focus-loss; `deleteClip()` pushes `.deleteClip` and evicts any prior delete from either stack. The existing `lastDeletedClip` property and `undoLastDelete()` method are removed in favor of unified `undo()` / `redo()` entry points, wired to a new "Undo" / "Redo" pair in the existing Clip menu. Esc fix is a single-clause edit in `KeyCommandView`. Toolbar gets a `.navigation` BACK button that's hidden outside preview modes and a "Coach Cutups" label moved to `.primaryAction`.

**Tech Stack:** SwiftUI, AppKit (NSEvent monitor for keys), XCTest for unit tests on `Workspace`. Manual smoke tests for the toolbar and Esc-while-focused behavior because the app target has no UI test infrastructure yet.

**Build/test commands:**
- Build & launch (after every Swift edit): `apple/scripts/run.sh`
- App-target tests (RecordingZoomCaptureTests etc.): `xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach test -only-testing:VideoCoachTests`
- Core package tests (UndoControllerTests + others): `cd apple/VideoCoachCore && swift test`

---

## File Structure

**Create:**
- `apple/VideoCoachCore/Sources/VideoCoachCore/UndoController.swift` — pure-Swift undo machinery: `DeletedClip`, `UndoAction`, `UndoController` struct with stacks + push/pop/cap/eviction.
- `apple/VideoCoachCore/Tests/VideoCoachCoreTests/UndoControllerTests.swift` — XCTest cases for the controller, runs in the existing hermetic VideoCoachCore test target (no MPVKit dependency).

**Modify:**
- `apple/App/Models/Workspace.swift` — replace `lastDeletedClip` + `undoLastDelete()` + the local `struct DeletedClip` with a `private var history = UndoController()`. Add `commitClipEdit`, `undo()`, `redo()`, forwarding `canUndo`/`canRedo`. Update `deleteClip` to use `history.pushDelete` and shred the evicted trash file. Update `openProject` to call `history.clearAll()`.
- `apple/App/Views/TagField.swift` — add `onFocusChange: (Bool) -> Void` callback so the inspector can observe tag-field focus transitions (TagField's internal `@FocusState` isn't reachable from outside).
- `apple/App/Views/ClipInspector.swift` — `EditorView` adds per-field `@FocusState` for name/notes plus a `tagsSnapshot` driven by TagField's callback, with snapshot-on-focus / commit-on-focus-loss and a `.onDisappear` flush. Drop per-keystroke notes save.
- `apple/App/Views/KeyCommandView.swift` — in `.previewClip` / `.previewLoading`, Esc bypasses the `firstResponder is NSText` guard.
- `apple/App/Views/ClipCommands.swift` — replace the `undoLastDelete` `FocusedValueKey` with `undoAction` + `redoAction`. Replace "Undo Delete Clip" with "Undo" + "Redo".
- `apple/App/ContentView.swift` — replace `undoLastDeleteHandler` with `undoHandler` + `redoHandler` published via `@FocusedValue`. Restructure toolbar: `.navigation` BACK button (only in preview), `.principal` keeps zoom + drawing controls, `.primaryAction` adds title before Export.

---

## Task 1: Create `UndoController` skeleton in `VideoCoachCore`

The undo state and stack management lives in the package (independently testable, no MPVKit cascade). `Workspace` will adopt it in Task 3. Today's `Workspace.DeletedClip` moves here too so the action's payload type is in the same module.

**Files:**
- Create: `apple/VideoCoachCore/Sources/VideoCoachCore/UndoController.swift`

- [ ] **Step 1: Create the file with type declarations and method stubs**

Write `apple/VideoCoachCore/Sources/VideoCoachCore/UndoController.swift`:

```swift
import Foundation

/// In-memory record of a deleted clip plus the on-disk path of its
/// recording in the project's trash directory. The recording file is
/// MOVED, not copied, so undelete restores it without round-tripping
/// data through RAM (safer for the 30–70MB .mov files we deal with).
///
/// Lives in `VideoCoachCore` rather than the app target because it's
/// the payload of `UndoAction.deleteClip` and the controller — which
/// owns the stack — must be able to construct and inspect these.
public struct DeletedClip: Sendable {
    public let clip: Clip
    public let trashedRecordingURL: URL

    public init(clip: Clip, trashedRecordingURL: URL) {
        self.clip = clip
        self.trashedRecordingURL = trashedRecordingURL
    }
}

/// One step on the unified undo stack. `editClip` covers tag/name/notes
/// commits made in the inspector — `before`/`after` are full `Clip`
/// snapshots (small structs, copy is cheap) so applying the inverse is
/// just a slot swap in `project.clips`. `deleteClip` carries the
/// `DeletedClip` value the trash directory tracks; at most one of
/// these may exist across both undo and redo stacks combined, matching
/// the on-disk invariant that we only keep one trashed `.mov` at a
/// time.
public enum UndoAction: Sendable {
    case editClip(id: Clip.ID, before: Clip, after: Clip)
    case deleteClip(DeletedClip)
}

/// Pure-data undo machinery for `Workspace`. Owns the undo / redo
/// stacks and the push / pop / cap / eviction semantics. Does NOT
/// apply actions — that's the caller's job (`Workspace.undo()` mutates
/// `project.clips`, invalidates preview caches, moves files in and out
/// of the trash directory). Keeping the stack manipulation here lets
/// us cover the genuinely-tricky logic (the eviction invariant, the
/// cap, the redo-clear) in `VideoCoachCoreTests` without dragging the
/// app target's MPVKit / AppKit dependencies into the test target.
///
/// Newest entry at the end of each stack array.
public struct UndoController {
    public private(set) var undoStack: [UndoAction] = []
    public private(set) var redoStack: [UndoAction] = []

    /// Maximum length of `undoStack`. Excess entries drop from the
    /// front (oldest first). `redoStack` inherits its bound
    /// implicitly: it can only ever hold what was previously on
    /// `undoStack`.
    public static let stackCap = 100

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Push a non-delete action onto the undo stack. Trims to cap;
    /// clears redo. Use `pushDelete(_:)` for `.deleteClip` — it
    /// carries extra eviction semantics tied to the on-disk trash
    /// invariant.
    public mutating func pushEdit(_ action: UndoAction) {
        fatalError("Implement in Task 2")
    }

    /// Push a delete onto the undo stack. Returns any prior delete
    /// found in either stack, so the caller can shred its trash file
    /// (the controller doesn't do file I/O). Trims to cap; clears
    /// redo.
    public mutating func pushDelete(_ stash: DeletedClip) -> DeletedClip? {
        fatalError("Implement in Task 2")
    }

    /// Pop top of `undoStack`, push it onto `redoStack`, and return
    /// the popped action so the caller can apply its inverse. Returns
    /// nil when the stack is empty.
    public mutating func popForUndo() -> UndoAction? {
        fatalError("Implement in Task 2")
    }

    /// Pop top of `redoStack`, push it onto `undoStack`, and return
    /// the popped action so the caller can apply it forward. Returns
    /// nil when the stack is empty.
    public mutating func popForRedo() -> UndoAction? {
        fatalError("Implement in Task 2")
    }

    /// Drop everything. Called by `Workspace.openProject(...)` so undo
    /// state never carries across project switches.
    public mutating func clearAll() {
        fatalError("Implement in Task 2")
    }
}
```

The `fatalError` stubs let the package build (the type compiles) without committing to an implementation that hasn't been driven by tests yet. Task 2 writes the tests, watches them crash on the stubs, then fills in the bodies.

- [ ] **Step 2: Build the package to verify it compiles**

Run:
```
cd /Users/taylor/dev/coach-cutups-2/apple/VideoCoachCore
swift build
```

Expected: build succeeds. The new file compiles; nothing references the new types yet.

- [ ] **Step 3: Commit**

```bash
cd /Users/taylor/dev/coach-cutups-2
git add apple/VideoCoachCore/Sources/VideoCoachCore/UndoController.swift
git commit -m "feat(core): add UndoController skeleton + UndoAction/DeletedClip

Stack types and shape live in VideoCoachCore so they're testable in
the existing hermetic core test target — Workspace transitively
imports Libmpv via MPVSourcePlayer, which the standalone test target
can't pull in. Method bodies stubbed with fatalError; Task 2 drives
the implementations with tests."
```

---

## Task 2: TDD `UndoController` implementations

**Files:**
- Create: `apple/VideoCoachCore/Tests/VideoCoachCoreTests/UndoControllerTests.swift`
- Modify: `apple/VideoCoachCore/Sources/VideoCoachCore/UndoController.swift`

- [ ] **Step 1: Write the failing tests**

Create `apple/VideoCoachCore/Tests/VideoCoachCoreTests/UndoControllerTests.swift`:

```swift
import XCTest
@testable import VideoCoachCore

final class UndoControllerTests: XCTestCase {

    // MARK: - Test helpers

    private func makeClip(name: String = "Clip") -> Clip {
        Clip(
            id: UUID(),
            name: name,
            sourceIndex: 0,
            startSourceSeconds: 0,
            recordingDuration: 1.0,
            recordingFilename: "clip-\(UUID()).mov",
            sortIndex: 0
        )
    }

    private func makeDeletedClip(filename: String = "clip-x.mov") -> DeletedClip {
        DeletedClip(
            clip: makeClip(),
            trashedRecordingURL: URL(fileURLWithPath: "/tmp/.trash/\(filename)")
        )
    }

    private func makeEdit() -> UndoAction {
        let clip = makeClip(name: "before")
        var after = clip
        after.tags = ["a"]
        return .editClip(id: clip.id, before: clip, after: after)
    }

    // MARK: - pushEdit

    func test_pushEdit_appends_and_clears_redo() {
        var c = UndoController()
        // Seed redoStack via pop, then verify a new pushEdit clears it.
        c.pushEdit(makeEdit())
        _ = c.popForUndo()
        XCTAssertEqual(c.redoStack.count, 1)

        c.pushEdit(makeEdit())

        XCTAssertEqual(c.undoStack.count, 1)
        XCTAssertTrue(c.redoStack.isEmpty)
    }

    func test_pushEdit_trims_to_cap() {
        var c = UndoController()
        for _ in 0..<(UndoController.stackCap + 5) {
            c.pushEdit(makeEdit())
        }
        XCTAssertEqual(c.undoStack.count, UndoController.stackCap)
    }

    // MARK: - pushDelete

    func test_pushDelete_with_no_prior_returns_nil() {
        var c = UndoController()
        let evicted = c.pushDelete(makeDeletedClip())
        XCTAssertNil(evicted)
        XCTAssertEqual(c.undoStack.count, 1)
    }

    func test_pushDelete_evicts_prior_delete_from_undoStack() {
        var c = UndoController()
        let a = makeDeletedClip(filename: "a.mov")
        _ = c.pushDelete(a)
        XCTAssertEqual(c.undoStack.count, 1)

        let b = makeDeletedClip(filename: "b.mov")
        let evicted = c.pushDelete(b)

        XCTAssertEqual(evicted?.trashedRecordingURL, a.trashedRecordingURL)
        // Only B is on the stacks now.
        let allDeletes = (c.undoStack + c.redoStack).filter { action in
            if case .deleteClip = action { return true } else { return false }
        }
        XCTAssertEqual(allDeletes.count, 1)
        if case let .deleteClip(d) = c.undoStack.last! {
            XCTAssertEqual(d.trashedRecordingURL, b.trashedRecordingURL)
        } else {
            XCTFail("Expected .deleteClip on top of undo stack")
        }
    }

    func test_pushDelete_evicts_prior_delete_from_redoStack() {
        var c = UndoController()
        let a = makeDeletedClip(filename: "a.mov")
        _ = c.pushDelete(a)
        // Move A onto redoStack via a pop.
        _ = c.popForUndo()
        XCTAssertTrue(c.undoStack.isEmpty)
        XCTAssertEqual(c.redoStack.count, 1)

        let b = makeDeletedClip(filename: "b.mov")
        let evicted = c.pushDelete(b)

        XCTAssertEqual(evicted?.trashedRecordingURL, a.trashedRecordingURL)
        let allDeletes = (c.undoStack + c.redoStack).filter { action in
            if case .deleteClip = action { return true } else { return false }
        }
        XCTAssertEqual(allDeletes.count, 1)
    }

    func test_pushDelete_clears_redo_when_pushing_succeeds() {
        var c = UndoController()
        // Stage some edits on redo by doing edit + pop.
        c.pushEdit(makeEdit())
        _ = c.popForUndo()
        XCTAssertEqual(c.redoStack.count, 1)

        _ = c.pushDelete(makeDeletedClip())
        XCTAssertTrue(c.redoStack.isEmpty)
    }

    // MARK: - popForUndo / popForRedo

    func test_popForUndo_moves_action_to_redoStack() {
        var c = UndoController()
        let edit = makeEdit()
        c.pushEdit(edit)

        let popped = c.popForUndo()

        XCTAssertNotNil(popped)
        XCTAssertTrue(c.undoStack.isEmpty)
        XCTAssertEqual(c.redoStack.count, 1)
    }

    func test_popForUndo_returns_nil_when_empty() {
        var c = UndoController()
        XCTAssertNil(c.popForUndo())
    }

    func test_popForRedo_moves_action_back_to_undoStack() {
        var c = UndoController()
        c.pushEdit(makeEdit())
        _ = c.popForUndo()

        let popped = c.popForRedo()

        XCTAssertNotNil(popped)
        XCTAssertEqual(c.undoStack.count, 1)
        XCTAssertTrue(c.redoStack.isEmpty)
    }

    func test_popForRedo_returns_nil_when_empty() {
        var c = UndoController()
        XCTAssertNil(c.popForRedo())
    }

    // MARK: - clearAll

    func test_clearAll_drops_both_stacks() {
        var c = UndoController()
        c.pushEdit(makeEdit())
        c.pushEdit(makeEdit())
        _ = c.popForUndo()
        XCTAssertFalse(c.undoStack.isEmpty)
        XCTAssertFalse(c.redoStack.isEmpty)

        c.clearAll()

        XCTAssertTrue(c.undoStack.isEmpty)
        XCTAssertTrue(c.redoStack.isEmpty)
    }

    // MARK: - canUndo / canRedo

    func test_canUndo_canRedo_track_stacks() {
        var c = UndoController()
        XCTAssertFalse(c.canUndo)
        XCTAssertFalse(c.canRedo)

        c.pushEdit(makeEdit())
        XCTAssertTrue(c.canUndo)
        XCTAssertFalse(c.canRedo)

        _ = c.popForUndo()
        XCTAssertFalse(c.canUndo)
        XCTAssertTrue(c.canRedo)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```
cd /Users/taylor/dev/coach-cutups-2/apple/VideoCoachCore
swift test --filter UndoControllerTests
```

Expected: ALL FAIL with `fatalError("Implement in Task 2")` traps from the stubs. This proves the test file compiles, links against the controller, and exercises every method we need to implement.

- [ ] **Step 3: Implement the method bodies**

In `apple/VideoCoachCore/Sources/VideoCoachCore/UndoController.swift`, replace each `fatalError("Implement in Task 2")` body with the real implementation:

```swift
    public mutating func pushEdit(_ action: UndoAction) {
        // Reject delete here so the eviction-aware `pushDelete` is the
        // only way a `.deleteClip` enters the stacks. A misuse caught
        // at runtime is better than silently bypassing eviction.
        if case .deleteClip = action {
            preconditionFailure("Use pushDelete(_:) for .deleteClip actions")
        }
        undoStack.append(action)
        if undoStack.count > Self.stackCap {
            undoStack.removeFirst(undoStack.count - Self.stackCap)
        }
        redoStack.removeAll()
    }

    public mutating func pushDelete(_ stash: DeletedClip) -> DeletedClip? {
        let evicted = evictPriorDelete()
        undoStack.append(.deleteClip(stash))
        if undoStack.count > Self.stackCap {
            undoStack.removeFirst(undoStack.count - Self.stackCap)
        }
        redoStack.removeAll()
        return evicted
    }

    public mutating func popForUndo() -> UndoAction? {
        guard let action = undoStack.popLast() else { return nil }
        redoStack.append(action)
        return action
    }

    public mutating func popForRedo() -> UndoAction? {
        guard let action = redoStack.popLast() else { return nil }
        undoStack.append(action)
        return action
    }

    public mutating func clearAll() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// Walks both stacks (undo first, redo as fallback) for an existing
    /// `.deleteClip`, removes it, and returns the carried `DeletedClip`.
    /// Returns nil when there's nothing to evict. Caller is responsible
    /// for shredding the trashed file if a `DeletedClip` is returned.
    private mutating func evictPriorDelete() -> DeletedClip? {
        if let i = undoStack.lastIndex(where: { if case .deleteClip = $0 { return true } else { return false } }) {
            if case let .deleteClip(d) = undoStack.remove(at: i) { return d }
        }
        if let i = redoStack.lastIndex(where: { if case .deleteClip = $0 { return true } else { return false } }) {
            if case let .deleteClip(d) = redoStack.remove(at: i) { return d }
        }
        return nil
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```
cd /Users/taylor/dev/coach-cutups-2/apple/VideoCoachCore
swift test --filter UndoControllerTests
```

Expected: PASS — all 11 tests green.

If any test fails, debug the implementation. Don't proceed until all pass.

- [ ] **Step 5: Commit**

```
cd /Users/taylor/dev/coach-cutups-2
git add apple/VideoCoachCore/Sources/VideoCoachCore/UndoController.swift apple/VideoCoachCore/Tests/VideoCoachCoreTests/UndoControllerTests.swift
git commit -m "feat(core): UndoController push/pop/cap/eviction (TDD)

Implementations for pushEdit, pushDelete, popForUndo, popForRedo,
clearAll. pushDelete walks both stacks for a prior delete and
returns the evicted DeletedClip so the caller can shred the trash
file. Tests cover all branches; trash file shredding itself is
the caller's job (file IO stays out of the package)."
```

---

## Task 3: Workspace adopts `UndoController` + ContentView/ClipCommands migration

`UndoController` is now fully tested (Task 2). This task wires `Workspace` to own one and apply actions, then migrates the two existing call sites (`ContentView`, `ClipCommands`) so the app target compiles and the menus point at the new entry points. There are no new unit tests — the action-application logic isn't testable in the current target structure, and the controller's logic is already covered. Verification is build + manual smoke at the end.

**Files:**
- Modify: `apple/App/Models/Workspace.swift`
- Modify: `apple/App/ContentView.swift`
- Modify: `apple/App/Views/ClipCommands.swift`

The three files land in one commit because they're a coupled rewrite — removing `lastDeletedClip` + `undoLastDelete()` from `Workspace` breaks `ContentView` and `ClipCommands` until they're migrated. Don't try to commit between them.

- [ ] **Step 1: Update `Workspace.swift`**

Open `apple/App/Models/Workspace.swift`. The plan below is one logical edit; do all parts before saving. They land in one file so they don't have to be staged separately.

**1a. Remove the local `struct DeletedClip` declaration.** Find:

```swift
    /// In-memory record of the most-recently-deleted clip, available for
    /// `undoLastDelete()`. Cleared by another delete (which trashes the new
    /// clip and shreds the previous trash file) or by a successful undo.
    /// Not persisted — quitting the app loses the undo. Each new project
    /// open also clears this and shreds the trash directory.
    private(set) var lastDeletedClip: DeletedClip?

    /// Snapshot of a deleted clip plus the on-disk path of its recording in
    /// the project's trash directory. The recording file itself was *moved*,
    /// not copied, so undelete restores it without round-tripping data
    /// through RAM (safer for the 30-70MB .mov files we deal with).
    struct DeletedClip: Sendable {
        let clip: Clip
        let trashedRecordingURL: URL
    }
```

Replace with:

```swift
    /// Per-project undo/redo machinery. Pure-data; lives in
    /// `VideoCoachCore` so the package's existing test target can cover
    /// the stack semantics without dragging in MPVKit. Application of
    /// each `UndoAction` (mutating `project.clips`, invalidating the
    /// preview cache, moving recording files in / out of `.trash`) is
    /// owned by this class — the controller is a passive bookkeeper.
    private var history = UndoController()

    /// Forwarded from the controller so callers (the `undo` / `redo`
    /// menu handlers, in particular) don't need to know the controller
    /// exists.
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
```

(Note: `DeletedClip` is now in `VideoCoachCore` — already imported at the top of this file as `import VideoCoachCore` — so no new import needed.)

**1b. Replace `deleteClip(id:)`** with the controller-aware version. Find the existing `func deleteClip(id: Clip.ID) throws { ... }` (uses `lastDeletedClip`) and replace its entire body with:

```swift
    /// Removes a clip from the project: drops the in-memory entry, MOVES
    /// the underlying recording into `recordings/.trash/`, invalidates the
    /// preview cache, and persists. Pushes a `.deleteClip` action onto
    /// the undo stack via `history.pushDelete(_:)`, which evicts any
    /// prior `.deleteClip` from either stack (returning the evicted
    /// `DeletedClip` so we can shred its trash file). The clip's
    /// `sortIndex` gap is left as-is — `reorderClips(from:to:)` re-numbers
    /// on next reorder, and the sidebar sorts by `sortIndex`-ascending
    /// so a gap is invisible.
    func deleteClip(id: Clip.ID) throws {
        guard let idx = project.clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = project.clips[idx]
        invalidatePreviewCache(for: id)

        guard let folder else {
            // No folder open ⇒ no trash dir ⇒ no recoverable delete.
            // Drop the clip metadata and bail. (In practice the menu
            // gates on having a project, so this is defensive.)
            project.clips.remove(at: idx)
            try saveProject()
            return
        }

        let recordingsDir = ProjectStore.recordingsDir(in: folder)
        let recordingURL = recordingsDir.appendingPathComponent(clip.recordingFilename)
        let trashDir = recordingsDir.appendingPathComponent(".trash")
        try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let trashedURL = trashDir.appendingPathComponent(clip.recordingFilename)
        if FileManager.default.fileExists(atPath: recordingURL.path) {
            try? FileManager.default.removeItem(at: trashedURL)
            try FileManager.default.moveItem(at: recordingURL, to: trashedURL)
        }
        let stash = DeletedClip(clip: clip, trashedRecordingURL: trashedURL)

        project.clips.remove(at: idx)
        try saveProject()

        // Push onto the controller; if it returns an evicted prior
        // delete, shred that trash file (the controller doesn't do IO).
        if let evicted = history.pushDelete(stash) {
            try? FileManager.default.removeItem(at: evicted.trashedRecordingURL)
        }
    }
```

**1c. Remove `undoLastDelete()`.** Find:

```swift
    /// Restores the most-recently-deleted clip: re-inserts the metadata into
    /// `project.clips` (preserving its original `sortIndex`) and moves the
    /// recording back from `recordings/.trash/`. Returns the restored clip's
    /// id so callers can re-select it; returns nil if there's nothing to
    /// undo.
    @discardableResult
    func undoLastDelete() throws -> Clip.ID? {
        // ... entire body ...
    }
```

Delete the whole method (including the doc comment and `@discardableResult`).

**1d. Add `commitClipEdit`, `undo()`, `redo()`** to `Workspace`. These are the application-logic entry points that callers use. Place them where `undoLastDelete` used to live (the spot is fine; group with related undo concerns):

```swift
    /// Inspector calls this on every field's focus-loss when the
    /// snapshot taken at focus-gain differs from the current clip. Skip
    /// when before == after so an unchanged focus session doesn't pollute
    /// the stack. Any redo branch is dropped.
    func commitClipEdit(id: Clip.ID, before: Clip, after: Clip) {
        guard before != after else { return }
        history.pushEdit(.editClip(id: id, before: before, after: after))
    }

    /// Pop one action from the undo stack and apply its inverse. Quietly
    /// no-ops when the stack is empty so menu wiring doesn't have to
    /// gate the call. Returns the action that was applied so the caller
    /// (ContentView) can adjust selection — it doesn't see the
    /// controller directly. Save errors during the inverse are
    /// swallowed (project file may be on a read-only volume mid-flight);
    /// the in-memory state is what the user sees and is what counts for
    /// undo correctness.
    @discardableResult
    func undo() -> UndoAction? {
        guard let action = history.popForUndo() else { return nil }
        applyInverse(of: action)
        return action
    }

    /// Symmetric to `undo()`. Pops one action from the redo stack and
    /// applies it forward. Returns the applied action.
    @discardableResult
    func redo() -> UndoAction? {
        guard let action = history.popForRedo() else { return nil }
        applyForward(of: action)
        return action
    }

    private func applyInverse(of action: UndoAction) {
        switch action {
        case let .editClip(id, before, _):
            if let i = project.clips.firstIndex(where: { $0.id == id }) {
                project.clips[i] = before
                invalidatePreviewCache(for: id)
                try? saveProject()
            }
        case let .deleteClip(stash):
            // Move .mov out of trash and re-insert the clip at its
            // original sortIndex slot. Tolerate a missing trash file
            // (someone may have cleaned it externally) — metadata still
            // restores. Re-selection of the restored clip is done by
            // the menu handler in ContentView, not here.
            if let folder, FileManager.default.fileExists(atPath: stash.trashedRecordingURL.path) {
                let recordingsDir = ProjectStore.recordingsDir(in: folder)
                let target = recordingsDir.appendingPathComponent(stash.clip.recordingFilename)
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.moveItem(at: stash.trashedRecordingURL, to: target)
            }
            let insertAt = project.clips.firstIndex(where: { $0.sortIndex > stash.clip.sortIndex })
                ?? project.clips.endIndex
            project.clips.insert(stash.clip, at: insertAt)
            try? saveProject()
        }
    }

    private func applyForward(of action: UndoAction) {
        switch action {
        case let .editClip(id, _, after):
            if let i = project.clips.firstIndex(where: { $0.id == id }) {
                project.clips[i] = after
                invalidatePreviewCache(for: id)
                try? saveProject()
            }
        case let .deleteClip(stash):
            // Re-apply the delete: remove from project, move .mov back
            // into trash. The action's `trashedRecordingURL` points at
            // the same path we'll re-occupy.
            if let i = project.clips.firstIndex(where: { $0.id == stash.clip.id }) {
                invalidatePreviewCache(for: stash.clip.id)
                project.clips.remove(at: i)
            }
            if let folder {
                let recordingsDir = ProjectStore.recordingsDir(in: folder)
                let recordingURL = recordingsDir.appendingPathComponent(stash.clip.recordingFilename)
                let trashDir = recordingsDir.appendingPathComponent(".trash")
                try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: recordingURL.path) {
                    try? FileManager.default.removeItem(at: stash.trashedRecordingURL)
                    try? FileManager.default.moveItem(at: recordingURL, to: stash.trashedRecordingURL)
                }
            }
            try? saveProject()
        }
    }
```

**1e. Update `openProject(...)`.** Find:

```swift
        // Undo state is in-memory only — never carries across app launches
        // or project switches. Shred any leftover trash from a prior session.
        lastDeletedClip = nil
        shredTrashDirectory()
```

Replace with:

```swift
        // Undo state is in-memory only — never carries across app launches
        // or project switches. Shred any leftover trash from a prior session.
        history.clearAll()
        shredTrashDirectory()
```

After step 1, `Workspace.swift` compiles in isolation, but `ContentView.swift` and `ClipCommands.swift` still reference `lastDeletedClip` / `undoLastDelete`. The full target won't link until step 2.

(The original plan revision had inline `Workspace`-coverage tests in `apple/Tests/AppTests/UndoStackTests.swift` at this step. Those tests now live as controller tests in `VideoCoachCoreTests/UndoControllerTests.swift` — Task 2 already created and ran them.)

- [ ] **Step 2: Migrate `ContentView` and `ClipCommands` in the same edit**

Open `apple/App/ContentView.swift`. Find:

```swift
            // Undo delete is gated on Workspace.lastDeletedClip — also nil
            // when nothing has been deleted, or while recording.
            .focusedValue(\.undoLastDelete, undoLastDeleteHandler)
```

Replace with:

```swift
            // Undo / redo are gated on Workspace.canUndo / canRedo — both
            // nil while recording so the menu items auto-disable.
            .focusedValue(\.undoAction, undoHandler)
            .focusedValue(\.redoAction, redoHandler)
```

Find the `undoLastDeleteHandler` computed property:

```swift
    /// Computed handler for Clip ▸ Undo Delete Clip (⌘Z). nil when there's
    /// nothing to undo OR while recording — the menu item disables itself
    /// in either case. On success, re-selects the restored clip so the user
    /// sees what came back.
    private var undoLastDeleteHandler: (() -> Void)? {
        guard workspace.lastDeletedClip != nil else { return nil }
        if appMode == .recording || appMode == .recordingStarting { return nil }
        return {
            do {
                if let restored = try workspace.undoLastDelete() {
                    selectedClipID = restored
                }
            } catch {
                recordingError = "Couldn't undo delete: \(error.localizedDescription)"
            }
        }
    }
```

Replace with:

```swift
    /// Handler published to the Clip ▸ Undo (⌘Z) menu. nil when the undo
    /// stack is empty OR while recording — the menu item disables itself
    /// in either case. ALWAYS selects the affected clip after undoing —
    /// without this, an undo of an edit on a non-selected clip is silent
    /// (model reverts but the user sees nothing change) and the user
    /// can't tell whether Cmd+Z actually did anything.
    private var undoHandler: (() -> Void)? {
        guard workspace.canUndo else { return nil }
        if appMode == .recording || appMode == .recordingStarting { return nil }
        return {
            guard let undone = workspace.undo() else { return }
            switch undone {
            case let .editClip(id, _, _):
                selectedClipID = id
            case let .deleteClip(stash):
                selectedClipID = stash.clip.id
            }
        }
    }

    /// Handler published to the Clip ▸ Redo (⇧⌘Z) menu. Same gating
    /// rules as undo. For an `.editClip` redo, selects the affected
    /// clip (mirrors undo). For a `.deleteClip` redo, clears selection
    /// if the deleted clip was selected — same behavior as a fresh
    /// delete in `requestDeleteClip`.
    private var redoHandler: (() -> Void)? {
        guard workspace.canRedo else { return nil }
        if appMode == .recording || appMode == .recordingStarting { return nil }
        return {
            guard let redone = workspace.redo() else { return }
            switch redone {
            case let .editClip(id, _, _):
                selectedClipID = id
            case let .deleteClip(stash):
                if selectedClipID == stash.clip.id {
                    selectedClipID = nil
                }
            }
        }
    }
```

`ClipCommands.swift` will still reference the old `undoLastDelete` `FocusedValueKey`. The next edit is in the same task because they have to land together for the target to compile.

In `apple/App/Views/ClipCommands.swift`, find:

```swift
private struct UndoLastDeleteKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var deleteSelectedClip: (() -> Void)? {
        get { self[DeleteSelectedClipKey.self] }
        set { self[DeleteSelectedClipKey.self] = newValue }
    }
    var undoLastDelete: (() -> Void)? {
        get { self[UndoLastDeleteKey.self] }
        set { self[UndoLastDeleteKey.self] = newValue }
    }
}
```

Replace with:

```swift
private struct UndoActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct RedoActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var deleteSelectedClip: (() -> Void)? {
        get { self[DeleteSelectedClipKey.self] }
        set { self[DeleteSelectedClipKey.self] = newValue }
    }
    var undoAction: (() -> Void)? {
        get { self[UndoActionKey.self] }
        set { self[UndoActionKey.self] = newValue }
    }
    var redoAction: (() -> Void)? {
        get { self[RedoActionKey.self] }
        set { self[RedoActionKey.self] = newValue }
    }
}
```

Find the `ClipCommands` struct body:

```swift
struct ClipCommands: Commands {
    @FocusedValue(\.deleteSelectedClip) private var deleteHandler
    @FocusedValue(\.undoLastDelete) private var undoDeleteHandler

    var body: some Commands {
        CommandMenu("Clip") {
            // No "…" — the action is one-shot now (no confirm) but
            // recoverable via Undo Delete Clip below.
            Button("Delete Clip") { deleteHandler?() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(deleteHandler == nil)

            Button("Undo Delete Clip") { undoDeleteHandler?() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(undoDeleteHandler == nil)
        }
    }
}
```

Replace with:

```swift
struct ClipCommands: Commands {
    @FocusedValue(\.deleteSelectedClip) private var deleteHandler
    @FocusedValue(\.undoAction) private var undoHandler
    @FocusedValue(\.redoAction) private var redoHandler

    var body: some Commands {
        CommandMenu("Clip") {
            // No "…" — the action is one-shot now (no confirm) but
            // recoverable via Undo below.
            Button("Delete Clip") { deleteHandler?() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(deleteHandler == nil)

            Divider()

            // Whole-project undo: covers the most recent clip edit
            // (tags / name / notes) OR the most recent delete, whichever
            // was last. Disabled while recording.
            Button("Undo") { undoHandler?() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(undoHandler == nil)

            Button("Redo") { redoHandler?() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(redoHandler == nil)
        }
    }
}
```

- [ ] **Step 3: Build and run the existing core tests**

Run the package's tests to confirm `UndoController` still works after the integration (it shouldn't have changed, but verify):
```
cd /Users/taylor/dev/coach-cutups-2/apple/VideoCoachCore
swift test --filter UndoControllerTests
```
Expected: PASS — same 11 tests from Task 2.

Build and launch the app:
```
/Users/taylor/dev/coach-cutups-2/apple/scripts/run.sh
```
Expected: build succeeds, app launches.

Manual smoke check:
- Open a project, select a clip, press Cmd+Delete to delete it.
- Cmd+Z → clip comes back and gets re-selected (matches old `undoLastDelete` behavior plus the new selection rule).
- Shift+Cmd+Z → clip is deleted again.
- Open the Clip menu — both "Undo" and "Redo" appear, with the right enable/disable state.

If the build fails on `lastDeletedClip` or `undoLastDelete` references, you missed a call site. The full set is: `Workspace.deleteClip` (rewritten in 1b), `Workspace.openProject` (rewritten in 1e), `ContentView.undoLastDeleteHandler` + `.focusedValue` (rewritten in step 2), `ClipCommands.UndoLastDeleteKey` + menu (rewritten in step 2).

- [ ] **Step 4: Commit**

```bash
cd /Users/taylor/dev/coach-cutups-2
git add apple/App/Models/Workspace.swift apple/App/Views/ClipCommands.swift apple/App/ContentView.swift
git commit -m "feat(workspace): adopt UndoController + add Undo/Redo menu

Workspace replaces local lastDeletedClip + undoLastDelete() with a
private UndoController (from VideoCoachCore) plus app-side
applyInverse / applyForward that mutate project.clips, invalidate
the preview cache, and move recording files in / out of .trash.
deleteClip pushes through history.pushDelete and shreds the evicted
trash file when one is returned. ContentView publishes undoAction +
redoAction focused values; ClipCommands menu renames \"Undo Delete
Clip\" to \"Undo\" and adds \"Redo\" (⇧⌘Z). Always selects the
affected clip on undo/redo so non-selected-clip edits are visible."
```

---

## Task 4: Inspector — snapshot on focus, commit on focus-loss

**Files:**
- Modify: `apple/App/Views/TagField.swift`
- Modify: `apple/App/Views/ClipInspector.swift`

`TagField` owns an internal `@FocusState` and renders its own `TextField`. SwiftUI's `.focused($state, equals:)` modifier applied from outside on a wrapper view does NOT propagate to the inner `TextField` — it's view-local. We expose focus changes via a callback parameter on TagField and have the inspector track tag focus through that callback while using `@FocusState` directly on the Name `TextField` and Notes `TextEditor`.

- [ ] **Step 1: Add an `onFocusChange` parameter to `TagField`**

In `apple/App/Views/TagField.swift`, change the struct's stored properties (around lines 9–13) from:

```swift
    @Binding var tags: [String]
    /// Pool of existing tags to suggest from — typically derived from
    /// `Set(workspace.project.clips.flatMap(\.tags))`.
    let suggestions: Set<String>
    let onCommit: () -> Void
```

to:

```swift
    @Binding var tags: [String]
    /// Pool of existing tags to suggest from — typically derived from
    /// `Set(workspace.project.clips.flatMap(\.tags))`.
    let suggestions: Set<String>
    let onCommit: () -> Void
    /// Fires whenever the internal TextField gains or loses focus.
    /// Used by the inspector to snapshot/commit clip edits for the undo
    /// stack. Default no-op so other call sites don't have to care.
    var onFocusChange: (Bool) -> Void = { _ in }
```

Then find the existing `.onChange(of: isFocused)` block (around lines 59–65):

```swift
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    commit()
                    highlightedIndex = nil
                    popoverManuallyDismissed = false
                }
            }
```

Replace with:

```swift
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    commit()
                    highlightedIndex = nil
                    popoverManuallyDismissed = false
                }
                onFocusChange(focused)
            }
```

That preserves the existing commit-on-blur behavior and adds an outbound notification on every focus transition.

- [ ] **Step 2: Replace `EditorView` body with per-field focus tracking**

In `apple/App/Views/ClipInspector.swift`, replace the entire `private struct EditorView` (lines 71–115) with:

```swift
private struct EditorView: View {
    let workspace: Workspace
    @Binding var clip: Clip
    let suggestions: Set<String>

    @FocusState private var nameFocused: Bool
    @FocusState private var notesFocused: Bool

    /// Per-field snapshots taken on focus-gain. Each field commits its
    /// own undo step on focus-loss. Per-spec ("each blur/Enter on a
    /// field is one step"), so tabbing name → tags → notes produces
    /// up to three undo steps. No union/coalescing here — it would
    /// require coordinating two different focus-tracking primitives
    /// (@FocusState for name+notes, callback for TagField) and the
    /// interleave order between them isn't guaranteed by SwiftUI.
    @State private var nameSnapshot: Clip?
    @State private var tagsSnapshot: Clip?
    @State private var notesSnapshot: Clip?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clip").font(.headline)

            Group {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("Clip name", text: $clip.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onChange(of: nameFocused) { _, focused in
                        handleFocusChange(focused: focused, snapshot: $nameSnapshot)
                    }
                    .onSubmit { try? workspace.saveProject() }
            }

            Group {
                Text("Tags").font(.caption).foregroundStyle(.secondary)
                TagField(
                    tags: $clip.tags,
                    suggestions: suggestions,
                    onCommit: { try? workspace.saveProject() },
                    onFocusChange: { focused in
                        handleFocusChange(focused: focused, snapshot: $tagsSnapshot)
                    }
                )
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

            Spacer()
        }
        // Safety net: if the EditorView is torn down (selection change,
        // Esc-to-source) while a field still holds an in-flight snapshot,
        // SwiftUI does NOT guarantee the field's focus-loss onChange
        // fires. Flush any remaining snapshots here so the user's edit
        // gets one undo step rather than vanishing. The bound clip is
        // already up-to-date because TextField/TextEditor write through
        // their bindings on every keystroke and TagField commits in its
        // own .onDisappear.
        .onDisappear {
            flush(&nameSnapshot)
            flush(&tagsSnapshot)
            flush(&notesSnapshot)
        }
    }

    /// Called on every focus transition for one field. On focus-gain,
    /// snapshot the clip; on focus-loss, push one commitClipEdit if the
    /// clip changed and clear the snapshot.
    private func handleFocusChange(focused: Bool, snapshot: Binding<Clip?>) {
        if focused {
            snapshot.wrappedValue = clip
        } else {
            flush(snapshot.wrappedValue.map { $0 }, clear: { snapshot.wrappedValue = nil })
        }
    }

    /// Two-arity flush (used by handleFocusChange — snapshot is held in
    /// a Binding, can't be inout-passed).
    private func flush(_ before: Clip?, clear: () -> Void) {
        guard let before, before != clip else { clear(); return }
        workspace.commitClipEdit(id: clip.id, before: before, after: clip)
        try? workspace.saveProject()
        clear()
    }

    /// One-arity flush over an inout snapshot (used by .onDisappear).
    private func flush(_ snapshot: inout Clip?) {
        guard let before = snapshot, before != clip else { snapshot = nil; return }
        workspace.commitClipEdit(id: clip.id, before: before, after: clip)
        try? workspace.saveProject()
        snapshot = nil
    }
}
```

Notes on the design:
1. Three independent snapshots, one per field. Each field handles its own focus-gain/focus-loss without depending on the others. Eliminates the inter-field tab interleave race that a union-tracking approach would have.
2. `TagField`'s `onCommit` still calls `saveProject()` on Enter so partial-edit data is durable across app exit. The focus-loss path then no-ops because `commitClipEdit` early-returns on `before == after`.
3. The `.onDisappear` flush is the backstop for view-teardown paths SwiftUI does not guarantee fire `onChange(of:focused)`: selecting a different clip (the parent `ClipInspector` applies `.id(id)` to force teardown) and Esc-to-source (ContentView clears `selectedClipID`, removing the inspector entirely).

- [ ] **Step 3: Build and smoke-test the field-edit flow**

Run: `apple/scripts/run.sh`

Manual smoke test:
- Open a project with at least one clip.
- Click the clip. Type a tag in the Tags field. Click outside the field.
- Open the Clip menu — "Undo" is enabled.
- Press Cmd+Z — the tag disappears.
- Press Shift+Cmd+Z — the tag comes back.
- Repeat with Name and Notes.
- Tab from name → tags → notes, making one change in each. Click outside. Press Cmd+Z three times — each undo reverts one field at a time. (Per-spec: one blur = one step.)
- Edit tags, then press Esc (instead of clicking out) — preview closes. Re-select the clip — tag change is present, Cmd+Z undoes it (the `.onDisappear` flush did its job).

If any field doesn't push an undo step, the engineer should re-check the `@FocusState` wiring (for name / notes) and the `onFocusChange` callback wiring (for tags).

- [ ] **Step 4: Commit**

```bash
git add apple/App/Views/TagField.swift apple/App/Views/ClipInspector.swift
git commit -m "feat(inspector): per-field focus-loss commit feeds undo stack

TagField gains an onFocusChange callback so the inspector can track
its focus alongside the name TextField and notes TextEditor (which
use @FocusState directly). EditorView snapshots the clip on
focus-gain and pushes one commitClipEdit on focus-loss when state
changed. Notes switches from per-keystroke save to per-session save.
TagField onCommit still saves on Enter so partial-edit data is
durable across app exit."
```

---

## Task 5: Esc bypasses the text-field guard while in preview

**Files:**
- Modify: `apple/App/Views/KeyCommandView.swift`

- [ ] **Step 1: Restructure the monitor so preview-mode Esc skips the NSText guard**

In `apple/App/Views/KeyCommandView.swift`, find the monitor closure starting at line 94. The current text-field guard is:

```swift
            // If a text editor (TextField field editor or TextEditor) currently has
            // focus, let the keystroke through. Otherwise typing "space", "a", "d"
            // into a name/tag/notes field would silently trigger video transport
            // commands instead of inserting characters.
            if window.firstResponder is NSText { return event }
```

Replace it with:

```swift
            let textIsFocused = window.firstResponder is NSText
            // Most shortcuts must defer to a focused text field — typing
            // "space", "a", "d" into a name/tag/notes field shouldn't fire
            // transport commands. Esc is the exception while previewing a
            // clip: if focus has wandered into the inspector, the user
            // still expects Esc to bail back to the source. Field-edit
            // commits happen on focus-loss (and on Enter for the name
            // field) so nothing in-flight is dropped — the focus change
            // induced by Esc still flows through ClipInspector's
            // onChange(of: focusedField) path.
            if textIsFocused && !(event.keyCode == KeyCode.escape && self.isPreviewMode()) {
                return event
            }
```

That `isPreviewMode()` helper doesn't exist yet — add it to `KeyCatchingView` just below the existing `currentZoomScale` property:

```swift
    private func isPreviewMode() -> Bool {
        switch appMode {
        case .previewClip, .previewLoading: return true
        default: return false
        }
    }
```

- [ ] **Step 2: Build and smoke-test**

Run: `apple/scripts/run.sh`

Manual smoke test (the bug being fixed):
- Open a project with at least one clip and select a clip (now in `.previewClip`).
- Click into the Tags field and start typing (don't blur).
- Press Esc.
- Expected: preview closes, source becomes visible again. Pending tag text is committed via the focus-loss path.
- Bonus check: while typing in the Tags field with the autocomplete popover visible, Esc still just dismisses the popover (TagField's `.onKeyPress(.escape)` returns `.handled` first).

- [ ] **Step 3: Commit**

```bash
git add apple/App/Views/KeyCommandView.swift
git commit -m "fix(key-commands): Esc exits preview even with text-field focus

Previously a focused inspector field would absorb Esc, leaving the
user stuck in clip preview until they clicked outside the field. Now
the global key monitor lets Esc through to onClosePreview while in
preview modes regardless of NSText focus. TagField's autocomplete
popover Esc handler still wins via SwiftUI's onKeyPress (returns
.handled) so popover-dismiss behavior is preserved."
```

---

## Task 6: Toolbar — BACK button and "Coach Cutups" label

**Files:**
- Modify: `apple/App/ContentView.swift`

- [ ] **Step 1: Restructure the toolbar**

In `apple/App/ContentView.swift`, find the existing `.toolbar { ... }` block (around lines 363–402):

```swift
        .toolbar {
            // Centered always-on cluster: zoom level + drawing controls.
            // ... existing comment ...
            ToolbarItem(placement: .principal) {
                HStack(spacing: 16) {
                    ZoomIndicator(zoom: workspace.currentZoom)
                    Toggle("Auto-clear (5s)", isOn: $autoClearStrokes)
                        .toggleStyle(.checkbox)
                        .disabled(appMode != .recording)
                    Button("Clear All") {
                        drawingClearToken &+= 1
                        recordingController?.appendClearAll()
                    }
                    .disabled(appMode != .recording)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showExportSheet = true
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .disabled(workspace.folder == nil || workspace.project.clips.isEmpty)
                .help(workspace.folder == nil
                      ? "Open a project to export"
                      : (workspace.project.clips.isEmpty
                         ? "Record at least one clip to export"
                         : "Export compilations…"))
            }
        }
```

Replace with:

```swift
        .toolbar {
            // Top-left BACK affordance: shown only while previewing a
            // clip, mirrors the Esc shortcut and the existing Source
            // button in TransportBar. Hidden (not just disabled) outside
            // preview modes so it doesn't visually clutter the toolbar
            // during scanning/recording.
            ToolbarItem(placement: .navigation) {
                if isPreviewMode {
                    Button(action: handleClosePreview) {
                        Label("Source", systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                            .font(.headline)
                    }
                    .controlSize(.large)
                    .help("Return to source video (Esc)")
                }
            }
            // Centered always-on cluster: zoom level + drawing controls.
            // ... preserved existing comment ...
            ToolbarItem(placement: .principal) {
                HStack(spacing: 16) {
                    ZoomIndicator(zoom: workspace.currentZoom)
                    Toggle("Auto-clear (5s)", isOn: $autoClearStrokes)
                        .toggleStyle(.checkbox)
                        .disabled(appMode != .recording)
                    Button("Clear All") {
                        drawingClearToken &+= 1
                        recordingController?.appendClearAll()
                    }
                    .disabled(appMode != .recording)
                }
            }
            // Right side: app-name label, then Export. The window's
            // navigationTitle still drives the macOS window chrome — this
            // toolbar label is a redundant in-pane affordance the user
            // asked for.
            ToolbarItem(placement: .primaryAction) {
                Text("Coach Cutups")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showExportSheet = true
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .disabled(workspace.folder == nil || workspace.project.clips.isEmpty)
                .help(workspace.folder == nil
                      ? "Open a project to export"
                      : (workspace.project.clips.isEmpty
                         ? "Record at least one clip to export"
                         : "Export compilations…"))
            }
        }
```

Add the `isPreviewMode` computed property near the other private helpers in `ContentView` (just below `buildSubtitle`):

```swift
    private var isPreviewMode: Bool {
        switch appMode {
        case .previewClip, .previewLoading: return true
        default: return false
        }
    }
```

- [ ] **Step 2: Build and smoke-test**

Run: `apple/scripts/run.sh`

Manual smoke test:
- Scanning mode: top-left of toolbar shows nothing extra (BACK hidden). Title "Coach Cutups" appears at the right of the toolbar before Export.
- Click a clip (preview mode): a large "← Source" button appears in the top-left of the toolbar. Click it → preview closes, BACK button disappears.
- Re-enter preview, press Esc → same effect.

- [ ] **Step 3: Commit**

```bash
git add apple/App/ContentView.swift
git commit -m "feat(toolbar): add BACK button (preview-only) and Coach Cutups label

Top-left navigation slot gets a large \"← Source\" button while in
.previewClip / .previewLoading; hidden in scanning/recording. Right
side gets a \"Coach Cutups\" label before Export. Existing centered
zoom + drawing-controls cluster is preserved."
```

---

## Task 7: Final regression sweep

**Files:** none (verification only).

- [ ] **Step 1: Run the full test suite**

Run both:
```
cd /Users/taylor/dev/coach-cutups-2/apple/VideoCoachCore && swift test
cd /Users/taylor/dev/coach-cutups-2 && xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach test -only-testing:VideoCoachTests
```
Expected: ALL PASS — `UndoControllerTests` (new in VideoCoachCoreTests) + `RecordingZoomCaptureTests` (existing in VideoCoachTests) + every other existing core test.

- [ ] **Step 2: Manual smoke test of the integrated behaviors**

Run: `apple/scripts/run.sh`. Walk through these scenarios end-to-end:

1. **Tag round-trip undo:** Pick a clip, type "shot, set", click outside → tags appear. Cmd+Z → tags disappear. Shift+Cmd+Z → tags reappear.
2. **Notes round-trip undo:** Type a sentence in notes, click outside → saved. Cmd+Z → reverts. Shift+Cmd+Z → restored.
3. **Multi-step undo:** Edit name, tags, notes (commit each by clicking out). Press Cmd+Z three times → walks back in reverse order.
4. **Delete + edit interleaved:** Edit a clip's name, delete a different clip, edit a third clip's tags. Cmd+Z three times → tags revert, deleted clip restored, name reverts.
5. **Two deletes evict:** Delete clip A, delete clip B. Cmd+Z restores B (not A). Cmd+Z again → no-op (A's entry was evicted).
6. **Esc with field focus:** Click clip, click into Notes, type, press Esc → preview exits. Re-enter preview → notes text is preserved (the focus-loss commit ran).
7. **BACK button visibility:** In scanning mode, no BACK button. Click clip → BACK appears. Click BACK → returns to source. Start recording → no BACK.
8. **Recording gates undo/redo:** Press R to start recording. Open Clip menu → Undo and Redo are disabled. Stop recording → enabled again.

- [ ] **Step 3: Commit nothing (verification task)**

If anything fails in step 2, file a follow-up — the underlying code is in earlier tasks' commits.
