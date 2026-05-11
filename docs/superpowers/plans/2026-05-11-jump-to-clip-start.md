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
- `apple/App/Source/MPVSourcePlayer.swift` — add a new public method `setReplayPosition(playlistPos:timeSeconds:)` that handles both attached and detached states so the jump survives a preview-mode re-attach race.
- `apple/App/Views/ClipSidebar.swift` — add `onJumpToClipStart: (Clip.ID) -> Void` prop, add `sourceMissing(for:)` helper, add the new context menu Button.
- `apple/App/ContentView.swift` — add `jumpToClipStart(_:)` method, wire it into the `ClipSidebar(...)` call.

All three files land in **one commit**. The new prop on `ClipSidebar` breaks the `ContentView` call site until supplied; the new method on `MPVSourcePlayer` is the only reliable way for `ContentView`'s handler to survive the detach-during-preview race.

**No new files. No Core changes. No new tests.**

### Why `setReplayPosition` is needed

`MPVSourcePlayer.detachLayer()` (at `apple/App/Source/MPVSourcePlayer.swift:235`) calls `mpv_terminate_destroy(h)` — the mpv instance is destroyed on every detach, not just unbound from a layer. While the user is in preview mode (`appMode == .previewClip(_)`), the `MPVPlayerView` is unmounted, so the source mpv handle is nil. A call to `player.seek(...)` in that state hits the early-return at line 514 (`guard handle != nil else { completion(); return }`) and silently drops the seek. On the next render, `MPVPlayerView` re-mounts, `attachLayer` creates a fresh mpv handle, and the attach-replay path at line 192 reads the player's cached `playlistPos` / `timePos` to position the new instance — those cached values are from before preview opened, not the clip's start.

`setReplayPosition` mutates the cached values directly (and, when the player IS attached, also issues a real seek so the change is visible immediately). The attach-replay then lands at the requested position naturally.

---

## Task 1: Wire the context menu item + handler

**Files:**
- Modify: `apple/App/Source/MPVSourcePlayer.swift`
- Modify: `apple/App/Views/ClipSidebar.swift`
- Modify: `apple/App/ContentView.swift`

- [ ] **Step 1: Add `setReplayPosition` to `MPVSourcePlayer`**

In `apple/App/Source/MPVSourcePlayer.swift`, find the `seek(...)` method (around line 505). Just below it (or in a sensible spot for new public position-control APIs), add:

```swift
    /// Set the position to land at after the next `attachLayer` (or
    /// immediately, if currently attached). The attach-replay path at
    /// `attachLayer` (see the `playlistPos == 0 && timePos > 0` branch
    /// above) reads `self.playlistPos` and `self.timePos` to position
    /// the freshly created mpv handle — overwriting those values here
    /// is what makes the requested position survive a detach/re-attach
    /// cycle. When the handle is currently live, we also issue a real
    /// (coarse) seek so the user sees the change without waiting for
    /// a re-attach. Use this when the caller can't guarantee the mpv
    /// handle exists at call time (e.g., when triggered from preview
    /// mode where the source `MPVPlayerView` is unmounted and the
    /// SwiftUI view-tree swap hasn't happened yet).
    public func setReplayPosition(playlistPos: Int, timeSeconds: Double) {
        // Mutating self.playlistPos / self.timePos directly is safe
        // here: the `private(set)` access keeps the public API
        // read-only externally, but this method is on the player
        // itself. mpv's next property-change event will overwrite
        // these values once mpv catches up — which is exactly what we
        // want (Swift state stays in lockstep with mpv state).
        self.playlistPos = playlistPos
        self.timePos = timeSeconds
        if handle != nil {
            seek(
                playlistPos: playlistPos,
                timeSeconds: timeSeconds,
                exact: false,
                completion: {}
            )
        }
    }
```

This is the only change to `MPVSourcePlayer.swift`.

