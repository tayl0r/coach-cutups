# Back Button + Robust Esc + Project-wide Undo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a top-left BACK button to exit clip preview, make Esc reliably exit preview even when text fields have focus, and add Cmd+Z/Shift+Cmd+Z that walks a per-project undo/redo stack of clip edits and deletes (capped at 100, with at most one delete on the stacks).

**Architecture:** A new `UndoAction` enum on `Workspace` with two cases (`.editClip(before, after)` and `.deleteClip(DeletedClip)`), backed by `undoStack` + `redoStack` arrays. The inspector pushes `.editClip` actions on field focus-loss; `deleteClip()` pushes `.deleteClip` and evicts any prior delete from either stack. The existing `lastDeletedClip` property and `undoLastDelete()` method are removed in favor of unified `undo()` / `redo()` entry points, wired to a new "Undo" / "Redo" pair in the existing Clip menu. Esc fix is a single-clause edit in `KeyCommandView`. Toolbar gets a `.navigation` BACK button that's hidden outside preview modes and a "Coach Cutups" label moved to `.primaryAction`.

**Tech Stack:** SwiftUI, AppKit (NSEvent monitor for keys), XCTest for unit tests on `Workspace`. Manual smoke tests for the toolbar and Esc-while-focused behavior because the app target has no UI test infrastructure yet.

**Build/test commands:**
- Build & launch (after every Swift edit): `apple/scripts/run.sh`
- Unit tests: `xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach test -only-testing:AppTests`

---

## File Structure

**Create:**
- `apple/Tests/AppTests/UndoStackTests.swift` — XCTest cases for `Workspace.commitClipEdit`, `undo()`, `redo()`, and the delete-eviction invariant.

**Modify:**
- `apple/App/Models/Workspace.swift` — add `UndoAction`, `undoStack`, `redoStack`, `commitClipEdit`, `undo`, `redo`, `canUndo`, `canRedo`. Remove `lastDeletedClip` and `undoLastDelete()`. Update `deleteClip` and `openProject`.
- `apple/App/Views/ClipInspector.swift` — `EditorView` adds `@FocusState`, snapshot-on-focus, commit-on-focus-loss for name / tags / notes. Drop per-keystroke notes save.
- `apple/App/Views/KeyCommandView.swift` — in `.previewClip` / `.previewLoading`, Esc bypasses the `firstResponder is NSText` guard.
- `apple/App/Views/ClipCommands.swift` — replace the `undoLastDelete` `FocusedValueKey` with `undoAction` + `redoAction`. Replace "Undo Delete Clip" with "Undo" + "Redo".
- `apple/App/ContentView.swift` — replace `undoLastDeleteHandler` with `undoHandler` + `redoHandler` published via `@FocusedValue`. Restructure toolbar: `.navigation` BACK button (only in preview), `.principal` keeps zoom + drawing controls, `.primaryAction` adds title before Export.

---

## Task 1: Add `UndoAction` and empty stacks to Workspace

**Files:**
- Modify: `apple/App/Models/Workspace.swift`

- [ ] **Step 1: Add the type declaration and stack properties**

Just under `struct DeletedClip` (around line 462–465), add the new enum and stacks. Don't wire any push paths yet — that's Tasks 2 and 3. We add this first so the test file in Task 2 can reference the type.

Find this block:

```swift
    /// In-memory record of the most-recently-deleted clip, available for
    /// `undoLastDelete()`. Cleared by another delete (which trashes the new
    /// clip and shreds the previous trash file) or by a successful undo.
    /// Not persisted — quitting the app loses the undo. Each new project
    /// open also clears this and shreds the trash directory.
    private(set) var lastDeletedClip: DeletedClip?
```

Replace with:

```swift
    /// One step on the unified undo stack. `editClip` covers tag/name/notes
    /// commits made in the inspector — `before`/`after` are full Clip
    /// snapshots (small structs, copy is cheap) so undo is just a slot
    /// swap. `deleteClip` carries the same `DeletedClip` value the trash
    /// directory tracks; at most one of these may exist across both stacks
    /// combined, matching the on-disk invariant that we only keep one
    /// trashed `.mov` at a time.
    enum UndoAction {
        case editClip(id: Clip.ID, before: Clip, after: Clip)
        case deleteClip(DeletedClip)
    }

    /// Per-project undo and redo histories. Newest entry at the end of
    /// each array. Cleared on `openProject(...)` and never persisted —
    /// quitting the app, switching projects, or relaunching loses the
    /// stacks (matches the existing trash-shred behavior).
    private(set) var undoStack: [UndoAction] = []
    private(set) var redoStack: [UndoAction] = []

    /// Cap on `undoStack` length. Drops from the front (oldest) when a new
    /// push would exceed it. The redo stack inherits its bound implicitly:
    /// it can only ever hold what was previously on `undoStack`.
    static let undoStackCap = 100

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
```

