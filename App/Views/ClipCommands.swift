import SwiftUI

/// FocusedValue keys for ContentView → App-level command bridge. When
/// ContentView is focused (the typical case for our single-window app), it
/// publishes its `requestDeleteClip` handler here so the top-level Clip
/// menu can fire it. When no clip is selected (or we're recording), the
/// handler is `nil` and the menu item auto-disables.
private struct DeleteSelectedClipKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var deleteSelectedClip: (() -> Void)? {
        get { self[DeleteSelectedClipKey.self] }
        set { self[DeleteSelectedClipKey.self] = newValue }
    }
}

/// Top-level Clip menu in the macOS menu bar. Currently exposes "Delete
/// Clip" (also accessible via the sidebar's right-click context menu).
/// Room to grow: Rename Clip, Reveal Recording in Finder, Duplicate, etc.
struct ClipCommands: Commands {
    @FocusedValue(\.deleteSelectedClip) private var deleteHandler

    var body: some Commands {
        CommandMenu("Clip") {
            Button("Delete Clip…") { deleteHandler?() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(deleteHandler == nil)
        }
    }
}
