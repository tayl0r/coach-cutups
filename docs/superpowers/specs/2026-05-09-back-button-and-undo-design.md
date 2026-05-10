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

### Stack types (in `Workspace.swift`)

```swift
enum UndoAction {
    case editClip(id: Clip.ID, before: Clip, after: Clip)
    case deleteClip(DeletedClip)
}

private var undoStack: [UndoAction] = []   // newest at end
private var redoStack: [UndoAction] = []   // newest at end
private static let undoStackCap = 100
```

**Invariant:** at most one `.deleteClip` exists across both stacks
combined. Matches the existing trash-of-one constraint; eviction
(below) preserves it.

### Pushes

- **Field-edit commit (new):** `Workspace.commitClipEdit(id:before:after:)`
  called by `EditorView` on each field's focus-loss when
  `before != after`. Pushes `.editClip(id, before, after)`. Trims
  `undoStack` to cap by dropping from the front. Clears `redoStack`.
- **`deleteClip(id:)` (existing path):** before stashing, walk
  `undoStack ∪ redoStack` for an existing `.deleteClip`. If found,
  shred its trash file and drop it from whichever stack it lived on.
  Then push the new `.deleteClip(DeletedClip(...))` onto `undoStack`,
  trim to cap, clear `redoStack`. The legacy
  `lastDeletedClip` property is removed; `undoLastDelete()` is removed.

### Undo (Cmd+Z)

- Pop top of `undoStack`. Apply inverse:
  - `.editClip(id, before, after)`: replace `project.clips[i]` with
    `before`, `saveProject()`, `invalidatePreviewCache(for: id)` so a
    re-select rebuilds preview from restored events. (Edits to
    `events` aren't reachable from the inspector today, but the cache
    invalidation costs nothing and keeps the contract simple.)
  - `.deleteClip(stash)`: same flow as today's `undoLastDelete` —
    move file from trash, re-insert metadata at original sortIndex,
    `saveProject()`, return restored id so caller can re-select.
- Push the popped action to `redoStack`.

### Redo (Shift+Cmd+Z)

- Pop top of `redoStack`. Apply forward:
  - `.editClip(id, before, after)`: replace `project.clips[i]` with
    `after`, `saveProject()`, invalidate preview cache.
  - `.deleteClip(stash)`: re-run the delete (move file to trash,
    remove metadata).
- Push back to `undoStack`.

### Lifecycle

- `openProject(...)` clears `undoStack` and `redoStack` (extends
  today's `lastDeletedClip = nil`). Trash shred stays as-is.
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

- `apple/App/ContentView.swift`
  - Toolbar restructured (.navigation BACK, .primaryAction title +
    Export).
  - `@FocusedValue` publishes for `undo`/`redo` replacing today's
    `undoLastDelete`.
- `apple/App/Views/KeyCommandView.swift`
  - In preview modes, Esc bypasses the `NSText` first-responder guard.
- `apple/App/Models/Workspace.swift`
  - Add `UndoAction`, `undoStack`, `redoStack`.
  - Add `commitClipEdit`, `undo()`, `redo()`,
    `canUndo`, `canRedo`, eviction helper.
  - Remove `lastDeletedClip` and `undoLastDelete()` (rolled into the
    unified stack).
  - `deleteClip` pushes `.deleteClip` action; trash-eviction uses the
    new helper.
  - `openProject` clears both stacks.
- `apple/App/Views/ClipInspector.swift`
  - `EditorView` adds `@FocusState`, snapshot-on-focus,
    commit-on-blur for all three fields.
  - Removes per-keystroke notes save.
- `apple/App/Views/ClipCommands.swift`
  - Replace "Undo Delete Clip" with "Undo" + "Redo".

## Testing

Existing unit-test surface (Workspace tests cover delete/undelete) is
extended:
- New tests around `Workspace.commitClipEdit` push behavior, undo/redo
  symmetry on `.editClip`, and the "max one delete in stacks combined"
  invariant after eviction.
- Existing `undoLastDelete` tests are migrated to the unified `undo()`
  entry point.

UI behaviors (Esc in preview while a field has focus, BACK button
visibility transitions) are verified manually.