Leave `lastDeletedClip` removal for Task 3 — keep it in place for now so existing call sites in `ContentView` keep compiling. They get migrated together in Task 6.

- [ ] **Step 2: Build to verify it compiles**

Run: `apple/scripts/run.sh`
Expected: build succeeds, app launches. The new properties aren't wired to anything yet, so behavior is unchanged.

- [ ] **Step 3: Commit**

```bash
git add apple/App/Models/Workspace.swift
git commit -m "feat(workspace): add UndoAction enum and empty stacks (no wiring yet)"
```

---

## Task 2: TDD `commitClipEdit` + undo/redo for `.editClip`

**Files:**
- Create: `apple/Tests/AppTests/UndoStackTests.swift`
- Modify: `apple/App/Models/Workspace.swift`

- [ ] **Step 1: Write the failing tests**

Create `apple/Tests/AppTests/UndoStackTests.swift`:

```swift
import XCTest
import VideoCoachCore
@testable import VideoCoach

@MainActor
final class UndoStackTests: XCTestCase {

    /// Helper: a Workspace seeded with one clip and no folder. Folder-less
    /// workspaces can't persist, but commitClipEdit / undo / redo for
    /// edit actions don't touch disk so the tests stay hermetic.
    private func makeWorkspaceWithOneClip() -> (Workspace, Clip) {
        let ws = Workspace()
        let clip = Clip(
            id: UUID(),
            name: "First",
            sourceIndex: 0,
            startSourceSeconds: 0,
            recordingDuration: 1.0,
            recordingFilename: "clip-test.mov",
            sortIndex: 0
        )
        ws.project.clips = [clip]
        return (ws, clip)
    }

    func test_commitClipEdit_pushes_one_action() {
        let (ws, clip) = makeWorkspaceWithOneClip()
        var after = clip
        after.tags = ["shot"]
        ws.project.clips[0] = after

        ws.commitClipEdit(id: clip.id, before: clip, after: after)

        XCTAssertEqual(ws.undoStack.count, 1)
        XCTAssertTrue(ws.redoStack.isEmpty)
    }

    func test_commitClipEdit_skips_when_before_equals_after() {
        let (ws, clip) = makeWorkspaceWithOneClip()
        ws.commitClipEdit(id: clip.id, before: clip, after: clip)
        XCTAssertEqual(ws.undoStack.count, 0)
    }

    func test_undo_editClip_restores_before() {
        let (ws, clip) = makeWorkspaceWithOneClip()
        var after = clip
        after.tags = ["shot"]
        ws.project.clips[0] = after
        ws.commitClipEdit(id: clip.id, before: clip, after: after)

        ws.undo()

        XCTAssertEqual(ws.project.clips[0].tags, [])
        XCTAssertTrue(ws.undoStack.isEmpty)
        XCTAssertEqual(ws.redoStack.count, 1)
    }

    func test_redo_editClip_reapplies_after() {
        let (ws, clip) = makeWorkspaceWithOneClip()
        var after = clip
        after.tags = ["shot"]
        ws.project.clips[0] = after
        ws.commitClipEdit(id: clip.id, before: clip, after: after)
        ws.undo()

        ws.redo()

        XCTAssertEqual(ws.project.clips[0].tags, ["shot"])
        XCTAssertEqual(ws.undoStack.count, 1)
        XCTAssertTrue(ws.redoStack.isEmpty)
    }

    func test_new_commit_clears_redo_stack() {
        let (ws, clip) = makeWorkspaceWithOneClip()
        var v1 = clip; v1.tags = ["a"]
        ws.project.clips[0] = v1
        ws.commitClipEdit(id: clip.id, before: clip, after: v1)
        ws.undo()
        XCTAssertEqual(ws.redoStack.count, 1)

        var v2 = clip; v2.tags = ["b"]
        ws.project.clips[0] = v2
        ws.commitClipEdit(id: clip.id, before: clip, after: v2)

        XCTAssertTrue(ws.redoStack.isEmpty)
        XCTAssertEqual(ws.undoStack.count, 1)
    }

    func test_undo_stack_cap_drops_oldest() {
        let (ws, clip) = makeWorkspaceWithOneClip()
        // Push 105 unique edits.
        var current = clip
        for i in 0..<105 {
            var next = current
            next.name = "edit \(i)"
            ws.project.clips[0] = next
            ws.commitClipEdit(id: clip.id, before: current, after: next)
            current = next
        }
        XCTAssertEqual(ws.undoStack.count, Workspace.undoStackCap)
        // The very first edit ("edit 0") fell off the bottom; the most
        // recent edit ("edit 104") is on top.
        if case let .editClip(_, _, after) = ws.undoStack.last! {
            XCTAssertEqual(after.name, "edit 104")
        } else {
            XCTFail("Expected .editClip on top of undo stack")
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach test -only-testing:AppTests/UndoStackTests`
Expected: FAIL — "value of type 'Workspace' has no member 'commitClipEdit'" / "no member 'undo'" / "no member 'redo'".

