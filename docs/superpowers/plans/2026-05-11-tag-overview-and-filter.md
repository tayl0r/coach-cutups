# Tag overview + sidebar filter + Esc-clear Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the inspector's "No clip selected" placeholder with a tag overview (count + duration per tag, A–Z or duration-desc), wire click-to-filter on the sidebar, and let Esc clear the filter as a third cascade layer.

**Architecture:** Pure UI / view-state additions. Aggregation reuses the existing `VideoCoachCore.TagAggregation.aggregate(project:)`. New `@State selectedTagFilter: String?` lives in `ContentView` and is threaded by binding to `ClipInspector` (renders + toggles) and `ClipSidebar` (filters list + chip + drag-disable). `KeyCommandView` gains a `hasTagFilter`/`onClearTagFilter` pair so its Esc handler can fire the clear in scanning mode.

**Tech Stack:** SwiftUI (Sonoma+/macOS 14), AppKit (NSEvent monitor for Esc). No new tests — `TagAggregation` is already covered in `VideoCoachCoreTests/TagAggregationTests.swift`; the rest is view plumbing verified manually.

**Build command (after every Swift edit):**
```
/Users/taylor/dev/coach-cutups-2/apple/scripts/run.sh
```

---

## File Structure

**Modify:**
- `apple/App/Views/ClipInspector.swift` — replace `placeholder` with a new `private struct TagOverview: View`; thread `selectedTagFilter: Binding<String?>` through `ClipInspector`.
- `apple/App/Views/ClipSidebar.swift` — accept `selectedTagFilter: Binding<String?>`; filter the clip list, render a "Filtered: <tag> ×" chip, omit `.onMove` while active.
- `apple/App/Views/KeyCommandView.swift` — add `hasTagFilter: Bool` and `onClearTagFilter: () -> Void` props; in the Esc handler's `default` case, fire the clear and consume the event when the filter is active.
- `apple/App/ContentView.swift` — add `@State private var selectedTagFilter: String?`; thread the binding to inspector + sidebar; pass `hasTagFilter` + `onClearTagFilter` to `KeyCommandView`; clear filter on `workspace.folder` change.

**No new files.** No Core changes.

---

## Task 1: TagOverview in inspector + filter state in ContentView

Lands the inspector replacement (the visible new UI) and the underlying state. After this task, clicking a tag in the inspector toggles its highlight but the sidebar doesn't react yet (that's Task 2). This intermediate state lets us verify the rendering, sort toggle, and toggle semantics in isolation.

**Files:**
- Modify: `apple/App/Views/ClipInspector.swift`
- Modify: `apple/App/ContentView.swift`

- [ ] **Step 1: Add filter state in ContentView and thread it to ClipInspector**

In `apple/App/ContentView.swift`, near the other `@State` declarations at the top of `struct ContentView`, add:

```swift
    /// Currently active sidebar tag filter. nil = show all clips.
    /// Toggled by clicking rows in the inspector's TagOverview when
    /// no clip is selected. Cleared on project switch (below) and by
    /// Esc in scanning mode (Task 3). View-state only; never persisted.
    @State private var selectedTagFilter: String? = nil
```

Find the `ClipInspector(...)` call in `mainSplit`'s `detail:` slot (around line 357–360):

```swift
        } detail: {
            ClipInspector(
                workspace: workspace,
                selectedClipID: $selectedClipID
            )
```

Replace with:

```swift
        } detail: {
            ClipInspector(
                workspace: workspace,
                selectedClipID: $selectedClipID,
                selectedTagFilter: $selectedTagFilter
            )
```

