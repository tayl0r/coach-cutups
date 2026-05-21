import SwiftUI

/// FocusedValue keys for ContentView → App-level command bridge. When
/// ContentView is focused (the typical case for our single-window app), it
/// publishes its `requestDeleteClip` handler here so the top-level Clip
/// menu can fire it. When no clip is selected (or we're recording), the
/// handler is `nil` and the menu item auto-disables.
private struct DeleteSelectedClipKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct UndoActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct RedoActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct OpenMatchSettingsKey: FocusedValueKey {
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
    var openMatchSettings: (() -> Void)? {
        get { self[OpenMatchSettingsKey.self] }
        set { self[OpenMatchSettingsKey.self] = newValue }
    }
}

/// Top-level Clip menu in the macOS menu bar. Currently exposes "Delete
/// Clip" (also accessible via the sidebar's right-click context menu).
/// Room to grow: Rename Clip, Reveal Recording in Finder, Duplicate, etc.
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

/// Top-level Project menu. ContentView publishes `openMatchSettings`
/// via `@FocusedValue` — `nil` (menu disabled) until a project folder
/// is opened. The handler flips the inspector to settings mode in
/// place (was: presented a modal sheet).
struct ProjectCommands: Commands {
    @FocusedValue(\.openMatchSettings) private var openMatchSettings

    var body: some Commands {
        CommandMenu("Project") {
            Button("Match Setup…") { openMatchSettings?() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(openMatchSettings == nil)
        }
    }
}
