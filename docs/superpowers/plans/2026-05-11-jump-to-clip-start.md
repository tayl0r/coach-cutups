# "Jump source video to clip start" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a sidebar right-click action that closes any active preview and seeks the source player to the right-clicked clip's recorded start position, paused.

**Architecture:** Pure UI wiring. New `onJumpToClipStart: (Clip.ID) -> Void` closure on `ClipSidebar` (parallel to the existing `onRequestDeleteClip`). The context menu builder gains a second `Button`; the disable state checks `isRecording` and whether the clip's source is missing. `ContentView.jumpToClipStart(_:)` is the handler — closes the preview via the existing `handleClosePreview` and calls `MPVSourcePlayer.seek(playlistPos:timeSeconds:exact:completion:)` with `exact: true` and an empty completion.

**Tech Stack:** SwiftUI (macOS 14), AppKit, existing `MPVSourcePlayer` seek API. No tests — handler is a 6-line delegate to well-tested code, verified by manual smoke.

**Build command (after every Swift edit):**
```
/Users/taylor/dev/coach-cutups-2/apple/scripts/run.sh
```

---

## File Structure

**Modify:**
- `apple/App/Views/ClipSidebar.swift` — add `onJumpToClipStart: (Clip.ID) -> Void` prop, add `sourceMissing(for:)` helper, add the new context menu Button.
- `apple/App/ContentView.swift` — add `jumpToClipStart(_:)` method, wire it into the `ClipSidebar(...)` call.

Both files land in **one commit** because adding a non-optional prop to `ClipSidebar` breaks the `ContentView` call site until the new argument is supplied.

**No new files. No Core changes. No new tests.**

---

## Task 1: Wire the context menu item + handler

**Files:**
- Modify: `apple/App/Views/ClipSidebar.swift`
- Modify: `apple/App/ContentView.swift`

- [ ] **Step 1: Add the `onJumpToClipStart` prop and the `sourceMissing` helper to `ClipSidebar`**

In `apple/App/Views/ClipSidebar.swift`, find the property list at the top of `struct ClipSidebar` (around lines 10–15):

```swift
struct ClipSidebar: View {
    @Bindable var workspace: Workspace
    @Binding var selectedClipID: Clip.ID?
    let appMode: AppMode
    @Binding var selectedTagFilter: String?
    var onRequestDeleteClip: (Clip.ID) -> Void
```

Add `onJumpToClipStart` immediately after `onRequestDeleteClip`:

```swift
struct ClipSidebar: View {
    @Bindable var workspace: Workspace
    @Binding var selectedClipID: Clip.ID?
    let appMode: AppMode
    @Binding var selectedTagFilter: String?
    var onRequestDeleteClip: (Clip.ID) -> Void
    /// Right-click action that closes any active preview and seeks the
    /// source player to this clip's recorded start position. Wired by
    /// ContentView; no-op-safe if called with an unknown id.
    var onJumpToClipStart: (Clip.ID) -> Void
```

Then add a small helper near the other private helpers in the struct (e.g., just below the `visibleClips` computed property added in the prior feature):

```swift
    /// True when the clip's source bookmark didn't resolve in this
    /// session. Used to gate the "Jump source video to clip start"
    /// menu item — seeking into an unresolved playlist would silently
    /// fail. Also returns true for an unknown clip id (defensive;
    /// shouldn't happen because the menu is built from the selection).
    private func sourceMissing(for clipID: Clip.ID) -> Bool {
        guard let clip = workspace.project.clips.first(where: { $0.id == clipID })
        else { return true }
        return workspace.missingSourceIndices.contains(clip.sourceIndex)
    }
```

- [ ] **Step 2: Add the menu Button**

Find the existing `.contextMenu(forSelectionType: Clip.ID.self)` block (around lines 46–55):

```swift
            .contextMenu(forSelectionType: Clip.ID.self) { ids in
                if let id = ids.first {
                    Button(role: .destructive) {
                        onRequestDeleteClip(id)
                    } label: {
                        Label("Delete Clip", systemImage: "trash")
                    }
                    .disabled(isRecording)
                }
            }
```

Add a second Button below the Delete one:

```swift
            .contextMenu(forSelectionType: Clip.ID.self) { ids in
                if let id = ids.first {
                    Button(role: .destructive) {
                        onRequestDeleteClip(id)
                    } label: {
                        Label("Delete Clip", systemImage: "trash")
                    }
                    .disabled(isRecording)

                    Button {
                        onJumpToClipStart(id)
                    } label: {
                        Label("Jump source video to clip start",
                              systemImage: "arrowshape.turn.up.left")
                    }
                    .disabled(isRecording || sourceMissing(for: id))
                }
            }
```

