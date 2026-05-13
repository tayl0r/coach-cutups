# Back-to-source affordance, robust Esc, and project-wide undo/redo

## Goal

Make it cheap to bail out of a clip preview, and recover edits the user
didn't mean to lose.

Three user-visible changes, one underlying mechanism:

1. **BACK button in the toolbar** — a large, top-left affordance that
   exits clip preview back to source.
2. **Esc reliably exits preview** — even when focus is sitting in an
   inspector text field. Today the global key monitor gates on
   `firstResponder is NSText` and lets Esc fall through to AppKit's text
   editing, leaving the user "stuck" in a clip until they click outside
   the field first.
3. **Cmd+Z / Shift+Cmd+Z** — project-wide undo/redo covering tag, name,
   notes, and delete-clip edits. One commit (focus-loss / Enter) is one
   undo step. Cap 100 steps.

## Non-goals

- Per-keystroke (NSUndoManager-style) undo within text fields.
- Persisting undo history across project switches or app launches —
  matches today's `lastDeletedClip` lifetime.
- Undo for source-video add/remove/relink/reorder, drawing strokes,
  zoom changes, or volume preferences. (Those don't go through the
  inspector and aren't on the user's stated path.)
- Undoing more than one clip-delete at a time. The trash directory
  holds one .mov file as it does today; the new stacks enforce the
  same invariant.

## UX

### Toolbar layout (`ContentView.swift`)

| Slot          | Today                                          | After                                                     |
|---------------|------------------------------------------------|-----------------------------------------------------------|
| `.navigation` | (empty)                                        | BACK button — `chevron.left` + "Source" label, large size |
| `.principal`  | ZoomIndicator + Auto-clear toggle + Clear All  | (unchanged)                                               |
| `.primaryAction` | Export button                               | "Coach Cutups" title label, then Export button           |

- BACK is hidden (not just disabled) outside `.previewClip(_)` /
  `.previewLoading(_)`. Action: existing `handleClosePreview`.
- The window's `navigationTitle("Coach Cutups")` /
  `navigationSubtitle(buildSubtitle)` stay as-is so the macOS window
  chrome continues to show build SHA + timestamp.

### Esc behavior

- Today: `KeyCommandView`'s window-scoped `NSEvent` monitor returns the
  event unhandled when any `NSText` is first responder. That blocks Esc
  in preview mode while the user is editing a tag/name/notes field.
- After: when `appMode` is `.previewClip(_)` or `.previewLoading(_)`,
  Esc bypasses the text-field guard and calls `onClosePreview`.
- The `TagField`'s autocomplete popover keeps its existing
  `.onKeyPress(.escape)` handler, which returns `.handled` only while
  the popover is visible. SwiftUI consumes that event before the AppKit
  monitor sees it, so popover-dismiss still works.
- Pending field edits aren't dropped: `TagField` commits on
  `onChange(isFocused)`; the name `TextField` commits on `.onSubmit`;
  notes `TextEditor` writes through every keystroke today.

## Undo / redo model

The mechanism splits along the existing package boundary:

- **`VideoCoachCore.UndoController`** (new struct) owns the stack
  state, push/pop semantics, the cap, and the delete-eviction
  invariant. Pure data; no UI, no IO. Independently testable in
  `VideoCoachCoreTests` (where Workspace tests can't reach today
  because Workspace transitively imports `Libmpv`).
- **`Workspace`** owns the controller, calls into it, and applies
  actions — the part that actually mutates `project.clips`,
  invalidates the AVPlayer preview cache, and moves recording files
  in and out of `.trash/`.

This matches Apple's "the undo stack should be associated with the
data, not the window" guidance: stack state lives next to `Project`
and `Clip` in the package; the UI-coupled bits stay in the app target.

### `UndoController` (in `apple/VideoCoachCore/Sources/VideoCoachCore/UndoController.swift`)