- [ ] **Step 2: Add the `onJumpToClipStart` prop and the `sourceMissing` helper to `ClipSidebar`**

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

- [ ] **Step 3: Add the menu Button**

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

Add the new Button ABOVE the Delete one (macOS HIG convention puts destructive actions at the bottom, often visually separated):

```swift
            .contextMenu(forSelectionType: Clip.ID.self) { ids in
                if let id = ids.first {
                    Button {
                        onJumpToClipStart(id)
                    } label: {
                        Label("Jump source video to clip start",
                              systemImage: "arrow.left.to.line")
                    }
                    .disabled(isRecording || sourceMissing(for: id))

                    Divider()

                    Button(role: .destructive) {
                        onRequestDeleteClip(id)
                    } label: {
                        Label("Delete Clip", systemImage: "trash")
                    }
                    .disabled(isRecording)
                }
            }
```

- [ ] **Step 4: Add `jumpToClipStart(_:)` to `ContentView`**

In `apple/App/ContentView.swift`, find an appropriate spot for the handler — group it near the other clip-level handlers like `requestDeleteClip` and `handleClosePreview`. Add this method:

```swift
    /// Right-click action from the sidebar: closes any active preview,
    /// then positions the source player at the clip's recorded start.
    /// Leaves the source paused — the user presses Space if they want
    /// to play.
    ///
    /// Uses `setReplayPosition` rather than `seek` because the call
    /// may fire while the source mpv handle is detached (preview mode
    /// unmounts `MPVPlayerView`, which destroys the handle via
    /// `detachLayer` → `mpv_terminate_destroy`). `seek` would no-op
    /// in that state; `setReplayPosition` mutates the cached Swift
    /// state so the attach-replay on next mount lands at the right
    /// position.
    private func jumpToClipStart(_ id: Clip.ID) {
        guard let clip = workspace.project.clips.first(where: { $0.id == id })
        else { return }
        guard let player = workspace.sourcePlayer else { return }

        // Prime the player's position state FIRST. If currently
        // attached (scanning mode), this also issues a real seek so
        // the change is visible immediately. If detached (preview
        // mode), the call just mutates cached state; the seek will
        // take effect when the preview close triggers a re-attach.
        player.setReplayPosition(
            playlistPos: clip.sourceIndex,
            timeSeconds: clip.startSourceSeconds
        )
        player.pause()

        // Close any active preview so the player view swaps back to
        // MPVPlayerView. On re-attach, attachLayer's replay path picks
        // up the playlistPos/timePos we just set.
        if selectedClipID != nil { handleClosePreview() }
    }
```

- [ ] **Step 5: Wire the handler into `ClipSidebar(...)` in `ContentView`**

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

- [ ] **Step 6: Build to verify**

Run: `/Users/taylor/dev/coach-cutups-2/apple/scripts/run.sh`
Expected: build succeeds.

If the build fails on `onJumpToClipStart` mismatch, double-check Step 2 (the prop name + signature must match what Step 5 passes). If it fails on `setReplayPosition`, double-check Step 1.

- [ ] **Step 7: Commit**

```bash
cd /Users/taylor/dev/coach-cutups-2
git add apple/App/Source/MPVSourcePlayer.swift apple/App/Views/ClipSidebar.swift apple/App/ContentView.swift
git commit -m "feat(sidebar): right-click 'Jump source video to clip start'

Right-click a clip → 'Jump source video to clip start' closes any
active preview and positions the source mpv player at the clip's
recorded (sourceIndex, startSourceSeconds), paused. Disabled while
recording and when the clip's source bookmark is unresolved.

Uses a new MPVSourcePlayer.setReplayPosition(playlistPos:timeSeconds:)
that mutates the player's cached state directly so the jump survives
the detach/re-attach race that happens when the action fires from
preview mode (MPVPlayerView is unmounted in preview, which destroys
the mpv handle via mpv_terminate_destroy)."
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