- [ ] **Step 3: Add `jumpToClipStart(_:)` to `ContentView`**

In `apple/App/ContentView.swift`, find an appropriate spot for the handler — group it near the other clip-level handlers like `requestDeleteClip` and `handleClosePreview`. Add this method:

```swift
    /// Right-click action from the sidebar: closes any active preview,
    /// then seeks the source player to the clip's recorded start
    /// position. Leaves the source paused — the user presses Space if
    /// they want to play.
    private func jumpToClipStart(_ id: Clip.ID) {
        guard let clip = workspace.project.clips.first(where: { $0.id == id })
        else { return }
        // Close any active preview so the player view swaps back to
        // MPVPlayerView before the seek lands. handleClosePreview also
        // bumps the source player's generation, which is fine — our
        // seek below is a fresh request under the new generation.
        if selectedClipID != nil { handleClosePreview() }
        guard let player = workspace.sourcePlayer else { return }
        player.pause()
        player.seek(
            playlistPos: clip.sourceIndex,
            timeSeconds: clip.startSourceSeconds,
            exact: true,
            completion: {}
        )
    }
```

- [ ] **Step 4: Wire the handler into `ClipSidebar(...)` in `ContentView`**

Find the existing `ClipSidebar(...)` call in `mainSplit` (around line 234, modified by the prior feature to pass `selectedTagFilter`):

```swift
        NavigationSplitView {
            ClipSidebar(
                workspace: workspace,
                selectedClipID: $selectedClipID,
                appMode: appMode,
                selectedTagFilter: $selectedTagFilter,
                onRequestDeleteClip: { id in requestDeleteClip(id) }
            )
```

Add the new closure as the last argument:

```swift
        NavigationSplitView {
            ClipSidebar(
                workspace: workspace,
                selectedClipID: $selectedClipID,
                appMode: appMode,
                selectedTagFilter: $selectedTagFilter,
                onRequestDeleteClip: { id in requestDeleteClip(id) },
                onJumpToClipStart: { id in jumpToClipStart(id) }
            )
```

- [ ] **Step 5: Build to verify**

Run: `/Users/taylor/dev/coach-cutups-2/apple/scripts/run.sh`
Expected: build succeeds.

If the build fails on `onJumpToClipStart` mismatch, double-check Step 1 (the prop name + signature must match what Step 4 passes).

- [ ] **Step 6: Commit**

```bash
cd /Users/taylor/dev/coach-cutups-2
git add apple/App/Views/ClipSidebar.swift apple/App/ContentView.swift
git commit -m "feat(sidebar): right-click 'Jump source video to clip start'

Closes any active preview and seeks MPVSourcePlayer to the clip's
recorded (sourceIndex, startSourceSeconds) with exact=true, paused.
Disabled while recording and when the clip's source bookmark is
unresolved. Uses the existing handleClosePreview path so the player
view swap and generation bump happen exactly as they do for the
Source button in the transport bar."
```

---

## Task 2: Manual smoke

**Files:** none.

- [ ] **Step 1: Run the app and walk through the scenarios**

Run: `/Users/taylor/dev/coach-cutups-2/apple/scripts/run.sh`

1. **Basic seek.** Open a project with at least one clip. Right-click a clip in the sidebar → context menu shows "Delete Clip" + "Jump source video to clip start". Click "Jump…" → source view shows the clip's starting frame, paused. Press Space → playback starts from that point.
2. **From inside a preview.** Click a different clip to enter preview. Right-click some clip in the sidebar → click "Jump…". Preview closes, source view appears at the clicked clip's start frame, paused.
3. **Missing source.** Quit the app, move the source video file outside the project folder, relaunch. The relink banner appears. Right-click a clip whose source is now missing → "Jump…" menu item is grayed out. Relink the source (point at the moved file) → menu item becomes enabled again. Restore the source file at its original path before continuing other tests if you moved it.
4. **Recording gate.** Press R to start recording. Right-click a clip → both menu items are grayed out. Stop recording (R or Esc) → menu items re-enable.
5. **Unaffected paths.** Cmd+Z / Cmd+Shift+Z still work for clip edits and deletes. The toolbar BACK button still closes preview. The tag-filter chip still appears and works. (Spot-check these — no functional change was made to them.)

- [ ] **Step 2: No commit (verification task).**

If a step fails, file a follow-up — the implementing code is in Task 1's commit.