```swift
public struct DeletedClip: Sendable {
    public let clip: Clip
    public let trashedRecordingURL: URL
    public init(clip: Clip, trashedRecordingURL: URL) { ... }
}

public enum UndoAction: Sendable {
    case editClip(id: Clip.ID, before: Clip, after: Clip)
    case deleteClip(DeletedClip)
}

public struct UndoController {
    public private(set) var undoStack: [UndoAction] = []   // newest last
    public private(set) var redoStack: [UndoAction] = []   // newest last
    public static let stackCap = 100

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Push a non-delete action onto the undo stack. Trims to cap;
    /// clears redo. Use `pushDelete(_:)` for `.deleteClip` — it carries
    /// extra eviction semantics tied to the on-disk trash invariant.
    public mutating func pushEdit(_ action: UndoAction) { ... }

    /// Push a delete onto the undo stack. Returns any prior delete
    /// found in either stack (so the caller can shred its trash file).
    /// Trims to cap; clears redo.
    public mutating func pushDelete(_ stash: DeletedClip) -> DeletedClip?

    /// Pop top of undo stack onto redo. Returns the popped action so
    /// the caller can apply its inverse.
    public mutating func popForUndo() -> UndoAction?

    /// Pop top of redo stack onto undo. Returns the popped action so
    /// the caller can apply it forward.
    public mutating func popForRedo() -> UndoAction?

    public mutating func clearAll() { ... }
}
```

**Invariant:** at most one `.deleteClip` exists across both stacks
combined. `pushDelete` enforces this by walking both stacks for an
existing `.deleteClip` and removing it before appending the new one
(returning the evicted value). The on-disk trash directory holds at
most one `.mov`, matching this invariant.

### Workspace integration

`Workspace` adopts the controller and gains application logic:

- Replaces `private(set) var lastDeletedClip: DeletedClip?` with
  `private var history = UndoController()`.
- Removes `func undoLastDelete()` — superseded by `undo()`.
- Forwards `canUndo`, `canRedo` from the controller.
- `commitClipEdit(id:before:after:)`: skip when `before == after`,
  else `history.pushEdit(.editClip(id, before, after))`.
- `deleteClip(id:)`: build a `DeletedClip`, call
  `history.pushDelete(stash)`. If a prior delete is returned (evicted),
  shred its trash file. (File IO stays in Workspace.)
- `undo()`: `history.popForUndo()` → if `.editClip`, restore `before`
  in `project.clips[i]`, save, invalidate preview cache. If
  `.deleteClip(stash)`, move file out of trash and re-insert metadata
  at original `sortIndex` slot.
- `redo()`: symmetric — `popForRedo()` then apply the forward.
- `openProject(...)` calls `history.clearAll()` (extends today's
  `lastDeletedClip = nil`). Trash shred stays as-is.

### Lifecycle

- During recording (`appMode == .recording` or `.recordingStarting`)
  the menu handlers are nil — Cmd+Z and Shift+Cmd+Z auto-disable.
- Selection: undo / redo always selects the affected clip. For
  `.deleteClip` undo this matches the existing restore-then-select
  behavior. For `.editClip` undo we also select — without this, an
  undo on a clip that isn't currently selected is silent (the model
  reverts but nothing visibly changes), and the user has no feedback
  to tell whether Cmd+Z did anything. The cost — being teleported to
  the affected clip — is preferable to invisible state changes.
  Redoing a `.deleteClip` clears selection if the deleted clip was
  selected (matches the fresh-delete behavior).

## Inspector changes (`ClipInspector.swift`)

`EditorView` switches each field from "save on every change" to
"snapshot on focus-gain, commit one undo step on focus-loss":

- Add `@State private var snapshotAtFocus: Clip?` to `EditorView`.
- Wrap each of the three fields with `.focused($fieldFocus, equals: ...)`
  using a `@FocusState` enum.
- On focus-gain: capture `snapshotAtFocus = clip`.
- On focus-loss: if `snapshotAtFocus != clip`,
  `workspace.commitClipEdit(id: clip.id, before: snapshotAtFocus!, after: clip)`.
  (Project save happens inside `commitClipEdit`.)