- [ ] **Step 3: Implement `commitClipEdit`, `undo`, `redo` on `Workspace`**

In `apple/App/Models/Workspace.swift`, add the following methods. Place them right after the stack property declarations from Task 1 (just below `var canRedo: Bool { !redoStack.isEmpty }`):

```swift
    /// Push a single field-edit step onto the undo stack. Called by the
    /// inspector on focus-loss for any of name / tags / notes when the
    /// snapshot taken at focus-gain differs from the current clip. Skipped
    /// when before == after so an unchanged focus session doesn't pollute
    /// the stack. Any redo branch is dropped — making a new edit always
    /// throws away forward history.
    func commitClipEdit(id: Clip.ID, before: Clip, after: Clip) {
        guard before != after else { return }
        pushUndo(.editClip(id: id, before: before, after: after))
    }

    /// Undo the most recent stack entry. Quietly no-ops when the stack is
    /// empty so menu wiring doesn't have to gate the call. Save errors
    /// during the inverse apply are swallowed (project file may be on a
    /// read-only volume mid-flight); the in-memory state is what the user
    /// sees and is what counts for undo correctness.
    func undo() {
        guard let action = undoStack.popLast() else { return }
        applyInverse(of: action)
        redoStack.append(action)
    }

    /// Redo the most recent undone entry. Symmetric to `undo()`.
    func redo() {
        guard let action = redoStack.popLast() else { return }
        applyForward(of: action)
        undoStack.append(action)
    }

    /// Push helper: enforces the stack cap and clears redo. Eviction of a
    /// prior `.deleteClip` (so the on-disk trash invariant holds) is
    /// handled by `deleteClip(id:)` itself; this helper only handles the
    /// length cap.
    private func pushUndo(_ action: UndoAction) {
        undoStack.append(action)
        if undoStack.count > Self.undoStackCap {
            undoStack.removeFirst(undoStack.count - Self.undoStackCap)
        }
        redoStack.removeAll()
    }

    private func applyInverse(of action: UndoAction) {
        switch action {
        case let .editClip(id, before, _):
            if let i = project.clips.firstIndex(where: { $0.id == id }) {
                project.clips[i] = before
                invalidatePreviewCache(for: id)
                try? saveProject()
            }
        case .deleteClip:
            // Filled in by Task 3 once the unified delete flow lands.
            break
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
        case .deleteClip:
            // Filled in by Task 3.
            break
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach test -only-testing:AppTests/UndoStackTests`
Expected: PASS — all six tests green.

- [ ] **Step 5: Commit**

```bash
git add apple/Tests/AppTests/UndoStackTests.swift apple/App/Models/Workspace.swift
git commit -m "feat(workspace): commitClipEdit + undo/redo for clip field edits

Adds commitClipEdit(id:before:after:) and unified undo()/redo() that
walk the editClip case. Cap enforced at 100 entries; redo cleared on
new commit. Delete handling lands in the next commit."
```

---

## Task 3: TDD migrate `deleteClip` to the unified stack and finish `.deleteClip` undo/redo

**Files:**
- Modify: `apple/App/Models/Workspace.swift`
- Modify: `apple/Tests/AppTests/UndoStackTests.swift`

- [ ] **Step 1: Write the failing tests**

