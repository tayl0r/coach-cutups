# Sidebar right-click: "Jump source video to clip start"

## Goal

Right-clicking a clip in the sidebar offers a new context menu item:
**Jump source video to clip start.** Selecting it closes any active
preview and seeks the source player to the clip's recorded start
position, leaving playback paused.

## UX

Context menu on a sidebar clip row (adjacent to the existing
"Delete Clip"):

```
Delete Clip
Jump source video to clip start
```

Action when clicked:

1. Prime the source player's position via a new
   `MPVSourcePlayer.setReplayPosition(playlistPos:timeSeconds:)`
   method (see below). When the source mpv handle is attached
   (scanning mode), this issues a coarse seek immediately. When
   detached (preview mode), it mutates the player's cached state so
   the attach-replay path at `MPVSourcePlayer.swift:192` picks up
   the new values when the view re-mounts.
2. Pause the source player.
3. If a clip preview is currently open (`selectedClipID != nil`),
   close it via the existing `handleClosePreview` path. The player
   view swaps from `PreviewPlayerSurface` back to `MPVPlayerView`,
   which re-attaches a fresh mpv handle that lands at the position
   set in step 1.

Playback is left **paused** — user presses Space if they want to
play. Seek uses `exact: false` (coarse, keyframe-tolerant) for
navigation responsiveness — `exact: true` on long-GOP HEVC can take
200–600 ms.

### Why `setReplayPosition` is needed

`MPVSourcePlayer.detachLayer()` calls `mpv_terminate_destroy(h)` —
the mpv instance is destroyed on every detach, not just unbound from
its layer. While the user is in preview mode, the source
`MPVPlayerView` is unmounted, so the source mpv handle is nil. A
direct call to `player.seek(...)` in that state hits the
`guard handle != nil` early-return at `MPVSourcePlayer.swift:514`
and silently drops the seek. The fix mutates the player's cached
`playlistPos` / `timePos` so the attach-replay path positions the
freshly created mpv instance at the requested point.

## Disabled states

- While `appMode == .recording` or `.recordingStarting`. Matches the
  existing "Delete Clip" disable rule.
- When the clip's source is missing
  (`workspace.missingSourceIndices.contains(clip.sourceIndex)`). The
  source's bookmark didn't resolve at this session; a seek into an
  empty playlist would silently fail. Better to gray the item out so
  the user can fix the relink first.

## Implementation

### `apple/App/Views/ClipSidebar.swift`

Add a closure prop, paralleling the existing `onRequestDeleteClip`:

```swift
var onJumpToClipStart: (Clip.ID) -> Void
```

Extend the `.contextMenu(forSelectionType: Clip.ID.self)` block:

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

A small helper computes the source-missing gate:

```swift
private func sourceMissing(for clipID: Clip.ID) -> Bool {
    guard let clip = workspace.project.clips.first(where: { $0.id == clipID })
    else { return true }
    return workspace.missingSourceIndices.contains(clip.sourceIndex)
}
```

### `apple/App/Source/MPVSourcePlayer.swift`

Add `setReplayPosition` (see "Why" above):

```swift
public func setReplayPosition(playlistPos: Int, timeSeconds: Double) {
    self.playlistPos = playlistPos
    self.timePos = timeSeconds
    if handle != nil {
        seek(playlistPos: playlistPos, timeSeconds: timeSeconds,
             exact: false, completion: {})
    }
}
```

### `apple/App/ContentView.swift`

Add the handler method. The order matters: prime the position FIRST,
THEN close the preview — so by the time `MPVPlayerView` re-mounts
and re-attaches, the player's cached state already has the right
values to replay.

```swift
private func jumpToClipStart(_ id: Clip.ID) {
    guard let clip = workspace.project.clips.first(where: { $0.id == id })
    else { return }
    guard let player = workspace.sourcePlayer else { return }
    player.setReplayPosition(
        playlistPos: clip.sourceIndex,
        timeSeconds: clip.startSourceSeconds
    )
    player.pause()
    if selectedClipID != nil { handleClosePreview() }
}
```

Wire it into the `ClipSidebar(...)` call:

```swift
ClipSidebar(
    workspace: workspace,
    selectedClipID: $selectedClipID,
    appMode: appMode,
    selectedTagFilter: $selectedTagFilter,
    onRequestDeleteClip: { id in requestDeleteClip(id) },
    onJumpToClipStart: { id in jumpToClipStart(id) }
)
```

## Testing

No new unit tests. The handler is a thin delegate to existing
well-tested code (`MPVSourcePlayer.seek`, `handleClosePreview`,
`workspace.project.clips` lookup).

Manual smoke:

1. Right-click a clip with no preview open → menu shows both items.
   Click "Jump source video to clip start" → source view shows the
   clip's starting frame, paused.
2. Repeat while a different clip is previewed → preview closes, source
   view appears at the right-clicked clip's start frame.
3. With a clip whose source is missing (relink banner showing), the
   menu item is grayed out.
4. While recording, both context menu items are grayed out.
5. After a successful jump, pressing Space plays the source from the
   clip's start position normally.

## Non-goals

- Auto-play after the seek. (User asked for "seek to the clip start
  time" — explicitly not "and start playing.")
- Marking the seek point or selecting a range. The jump is one-shot;
  the user can then play freely.
- Showing the clip's end position. We jump to start only; if the user
  wants to find the end, they can play forward or use the recording
  duration shown in the sidebar.
- A keyboard shortcut for this action. Right-click is the only
  surface for v1.