Notes-specific change: today's `onChange(of: clip.notes)` is removed.
Notes still write through to `clip.notes` via the binding (so live
display updates), but disk save deferred until focus-loss commit. This
is fine — the project file is small JSON and writing once per editing
session is preferable to once per keystroke.

TagField's existing `onCommit` parameter is unchanged; it remains the
trigger for the field-level focus-loss commit.

## Menu wiring (`ClipCommands.swift`)

- New `FocusedValueKey`s: `undo`, `redo` (each `() -> Void`).
- ContentView publishes computed `undoHandler` / `redoHandler` —
  nil while recording or when respective stack is empty.
- "Clip" menu replaces today's "Undo Delete Clip" with:
  - **Undo** — `Cmd+Z` — calls `undoHandler`, disabled when nil.
  - **Redo** — `Shift+Cmd+Z` — calls `redoHandler`, disabled when nil.
- The standard macOS Edit menu is not modified — putting these in
  the existing custom Clip menu keeps consistency with the
  delete-clip command which already lives there.

## File-by-file change summary

- `apple/VideoCoachCore/Sources/VideoCoachCore/UndoController.swift` (new)
  - `public struct DeletedClip` (moved from `Workspace`, made
    `public`).
  - `public enum UndoAction` with `.editClip` / `.deleteClip` cases.
  - `public struct UndoController` with `undoStack`, `redoStack`,
    `pushEdit`, `pushDelete` (returns evicted `DeletedClip?`),
    `popForUndo`, `popForRedo`, `clearAll`, `canUndo`, `canRedo`.
- `apple/VideoCoachCore/Tests/VideoCoachCoreTests/UndoControllerTests.swift` (new)
  - Covers push/pop, cap-and-trim, redo-clear on new push, eviction
    of prior `.deleteClip` from either stack, `clearAll`.
- `apple/App/Models/Workspace.swift`
  - Replaces `private(set) var lastDeletedClip: DeletedClip?` with
    `private var history = UndoController()`.
  - Adds forwarding `canUndo`, `canRedo`.
  - Adds `commitClipEdit`, `undo()`, `redo()` — these own the
    application logic (mutate `project.clips`, invalidate preview
    cache, file IO for trash).
  - Removes `undoLastDelete()` (superseded by `undo()`).
  - `deleteClip(id:)` calls `history.pushDelete(...)`; shreds the
    evicted trash file if any.
  - `openProject(...)` calls `history.clearAll()`.
  - Removes the local `struct DeletedClip` declaration (now imported
    from `VideoCoachCore`).
- `apple/App/Views/KeyCommandView.swift`
  - In preview modes, Esc bypasses the `NSText` first-responder guard.
- `apple/App/ContentView.swift`
  - Toolbar restructured (.navigation BACK, .primaryAction title +
    Export).
  - `@FocusedValue` publishes for `undo`/`redo` replacing today's
    `undoLastDelete`.
- `apple/App/Views/ClipInspector.swift`
  - `EditorView` adds per-field focus tracking with `.onDisappear`
    flush; commits on focus-loss.
  - Removes per-keystroke notes save.
- `apple/App/Views/TagField.swift`
  - Add `onFocusChange: (Bool) -> Void` parameter (default no-op).
- `apple/App/Views/ClipCommands.swift`
  - Replace "Undo Delete Clip" with "Undo" + "Redo".

## Testing

- **Unit tests (`VideoCoachCoreTests/UndoControllerTests.swift`):**
  cover push/pop semantics, cap eviction, redo-clear on new push,
  delete-eviction invariant across both stacks, `clearAll`. These are
  the parts where bugs hide.
- **Workspace integration:** the action-application logic
  (mutate clips, invalidate preview cache, trash file IO) is
  intentionally NOT unit-tested — it requires the app target's
  `Libmpv` cascade. Verified instead by the manual smoke test in the
  final task: tag/name/notes round-trip, delete + restore, two
  deletes evicting the older, and recording-mode menu disable.
- UI behaviors (Esc in preview while a field has focus, BACK button
  visibility transitions) are verified manually.