Add a helper at the top of `UndoStackTests.swift` (above the existing helper) for tests that need a real folder for trash:

```swift
    /// Helper: a Workspace with a temp project folder and one clip whose
    /// recording file actually exists on disk. Used by delete/undelete
    /// tests that exercise the trash directory.
    private func makeWorkspaceWithFolderAndOneClip() throws -> (Workspace, Clip, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("UndoStackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let recordingsDir = folder.appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        let filename = "clip-\(UUID()).mov"
        let recordingURL = recordingsDir.appendingPathComponent(filename)
        try Data([0x00]).write(to: recordingURL)

        let ws = Workspace()
        ws.folder = folder
        let clip = Clip(
            id: UUID(),
            name: "Folderful",
            sourceIndex: 0,
            startSourceSeconds: 0,
            recordingDuration: 1.0,
            recordingFilename: filename,
            sortIndex: 0
        )
        ws.project.clips = [clip]
        try ws.saveProject()
        return (ws, clip, folder)
    }
```

Add new test methods at the bottom of the class:

```swift
    func test_deleteClip_pushes_deleteClip_action() throws {
        let (ws, clip, folder) = try makeWorkspaceWithFolderAndOneClip()
        defer { try? FileManager.default.removeItem(at: folder) }

        try ws.deleteClip(id: clip.id)

        XCTAssertEqual(ws.undoStack.count, 1)
        if case .deleteClip = ws.undoStack.last! {
            // ok
        } else {
            XCTFail("Expected .deleteClip on top of undo stack")
        }
        XCTAssertTrue(ws.project.clips.isEmpty)
    }

    func test_undo_deleteClip_restores_clip_and_recording() throws {
        let (ws, clip, folder) = try makeWorkspaceWithFolderAndOneClip()
        defer { try? FileManager.default.removeItem(at: folder) }
        let recordingURL = folder
            .appendingPathComponent("recordings")
            .appendingPathComponent(clip.recordingFilename)
        try ws.deleteClip(id: clip.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordingURL.path))

        ws.undo()

        XCTAssertEqual(ws.project.clips.count, 1)
        XCTAssertEqual(ws.project.clips[0].id, clip.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordingURL.path))
        XCTAssertTrue(ws.undoStack.isEmpty)
        XCTAssertEqual(ws.redoStack.count, 1)
    }

    func test_redo_deleteClip_re_deletes_clip() throws {
        let (ws, clip, folder) = try makeWorkspaceWithFolderAndOneClip()
        defer { try? FileManager.default.removeItem(at: folder) }
        try ws.deleteClip(id: clip.id)
        ws.undo()

        ws.redo()

        XCTAssertTrue(ws.project.clips.isEmpty)
        XCTAssertEqual(ws.undoStack.count, 1)
        XCTAssertTrue(ws.redoStack.isEmpty)
    }

    func test_second_delete_evicts_prior_delete_from_undo_stack() throws {
        let (ws, clipA, folder) = try makeWorkspaceWithFolderAndOneClip()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Add a second clip with its own recording file.
        let filenameB = "clip-\(UUID()).mov"
        let recordingsDir = folder.appendingPathComponent("recordings")
        let recordingB = recordingsDir.appendingPathComponent(filenameB)
        try Data([0x00]).write(to: recordingB)
        let clipB = Clip(
            id: UUID(), name: "B", sourceIndex: 0, startSourceSeconds: 0,
            recordingDuration: 1.0, recordingFilename: filenameB, sortIndex: 1
        )
        ws.project.clips.append(clipB)
        try ws.saveProject()

        try ws.deleteClip(id: clipA.id)
        try ws.deleteClip(id: clipB.id)

        // Only one .deleteClip exists across both stacks (B's). A's prior
        // entry was evicted from undoStack and its trash file shredded.
        let allDeletes = (ws.undoStack + ws.redoStack).filter { action in
            if case .deleteClip = action { return true } else { return false }
        }
        XCTAssertEqual(allDeletes.count, 1)
        // A's trashed recording is gone; B's is in trash.
        let trashA = recordingsDir.appendingPathComponent(".trash")
            .appendingPathComponent(clipA.recordingFilename)
        let trashB = recordingsDir.appendingPathComponent(".trash")
            .appendingPathComponent(filenameB)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashB.path))
    }

    func test_delete_evicts_a_redo_stack_delete_too() throws {
        let (ws, clipA, folder) = try makeWorkspaceWithFolderAndOneClip()
        defer { try? FileManager.default.removeItem(at: folder) }
        let filenameB = "clip-\(UUID()).mov"
        let recordingsDir = folder.appendingPathComponent("recordings")
        try Data([0x00]).write(to: recordingsDir.appendingPathComponent(filenameB))
        let clipB = Clip(
            id: UUID(), name: "B", sourceIndex: 0, startSourceSeconds: 0,
            recordingDuration: 1.0, recordingFilename: filenameB, sortIndex: 1
        )
        ws.project.clips.append(clipB)
        try ws.saveProject()

        // Delete A, then undo → A's deleteClip lives on redoStack.
        try ws.deleteClip(id: clipA.id)
        ws.undo()
        // Now delete B. Since A is on redoStack, eviction must reach into
        // redoStack, drop A's entry, shred A's trash file.
        try ws.deleteClip(id: clipB.id)

        let trashA = recordingsDir.appendingPathComponent(".trash")
            .appendingPathComponent(clipA.recordingFilename)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashA.path))
        let allDeletes = (ws.undoStack + ws.redoStack).filter { action in
            if case .deleteClip = action { return true } else { return false }
        }
        XCTAssertEqual(allDeletes.count, 1)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach test -only-testing:AppTests/UndoStackTests`
