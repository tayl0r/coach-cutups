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
