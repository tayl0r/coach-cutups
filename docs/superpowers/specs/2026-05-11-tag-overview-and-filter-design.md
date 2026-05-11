# Tag overview in inspector + tag-filter for sidebar

## Goal

When no clip is selected, replace the inspector's "No clip selected"
placeholder with a useful tag overview. Make those tags clickable to
filter the sidebar to clips with that tag. Give Esc a way to clear
the filter so the user can always unwind to the default view.

User-visible behavior:

1. **Tag overview in inspector when nothing selected** — list of every
   tag used across the project, with per-tag clip count and total
   duration. Default sort A–Z; a button flips to duration descending.
2. **Click-to-filter** — clicking a tag row toggles a global
   single-tag filter. The sidebar shows only clips containing that
   tag, with a small chip at the top: `Filtered: <tag> ×`. Click the
   `×` (or the same tag row in the inspector again) to clear.
3. **Esc clears the filter** — as a third layer in the existing Esc
   cascade (after stop-recording and close-preview).

## Non-goals

- Multi-tag filtering (AND or OR across multiple tags). Single-tag
  toggle only for v1.
- Reordering clips while the filter is active. Drag-to-reorder is
  disabled when the sidebar list is filtered (changing `sortIndex` of
  clips you can't see is confusing).
- Persisting the filter across launches or project switches. It's a
  view-state toggle; opening a project clears it.
- Clicking-a-tag opens the tag for renaming or any tag-management
  surface. Pure read + filter for v1.
- Inverse filter / exclude (`NOT shot`).

## UX

### Inspector when no clip is selected (replaces today's `placeholder`)

```
Tags                                      [ A–Z ▾ ]
─────────────────────────────────────────────────
shot                                  12 · 2:18
on-goal                                7 · 1:42
set-piece                              4 · 0:51
…
```

- Header `Tags` on the left, sort toggle button on the right.
- Sort button shows the current mode: tap to flip between `A–Z` and
  `Duration`. Single button rather than a segmented control — matches
  the user's "a button" framing.
- One row per tag. Tag name left-aligned; `<count> · <duration>`
  right-aligned.
- Duration format: reuse the existing `formatDuration(_:)` in
  `ClipSidebar.swift` (renders as `M:SS`, with `M` allowed to grow past
  60 for long totals — e.g., `75:00` for 1h 15m). Matches the format
  the sidebar already uses for clip and source durations.
- When the row's tag matches `selectedTagFilter`, the row gets a
  subtle accent-colored background so the user can see what's active.
- Clicking a row toggles `selectedTagFilter`:
  - filter nil → set to this tag.
  - filter equals this tag → set to nil.
  - filter is some other tag → swap to this tag.

### Empty states

- No clips in the project → "No clips yet."
- Clips exist but no tags on any clip → "No tags yet — add tags to
  clips in the Inspector."

### Sidebar when a filter is active

- Small chip pinned above the clip list: `Filtered: shot ×`. Tapping
  `×` clears the filter (`selectedTagFilter = nil`).
- Visible clips = `project.clips.filter { $0.tags.contains(filter) }`,
  preserving the existing sortIndex ordering inside the subset.
- Drag-to-reorder disabled while the chip is visible (no `.onMove`).
- Empty state below the chip if the filter matches nothing:
  "No clips with tag '\(filter)'."

### Esc cascade (extends today's logic in `KeyCommandView`)

| Mode                                 | Esc does                  |
|--------------------------------------|---------------------------|
| `.recording`                         | stop recording            |
| `.previewClip` / `.previewLoading`   | close preview             |
| scanning + `selectedTagFilter != nil`| clear filter — **new**    |
| scanning + no filter                 | falls through (AppKit)    |

Two presses unwind "preview a clip with a filter set" back to default:
first closes preview, second clears filter.

## Data model

Reuse `VideoCoachCore.TagAggregation.aggregate(project:)`, which
already returns `[TagSummary]` sorted alpha by tag:

```swift
public struct TagSummary: Hashable, Sendable {
    public var tag: String
    public var clipCount: Int
    public var totalDurationSeconds: Double
}

public enum TagAggregation {
    public static func aggregate(project: Project) -> [TagSummary]
}
```

The inspector view sorts in-memory when the user toggles to
duration-descending; on a tie it falls back to alpha so the order is
stable. No new Core types or methods.

A clip with multiple tags contributes its full `recordingDuration` to
each of its tags. The sum of durations across tags can exceed total
project duration — that's by design ("total time of content tagged X",
not "time exclusively tagged X").

## Filter state

```swift
// ContentView.swift
@State private var selectedTagFilter: String? = nil
```

Threaded down as a binding to:
- `ClipInspector` — so the new tag overview can toggle it and
  highlight the active row.
- `ClipSidebar` — so the list filters and the chip renders.

Cleared by:
- Clicking the same tag in the inspector (toggle off).
- Clicking the `×` chip in the sidebar.
- Pressing Esc in scanning mode while filter is set.
- Opening a project (extends the existing reset that happens on
  `workspace.openProject(...)` completion).

NOT cleared by:
- Selecting a clip while the filter is active. The user might want
  to keep filter context while inspecting individual clips.
- Recording start/stop. Recording itself doesn't interact with the
  filter.

## File-by-file change summary

- `apple/App/Views/ClipInspector.swift`
  - Replaces the `placeholder` view with a new `private struct
    TagOverview: View` taking `workspace: Workspace`, `selectedTagFilter:
    Binding<String?>`. `@State` sort mode lives in `TagOverview`.
  - `ClipInspector` accepts a `selectedTagFilter: Binding<String?>`
    and passes it to `TagOverview` (only when `selectedClipID == nil`).
- `apple/App/Views/ClipSidebar.swift`
  - Accepts `selectedTagFilter: Binding<String?>`.
  - When non-nil: renders the filter chip above the `List`, applies
    the predicate to the displayed clips, and omits the `.onMove`.
- `apple/App/Views/KeyCommandView.swift`
  - Adds `var hasTagFilter: Bool = false` and
    `var onClearTagFilter: () -> Void = {}`.
  - Esc handler `default` case calls `onClearTagFilter` and returns
    `nil` when `hasTagFilter` is true; otherwise falls through.
- `apple/App/ContentView.swift`
  - Adds `@State private var selectedTagFilter: String? = nil`.
  - Passes the binding to `ClipInspector` and `ClipSidebar`.
  - Passes `hasTagFilter` + `onClearTagFilter` to `KeyCommandView`.
  - Adds an `.onChange(of: workspace.folder) { _, _ in selectedTagFilter = nil }`
    so opening a different project resets the filter. (The existing
    `DeviceWiringModifier` already watches `workspace.folder`; this is
    a separate one-liner on the main view.)

## Testing

`TagAggregation.aggregate(project:)` already has tests in
`VideoCoachCoreTests/TagAggregationTests.swift` — no Core changes here
mean no new Core tests.

UI is verified manually:
- Add tags to several clips; confirm inspector list, counts, and
  total durations match.
- Sort toggle flips order; tied durations fall back to alpha.
- Click a tag → sidebar filters, chip appears, drag is disabled. Click
  same tag → clears. Click different tag → swaps.
- Click `×` on the chip → clears.
- Esc cascade: in preview with filter set → press once (preview
  closes), press again (filter clears). In scanning with no filter →
  Esc does nothing.
- Open a different project → filter resets to nil.
- No clips: inspector shows "No clips yet." No tags: shows "No tags
  yet."