Expected: FAIL — current `deleteClip` still uses `lastDeletedClip`, doesn't push to `undoStack`. Also `applyInverse(.deleteClip)` is still a no-op stub.

- [ ] **Step 3: Replace `deleteClip` body and the stubbed `.deleteClip` cases**

In `apple/App/Models/Workspace.swift`, find the existing `deleteClip(id:)` method and replace its body with the version that pushes onto the unified stack and evicts any prior delete:

```swift
    /// Removes a clip from the project: drops the in-memory entry, MOVES
    /// the underlying recording into `recordings/.trash/`, invalidates the
    /// preview cache, and persists. Pushes a `.deleteClip` action onto the
    /// undo stack. The on-disk trash holds at most one .mov; if a prior
    /// `.deleteClip` exists in either undoStack or redoStack, evict it
    /// (shred its trash file, drop it from whichever stack it lived on)
    /// before pushing the new one. The clip's `sortIndex` gap is left
    /// as-is — `reorderClips(from:to:)` re-numbers on next reorder, and
    /// the sidebar sorts by `sortIndex`-ascending so a gap is invisible.
    func deleteClip(id: Clip.ID) throws {
        guard let idx = project.clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = project.clips[idx]
        invalidatePreviewCache(for: id)

        evictPriorDeleteAction()

        var stash: DeletedClip?
        if let folder {
            let recordingsDir = ProjectStore.recordingsDir(in: folder)
            let recordingURL = recordingsDir.appendingPathComponent(clip.recordingFilename)
            let trashDir = recordingsDir.appendingPathComponent(".trash")
            try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
            let trashedURL = trashDir.appendingPathComponent(clip.recordingFilename)
            if FileManager.default.fileExists(atPath: recordingURL.path) {
                try? FileManager.default.removeItem(at: trashedURL)
                try FileManager.default.moveItem(at: recordingURL, to: trashedURL)
            }
            stash = DeletedClip(clip: clip, trashedRecordingURL: trashedURL)
        }

        project.clips.remove(at: idx)
        try saveProject()

        if let stash {
            pushUndo(.deleteClip(stash))
        }
    }

    /// Walks both stacks looking for an existing `.deleteClip`. If found,
    /// shreds its trash file and removes the entry. Caller is responsible
    /// for then pushing a new delete onto `undoStack`. Idempotent — safe
    /// to call when there's nothing to evict.
    private func evictPriorDeleteAction() {
        let prior: DeletedClip?
        if let i = undoStack.lastIndex(where: { if case .deleteClip = $0 { return true } else { return false } }) {
            if case let .deleteClip(d) = undoStack.remove(at: i) { prior = d } else { prior = nil }
        } else if let i = redoStack.lastIndex(where: { if case .deleteClip = $0 { return true } else { return false } }) {
            if case let .deleteClip(d) = redoStack.remove(at: i) { prior = d } else { prior = nil }
        } else {
            prior = nil
        }
        if let prior {
            try? FileManager.default.removeItem(at: prior.trashedRecordingURL)
        }
    }
```