Add a one-line `.onChange` on the modifier chain in `rootContent` (or directly on the `body`'s top view) to clear the filter when the project switches. Place it near the existing `.onChange(of: selectedClipID)` blocks (around line 98):

```swift
            .onChange(of: workspace.folder) { _, _ in
                // Filter is view-state tied to the current project; reset
                // it when the user opens or switches projects.
                selectedTagFilter = nil
            }
```

- [ ] **Step 2: Replace the inspector's placeholder with `TagOverview`**

In `apple/App/Views/ClipInspector.swift`, the `ClipInspector` struct accepts a new binding and the existing `placeholder` view is replaced with the new `TagOverview` view.

Find the existing `struct ClipInspector` declaration (around line 7–11):

```swift
struct ClipInspector: View {
    @Bindable var workspace: Workspace
    @Binding var selectedClipID: Clip.ID?

    var body: some View {
```

Replace with:

```swift
struct ClipInspector: View {
    @Bindable var workspace: Workspace
    @Binding var selectedClipID: Clip.ID?
    @Binding var selectedTagFilter: String?

    /// Sort mode for the no-clip-selected tag overview. Hoisted here
    /// (rather than as @State inside TagOverview) so the user's
    /// chosen sort survives clip-selection cycles — the inspector's
    /// body switches between EditorView and TagOverview, tearing
    /// down whichever isn't currently shown.
    @State private var tagOverviewSort: TagOverviewSortMode = .alpha

    var body: some View {
```

Find the `placeholder` private view (around line 33–39):

```swift
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Inspector").font(.headline)
            Text("No clip selected").foregroundStyle(.secondary)
            Spacer()
        }
    }
```

Replace with a call to a new view that takes the workspace, the filter binding, and the sort binding:

```swift
    private var placeholder: some View {
        TagOverview(
            workspace: workspace,
            selectedTagFilter: $selectedTagFilter,
            sort: $tagOverviewSort
        )
    }
```

Then add the new `TagOverview` view at the bottom of `ClipInspector.swift` (after the existing `private struct EditorView`):

```swift
/// Shown in the inspector when no clip is selected. Lists every tag
/// used across the project's clips with per-tag count and total
/// duration. Default sort is alpha; the sort toggle button flips to
/// duration-descending (ties break alpha so the order is stable).
/// Clicking a row toggles the global `selectedTagFilter`: nil → this
/// tag, this tag → nil, other tag → this tag. The active filter row
/// gets a subtle accent background so the user can see what's on.
enum TagOverviewSortMode: Hashable {
    case alpha
    case durationDesc
}

private struct TagOverview: View {
    let workspace: Workspace
    @Binding var selectedTagFilter: String?
    /// Sort mode is hoisted to the parent `ClipInspector` so it
    /// survives clip-selection cycles. `TagOverview` is torn down
    /// whenever a clip is selected (the inspector body switches to
    /// `EditorView`); a `@State` here would reset on every cycle.
    @Binding var sort: TagOverviewSortMode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if workspace.project.clips.isEmpty {
                emptyMessage("No clips yet")
            } else {
                let summaries = sortedSummaries()
                if summaries.isEmpty {
                    emptyMessage("No tags yet — add tags to clips in the Inspector.")
                } else {
                    list(summaries)
                }
            }
            // No trailing Spacer here. The ScrollView inside `list`
            // needs to expand to consume the remaining vertical
            // space; a Spacer would compete with it and collapse the
            // ScrollView to its content's intrinsic height (which on
            // a long tag list would clip).
        }
    }

    private var header: some View {
        HStack {
            Text("Tags").font(.headline)
            Spacer()
            Button {
                sort = (sort == .alpha) ? .durationDesc : .alpha
            } label: {
                // Label shows the CURRENT mode so users can see which sort
                // is active without having to recognize which icon means
                // which direction.
                Text(sort == .alpha ? "A–Z" : "Duration")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Toggle sort order")
        }
    }

    @ViewBuilder
    private func emptyMessage(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .font(.callout)
    }

    private func list(_ summaries: [TagSummary]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(summaries, id: \.tag) { summary in
                    row(for: summary)
                }
            }
        }
    }

    private func row(for summary: TagSummary) -> some View {
        let isActive = selectedTagFilter == summary.tag
        return Button {
            // Toggle: clicking the active tag clears, clicking a
            // different tag swaps, clicking when nil sets.
            selectedTagFilter = isActive ? nil : summary.tag
        } label: {
            HStack {
                Text(summary.tag)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(summary.clipCount) · \(formatDuration(summary.totalDurationSeconds))")
                    .foregroundStyle(.secondary)
                    .font(.callout.monospacedDigit())
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sortedSummaries() -> [TagSummary] {
        let base = TagAggregation.aggregate(project: workspace.project)
        switch sort {
        case .alpha:
            return base                                      // already alpha
        case .durationDesc:
            return base.sorted { lhs, rhs in
                if lhs.totalDurationSeconds != rhs.totalDurationSeconds {
                    return lhs.totalDurationSeconds > rhs.totalDurationSeconds
                }
                return lhs.tag < rhs.tag                     // stable tie-break
            }
        }
    }
}
```

`formatDuration(_:)` is a top-level function defined in `ClipSidebar.swift`. Both files are in the same target so it's visible here without any import or qualification.

- [ ] **Step 3: Build and verify**

Run: `/Users/taylor/dev/coach-cutups-2/apple/scripts/run.sh`
Expected: build succeeds, app launches. Open a project with at least a few tagged clips. With no clip selected, the inspector now shows:
- "Tags" header with an `A–Z` button on the right
- One row per tag, name on the left, "count · duration" on the right
- Clicking a row highlights it (background tint); clicking again removes the highlight; clicking a different row moves the highlight
- The sort button flips between `A–Z` and `Duration`; alphabetical when `A–Z` is shown, longest-first when `Duration` is shown
- Empty-state messages when there are no clips / no tags

The sidebar doesn't react to the filter yet — that's Task 2. The clip-selected behavior is unchanged.

- [ ] **Step 4: Commit**

```bash
cd /Users/taylor/dev/coach-cutups-2
git add apple/App/Views/ClipInspector.swift apple/App/ContentView.swift
git commit -m "feat(inspector): TagOverview replaces placeholder when no clip selected

Shows every tag in the project with clip count + total duration.
Default sort is A–Z (from TagAggregation); a single button flips to
duration-descending with alpha tie-break. Click a row to toggle
ContentView's selectedTagFilter; the sidebar will start reacting in
the next commit. Filter is cleared on project switch."
```

---

## Task 2: Sidebar reacts to the filter (chip + filtered list + drag-disable)

After this task the filter is visibly functional: clicking a tag in the inspector filters the sidebar list and shows a chip; clicking `×` clears it.

**Files:**
- Modify: `apple/App/Views/ClipSidebar.swift`
- Modify: `apple/App/ContentView.swift`

- [ ] **Step 1: Pass the binding from ContentView to ClipSidebar**

In `apple/App/ContentView.swift`, find the existing `ClipSidebar(...)` call in `mainSplit` (around line 234):

```swift
        NavigationSplitView {
            ClipSidebar(
                workspace: workspace,
                selectedClipID: $selectedClipID,
                appMode: appMode,
                onRequestDeleteClip: { id in requestDeleteClip(id) }
            )
```

Replace with:

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

- [ ] **Step 2: Apply the filter in ClipSidebar**

Read the current `apple/App/Views/ClipSidebar.swift` in full before editing — it has a `TextField` for project name + a `Divider` + a `List` with TWO sections (`sourcesSection`, `clipsSection`) wrapped in a `VStack`. The filter chip slots BETWEEN the existing `Divider` and the `List`; only `clipsSection` filters; `sourcesSection` is unchanged.

**Edit 1 — add the binding.** Find the existing property list (around line 10–14):

```swift
struct ClipSidebar: View {
    @Bindable var workspace: Workspace
    @Binding var selectedClipID: Clip.ID?
    let appMode: AppMode
    var onRequestDeleteClip: (Clip.ID) -> Void
```

Insert `selectedTagFilter` before `onRequestDeleteClip`:

```swift
struct ClipSidebar: View {
    @Bindable var workspace: Workspace
    @Binding var selectedClipID: Clip.ID?
    let appMode: AppMode
    @Binding var selectedTagFilter: String?
    var onRequestDeleteClip: (Clip.ID) -> Void
```

**Edit 2 — add a filtered-clips computed property.** Just below the existing `sortedClips` property (around lines 20–22):

```swift
    private var sortedClips: [Clip] {
        workspace.project.clips.sorted(by: { $0.sortIndex < $1.sortIndex })
    }
```

Add:

```swift
    /// Sorted clips after applying `selectedTagFilter`. When nil,
    /// equivalent to `sortedClips`. Used by `clipsSection` for
    /// rendering — `sortedClips` is preserved for any non-filtered
    /// callers.
    private var visibleClips: [Clip] {
        guard let filter = selectedTagFilter else { return sortedClips }
        return sortedClips.filter { $0.tags.contains(filter) }
    }
```

**Edit 3 — insert the filter chip between the existing Divider and List.** Find this block in `body` (around lines 28–42):

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Project name", text: $workspace.project.name)
                .textFieldStyle(.plain)
                .font(.headline)
                .padding(8)
                .onSubmit { try? workspace.saveProject() }
                .disabled(isRecording)

            Divider()

            List(selection: $selectedClipID) {
                sourcesSection
                clipsSection
            }
```

Insert the chip after `Divider()` and before `List`:

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Project name", text: $workspace.project.name)
                .textFieldStyle(.plain)
                .font(.headline)
                .padding(8)
                .onSubmit { try? workspace.saveProject() }
                .disabled(isRecording)

            Divider()

            if let activeFilter = selectedTagFilter {
                filterChip(activeFilter)
                Divider()
            }

            List(selection: $selectedClipID) {
                sourcesSection
                clipsSection
            }
```

**Edit 4 — add the `filterChip` builder.** Place it near the bottom of `ClipSidebar`, just above the closing brace of the struct (after `clipsSection` / `sourceRow` / `sourcesSection`):

```swift
    @ViewBuilder
    private func filterChip(_ tag: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "tag.fill")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text("Filtered: \(tag)")
                .font(.callout)
            Spacer()
            Button {
                selectedTagFilter = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear filter")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.10))
    }
```

**Edit 5 — modify `clipsSection` to use `visibleClips`, conditionally disable `.onMove`, and show the empty-state message.** Find the current `clipsSection` (around lines 116–136):

```swift
    @ViewBuilder
    private var clipsSection: some View {
        Section {
            ForEach(sortedClips) { clip in
                HStack {
                    Text(clip.name).lineLimit(1)
                    Spacer()
                    Text(formatDuration(clip.recordingDuration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .tag(clip.id)
            }
            .onMove { indices, dest in
                workspace.reorderClips(from: indices, to: dest)
            }
        } header: {
            Text("Clips")
        }
    }
```

Replace with:

```swift
    @ViewBuilder
    private var clipsSection: some View {
        Section {
            // Use `visibleClips` (filtered) when a tag filter is
            // active, otherwise the full `sortedClips`. The two
            // ForEach branches let us attach .onMove conditionally —
            // SwiftUI requires .onMove directly on a ForEach, not
            // wrapped in an `if`.
            if selectedTagFilter != nil {
                ForEach(visibleClips) { clip in
                    clipRow(clip)
                }
                // No .onMove while filtered — reordering a subset
                // would permute sortIndex of clips you can't see.
                if visibleClips.isEmpty {
                    Text("No clips with tag '\(selectedTagFilter!)'")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .padding(.vertical, 4)
                }
            } else {
                ForEach(sortedClips) { clip in
                    clipRow(clip)
                }
                .onMove { indices, dest in
                    workspace.reorderClips(from: indices, to: dest)
                }
            }
        } header: {
            Text("Clips")
        }
    }

    @ViewBuilder
    private func clipRow(_ clip: Clip) -> some View {
        HStack {
            Text(clip.name).lineLimit(1)
            Spacer()
            Text(formatDuration(clip.recordingDuration))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .tag(clip.id)
    }
```

(The clip-row body is extracted into `clipRow(_:)` so the two ForEach branches share it.)

- [ ] **Step 3: Build and verify**

Run: `/Users/taylor/dev/coach-cutups-2/apple/scripts/run.sh`
Expected: build succeeds. Manual smoke:
- With a project open and several tagged clips, click a tag in the inspector. The sidebar should now show only clips with that tag, plus a "Filtered: <tag> ×" chip at the top.
- Click the `×` in the chip → filter clears, full list returns.
- Click the same tag again in the inspector → filter clears.
- Click a different tag → filter swaps.
- While filtered, try to drag-reorder a clip in the sidebar. The `.onMove` should be inactive (no drag indicator). Clear the filter → drag-reorder works again.
- Click a tag that no clip has (shouldn't be possible from the inspector, but if you reach it some other way) → "No clips with tag 'X'" message under the chip.

- [ ] **Step 4: Commit**

```bash
cd /Users/taylor/dev/coach-cutups-2
git add apple/App/Views/ClipSidebar.swift apple/App/ContentView.swift
git commit -m "feat(sidebar): filter chip + filtered list + disable drag while filtered

Sidebar accepts selectedTagFilter binding from ContentView. When
non-nil, renders a 'Filtered: <tag> ×' chip above the list and
shows only clips containing the tag. Drag-to-reorder is suppressed
while filtered so users don't accidentally permute sortIndex on
clips they can't see."
```

---

## Task 3: Esc cascade clears filter in scanning mode

Adds the third Esc layer. After recording-stop (layer 1) and preview-close (layer 2), Esc in scanning mode with a filter set clears the filter (layer 3); without a filter it falls through to AppKit as today.

**Files:**
- Modify: `apple/App/Views/KeyCommandView.swift`
- Modify: `apple/App/ContentView.swift`

- [ ] **Step 1: Add filter-aware props to KeyCommandView**

In `apple/App/Views/KeyCommandView.swift`, find the `struct KeyCommandView` declaration with its stored properties (around lines 3–27 — the closure-let block at the top). Add two new properties at the end of that block:

```swift
    /// True when ContentView's selectedTagFilter is non-nil. Lets the
    /// Esc handler fire onClearTagFilter as a third cascade layer
    /// (after stop-recording and close-preview).
    let hasTagFilter: Bool
    /// Invoked when Esc fires in scanning mode and a filter is active.
    /// Owned by ContentView; sets selectedTagFilter = nil.
    let onClearTagFilter: () -> Void
```

Find the `apply(to:)` method (around line 38–47):

```swift
    private func apply(to v: KeyCatchingView) {
        v.appMode = appMode
        v.onSkip = onSkip
        v.onTogglePlay = onTogglePlay
        v.onToggleRecord = onToggleRecord
        v.onClosePreview = onClosePreview
        v.onResetZoom = onResetZoom
        v.currentZoomScale = currentZoomScale
        v.onZoomLevel = onZoomLevel
    }
```

Add the two new fields:

```swift
    private func apply(to v: KeyCatchingView) {
        v.appMode = appMode
        v.onSkip = onSkip
        v.onTogglePlay = onTogglePlay
        v.onToggleRecord = onToggleRecord
        v.onClosePreview = onClosePreview
        v.onResetZoom = onResetZoom
        v.currentZoomScale = currentZoomScale
        v.onZoomLevel = onZoomLevel
        v.hasTagFilter = hasTagFilter
        v.onClearTagFilter = onClearTagFilter
    }
```

Find the `KeyCatchingView` class's stored properties (around line 74–82). Add two new fields:

```swift
    var hasTagFilter: Bool = false
    var onClearTagFilter: () -> Void = {}
```

Now find the `Esc` switch in the monitor closure (around line 118–132). It currently looks like:

```swift
            case KeyCode.escape:
                // Esc handles "exit current mode": stop recording during
                // .recording, close clip preview during .previewClip /
                // .previewLoading. Outside those modes it falls through so
                // AppKit's normal Esc (close popover, dismiss sheet) works.
                switch self.appMode {
                case .recording:
                    self.onToggleRecord()
                    return nil
                case .previewClip, .previewLoading:
                    self.onClosePreview()
                    return nil
                default:
                    return event
                }
```

Replace the `default` arm:

```swift
            case KeyCode.escape:
                // Esc cascade: stop recording, close preview, clear tag
                // filter, then fall through to AppKit (close popover,
                // dismiss sheet). Each layer unwinds one piece of view
                // state so two Esc presses from "previewing with a
                // filter" leave you at default scanning + no filter.
                switch self.appMode {
                case .recording:
                    self.onToggleRecord()
                    return nil
                case .previewClip, .previewLoading:
                    self.onClosePreview()
                    return nil
                default:
                    if self.hasTagFilter {
                        self.onClearTagFilter()
                        return nil
                    }
                    return event
                }
```

- [ ] **Step 2: Wire the new props in ContentView**

In `apple/App/ContentView.swift`, find the existing `KeyCommandView(...)` call in `mainSplit` (around lines 319–335):

```swift
                    KeyCommandView(
                        appMode: appMode,
                        onSkip: handleSkip,
                        onTogglePlay: handleTogglePlay,
                        onToggleRecord: handleToggleRecord,
                        onClosePreview: handleClosePreview,
                        onResetZoom: { workspace.currentZoom = .identity },
                        currentZoomScale: workspace.currentZoom.scale,
                        onZoomLevel: { newScale, cursor in
                            // … existing comment + body …
                            let next = workspace.currentZoom
                                .zoomedToCursor(newScale: newScale, cursor: cursor)
                            workspace.setCurrentZoomImmediate(next)
                        }
                    )
```

Add two trailing arguments to the call:

```swift
                    KeyCommandView(
                        appMode: appMode,
                        onSkip: handleSkip,
                        onTogglePlay: handleTogglePlay,
                        onToggleRecord: handleToggleRecord,
                        onClosePreview: handleClosePreview,
                        onResetZoom: { workspace.currentZoom = .identity },
                        currentZoomScale: workspace.currentZoom.scale,
                        onZoomLevel: { newScale, cursor in
                            let next = workspace.currentZoom
                                .zoomedToCursor(newScale: newScale, cursor: cursor)
                            workspace.setCurrentZoomImmediate(next)
                        },
                        hasTagFilter: selectedTagFilter != nil,
                        onClearTagFilter: { selectedTagFilter = nil }
                    )
```

- [ ] **Step 3: Build and verify**

Run: `/Users/taylor/dev/coach-cutups-2/apple/scripts/run.sh`
Expected: build succeeds. Manual smoke:
- In scanning mode, click a tag in the inspector → sidebar filters. Press Esc → filter clears, full list returns.
- With no filter active, press Esc → nothing happens (AppKit default for unhandled Esc).
- Enter a preview (click a clip) while a filter is set. Press Esc → preview closes, filter STILL set (chip still visible). Press Esc again → filter clears.
- During recording, Esc still stops the recording (no filter interaction).

- [ ] **Step 4: Commit**

```bash
cd /Users/taylor/dev/coach-cutups-2
git add apple/App/Views/KeyCommandView.swift apple/App/ContentView.swift
git commit -m "feat(key-commands): Esc clears tag filter as third cascade layer

After the existing recording-stop and preview-close cases, Esc in
scanning mode fires onClearTagFilter when the filter is active.
Two presses unwind 'preview a clip with a filter set' back to the
default scanning view."
```

---

## Task 4: Final regression sweep

Verification only; no code.

**Files:** none.

- [ ] **Step 1: Run all tests**

```
cd /Users/taylor/dev/coach-cutups-2/apple/VideoCoachCore && swift test
```
Expected: ALL PASS — existing test suite including `TagAggregationTests`.

- [ ] **Step 2: Manual end-to-end smoke**

Run `/Users/taylor/dev/coach-cutups-2/apple/scripts/run.sh` and walk through:

1. **Inspector renders correctly.** With no clip selected and several tagged clips, the inspector shows the Tags header, sort button, and one row per unique tag with `<count> · <duration>`. Counts and durations match (cross-check by counting clips with each tag).
2. **Sort toggle.** Click the button; rows reorder by total duration desc (ties broken alpha). Click again; rows reorder back to A–Z.
3. **Click-to-filter.** Click a tag row → row highlights, sidebar filters, chip appears. Click same tag → unhighlights, sidebar restores, chip disappears. Click a different tag → highlight + filter swap.
4. **Chip × clears.** Click the `×` in the sidebar chip → filter clears.
5. **Drag-reorder.** While filtered, dragging a sidebar clip should not reorder. Clear the filter; dragging works again.
6. **Esc clears (scanning).** With filter set and no clip selected, press Esc → filter clears.
7. **Esc cascade through preview.** Set filter, click a clip (enter preview). Press Esc → preview closes, filter still set. Press Esc again → filter clears.
8. **Esc with recording.** With filter set, press R to start recording. Esc still stops recording (filter untouched). After stop, Esc clears filter as in step 6.
9. **Project switch.** With filter set, open a different project folder → filter resets to nil.
10. **Empty states.** Open a project with no clips → inspector shows "No clips yet". Open a project with clips but no tags on any → "No tags yet — add tags to clips in the Inspector".
11. **Clip-selected path unchanged.** Select a clip → inspector shows the existing EditorView with name/tags/notes. Cmd+Z / Cmd+Delete still work as before.

- [ ] **Step 3: No commit (verification task).**

If any step fails, file a follow-up — the implementing code is in earlier tasks' commits.
