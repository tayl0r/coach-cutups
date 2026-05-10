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

    /// Push a delete onto the undo stack. Returns any prior delete
    /// found in either stack, so the caller can shred its trash file
    /// (the controller doesn't do file I/O). Trims to cap; clears
    /// redo.
    public mutating func pushDelete(_ stash: DeletedClip) -> DeletedClip? {
        let evicted = evictPriorDelete()
        undoStack.append(.deleteClip(stash))
        if undoStack.count > Self.stackCap {
            undoStack.removeFirst(undoStack.count - Self.stackCap)
        }
        redoStack.removeAll()
        return evicted
    }

    /// Pop top of `undoStack`, push it onto `redoStack`, and return
    /// the popped action so the caller can apply its inverse. Returns
    /// nil when the stack is empty.
    public mutating func popForUndo() -> UndoAction? {
        guard let action = undoStack.popLast() else { return nil }
        redoStack.append(action)
        return action
    }

    /// Pop top of `redoStack`, push it onto `undoStack`, and return
    /// the popped action so the caller can apply it forward. Returns
    /// nil when the stack is empty.
    public mutating func popForRedo() -> UndoAction? {
        guard let action = redoStack.popLast() else { return nil }
        undoStack.append(action)
        return action
    }

    /// Drop everything. Called by `Workspace.openProject(...)` so undo
    /// state never carries across project switches.
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
}