Also delete the `lastDeletedClip` property and the entire `undoLastDelete()` method now that the unified stack owns the behavior. Find:

```swift
    /// In-memory record of the most-recently-deleted clip, available for
    /// `undoLastDelete()`. Cleared by another delete (which trashes the new
    /// clip and shreds the previous trash file) or by a successful undo.
    /// Not persisted — quitting the app loses the undo. Each new project
    /// open also clears this and shreds the trash directory.
    private(set) var lastDeletedClip: DeletedClip?
```

— delete that entire block.

Find:

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

— delete the whole method (the next call site, in `ContentView`, gets migrated in Task 6).

Now fill in the `.deleteClip` cases in `applyInverse` and `applyForward`. Replace:

```swift
        case .deleteClip:
            // Filled in by Task 3 once the unified delete flow lands.
            break
```

…in `applyInverse` with:

```swift
        case let .deleteClip(stash):
            // Restore: move .mov out of trash and re-insert the clip at
            // its original sortIndex slot. Tolerate a missing trash file
            // (someone may have cleaned it externally) — metadata still
            // restores. Re-selection of the restored clip is done by the
            // caller in ContentView.
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
```

And replace the same stub in `applyForward` with a re-delete:

```swift
        case let .deleteClip(stash):
            // Re-apply the delete: remove from project, move .mov back
            // into trash. We don't need to mutate the action's stored
            // DeletedClip — the trashedRecordingURL is the same path
            // we'll re-occupy here.
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
```

Note: with `lastDeletedClip` removed, the only other reference inside `Workspace.swift` is in `openProject(...)`. Find:

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
        undoStack.removeAll()
        redoStack.removeAll()
        shredTrashDirectory()
```

`ContentView.swift` will still reference `lastDeletedClip` and `undoLastDelete` at this point — that's expected; Task 6 migrates those call sites and the project compiles again. Don't try to build between Tasks 3 and 6 yet — they're a coupled rewrite. (Tests in Task 4 / 5 below don't go through the app target's `ContentView`, so we can verify the model without compiling the UI code path. Actually, AppTests does compile the whole app target — see Step 4.)

- [ ] **Step 4: Migrate `ContentView`'s call sites in the same edit (so the target builds)**

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
    /// in either case. When the popped action is `.deleteClip`, re-selects
    /// the restored clip so the user sees what came back; for `.editClip`
    /// we leave selection alone (the user may have moved on to a different
    /// clip in the interim).
    private var undoHandler: (() -> Void)? {
        guard workspace.canUndo else { return nil }
        if appMode == .recording || appMode == .recordingStarting { return nil }
        return {
            let top = workspace.undoStack.last
            workspace.undo()
            if case let .deleteClip(stash) = top {
                selectedClipID = stash.clip.id
            }
        }
    }

    /// Handler published to the Clip ▸ Redo (⇧⌘Z) menu. Same gating
    /// rules as undo. When the redo'd action is `.deleteClip`, clears
    /// selection if the deleted clip was selected, mirroring how a
    /// fresh delete behaves in `requestDeleteClip`.
    private var redoHandler: (() -> Void)? {
        guard workspace.canRedo else { return nil }
        if appMode == .recording || appMode == .recordingStarting { return nil }
        return {
            let top = workspace.redoStack.last
            workspace.redo()
            if case let .deleteClip(stash) = top, selectedClipID == stash.clip.id {
                selectedClipID = nil
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

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach test -only-testing:AppTests/UndoStackTests`
Expected: PASS — all eleven tests green (six from Task 2 plus five new ones).

- [ ] **Step 6: Build the app to verify nothing else broke**

Run: `apple/scripts/run.sh`
Expected: build succeeds, app launches. Manual check: select a clip, press Cmd+Delete to delete it; Cmd+Z to undo (clip comes back, gets re-selected). Cmd+Z and Shift+Cmd+Z appear in the Clip menu.

- [ ] **Step 7: Commit**

```bash
git add apple/App/Models/Workspace.swift apple/App/Views/ClipCommands.swift apple/App/ContentView.swift apple/Tests/AppTests/UndoStackTests.swift
git commit -m "feat(workspace): unify delete-clip undo into UndoAction stack

Replaces lastDeletedClip + undoLastDelete() with the new undoStack /
redoStack and a deleteClip action that evicts any prior delete from
either stack so the on-disk trash invariant (one .mov) holds. Renames
the menu item from \"Undo Delete Clip\" to \"Undo\" and adds \"Redo\"
(⇧⌘Z). FocusedValueKey renamed undoLastDelete → undoAction + redoAction."
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

- [ ] **Step 2: Replace `EditorView` body with focus-tracked version**

In `apple/App/Views/ClipInspector.swift`, replace the entire `private struct EditorView` (lines 71–115) with:

```swift
private struct EditorView: View {
    let workspace: Workspace
    @Binding var clip: Clip
    let suggestions: Set<String>

    /// Tracks which non-tag field has keyboard focus. nil = nothing
    /// focused (or tags are focused — those are tracked separately via
    /// TagField's onFocusChange callback because TagField owns an
    /// internal @FocusState that the outer .focused(...) modifier
    /// doesn't reach).
    @FocusState private var focusedField: Field?
    /// Whether TagField currently has focus, surfaced via its
    /// onFocusChange callback. Single source of truth for tag focus.
    @State private var tagsFocused: Bool = false
    /// Snapshot of the clip taken when ANY field (name / tags / notes)
    /// gained focus. Cleared on focus-loss after pushing one
    /// commitClipEdit. nil = no field is currently being edited.
    @State private var snapshotAtFocus: Clip?

    private enum Field: Hashable { case name, notes }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clip").font(.headline)

            Group {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("Clip name", text: $clip.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .name)
                    .onSubmit { try? workspace.saveProject() }
            }

            Group {
                Text("Tags").font(.caption).foregroundStyle(.secondary)
                TagField(
                    tags: $clip.tags,
                    suggestions: suggestions,
                    onCommit: { try? workspace.saveProject() },
                    onFocusChange: { focused in tagsFocused = focused }
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
                    .focused($focusedField, equals: .notes)
            }

            Spacer()
        }
        .onChange(of: anyFieldFocused) { oldValue, newValue in
            // Focus-gain (no field → some field): snapshot the clip so
            // we can compute a single before/after for the editing
            // session.
            if !oldValue, newValue {
                snapshotAtFocus = clip
                return
            }
            // Focus-loss (some field → no field): commit one undo step
            // covering the whole session. Notes save also lands here
            // (replaces the old per-keystroke .onChange(clip.notes)
            // write — same end state, far less I/O).
            if oldValue, !newValue, let before = snapshotAtFocus {
                if before != clip {
                    workspace.commitClipEdit(id: clip.id, before: before, after: clip)
                    try? workspace.saveProject()
                }
                snapshotAtFocus = nil
            }
        }
    }

    /// True when ANY of the three fields has keyboard focus. Computed so
    /// onChange fires on the union transition (no field → some field
    /// and back), not on intermediate hops between fields. That way
    /// tabbing from name → tags → notes is one editing session, not
    /// three.
    private var anyFieldFocused: Bool {
        focusedField != nil || tagsFocused
    }
}
```

Subtle correctness notes:
1. `TagField`'s `onCommit` still calls `saveProject()` on Enter so that committing without ever losing focus (e.g., user types tags, presses Enter, then quits the app) still persists. The focus-loss path then no-ops because `commitClipEdit` early-returns when `before == after`.
2. Field-to-field transitions (e.g., user clicks from name into tags) briefly toggle `anyFieldFocused` — `focusedField` becomes nil for one runloop tick before TagField reports `tagsFocused = true`. SwiftUI's `onChange(of:)` coalesces same-value writes, but the order of focus-out/focus-in is not guaranteed. If this turns out to flicker (testable: tab through fields, check `Workspace.undoStack.count`), wrap the snapshot reset in a one-runloop debounce. Verify in Step 3 manual smoke and only add the debounce if needed — YAGNI otherwise.

- [ ] **Step 3: Build and smoke-test the field-edit flow**

Run: `apple/scripts/run.sh`

Manual smoke test:
- Open a project with at least one clip.
- Click the clip. Type a tag in the Tags field. Click outside the field.
- Open the Clip menu — "Undo" is enabled.
- Press Cmd+Z — the tag disappears.
- Press Shift+Cmd+Z — the tag comes back.
- Repeat with Name and Notes.

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

- [ ] **Step 1: Run the full app test suite**

Run: `xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach test -only-testing:AppTests`
Expected: ALL PASS — `RecordingZoomCaptureTests` (existing) + `UndoStackTests` (new).

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
