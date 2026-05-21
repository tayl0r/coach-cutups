import SwiftUI
import VideoCoachCore

/// Right pane: clip metadata editor. Reads/writes go through a `Binding<Clip>`
/// resolved from `selectedClipID`, and each commit calls `workspace.saveProject()`
/// so disk state matches what's on screen.
struct ClipInspector: View {
    @Bindable var workspace: Workspace
    let coordinator: TranscriptionCoordinator
    @Binding var selectedClipID: Clip.ID?
    @Binding var selectedTagFilter: String?

    /// Sort mode for the no-clip-selected tag overview. Hoisted here
    /// (rather than as @State inside TagOverview) so the user's
    /// chosen sort survives clip-selection cycles — the inspector's
    /// body switches between EditorView and TagOverview, tearing
    /// down whichever isn't currently shown.
    @State private var tagOverviewSort: TagOverviewSortMode = .alpha

    var body: some View {
        Group {
            if let id = selectedClipID, let binding = clipBinding(for: id) {
                EditorView(
                    workspace: workspace,
                    coordinator: coordinator,
                    clip: binding,
                    suggestions: tagSuggestions
                )
                // Force teardown when selection changes so the OLD EditorView's
                // TagField runs its onDisappear-commit through its OLD binding
                // (which still resolves to the old clip by ID). Without this,
                // the binding migrates to the new clip first and the in-flight
                // tag edit lands on the wrong clip.
                .id(id)
            } else {
                placeholder
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var placeholder: some View {
        TagOverview(
            workspace: workspace,
            selectedTagFilter: $selectedTagFilter,
            sort: $tagOverviewSort
        )
    }

    /// Binding into the clip with the given id, resolved on every read/write.
    /// We look up by ID rather than by captured index so the binding stays
    /// correct across reorders AND so an in-flight edit on the OLD inspector
    /// (during selection-change teardown) writes to the right clip even after
    /// `selectedClipID` has moved on.
    private func clipBinding(for id: Clip.ID) -> Binding<Clip>? {
        guard workspace.project.clips.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: {
                // Defensive: clip may have been deleted between renders.
                workspace.project.clips.first(where: { $0.id == id }) ?? Self.placeholderClip
            },
            set: { newValue in
                if let i = workspace.project.clips.firstIndex(where: { $0.id == id }) {
                    workspace.project.clips[i] = newValue
                }
            }
        )
    }

    private static let placeholderClip = Clip(
        name: "", sourceIndex: 0, startSourceSeconds: 0,
        recordingDuration: 0, recordingFilename: "", sortIndex: 0
    )

    private var tagSuggestions: Set<String> {
        Set(workspace.project.clips.flatMap(\.tags))
    }
}

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

private struct EditorView: View {
    let workspace: Workspace
    let coordinator: TranscriptionCoordinator
    @Binding var clip: Clip
    let suggestions: Set<String>

    @FocusState private var nameFocused: Bool
    @FocusState private var notesFocused: Bool
    @FocusState private var transcriptFocused: Bool
    @FocusState private var summaryFocused: Bool

    /// Per-field snapshots taken on focus-gain. Each field commits its
    /// own undo step on focus-loss. Per-spec ("each blur/Enter on a
    /// field is one step"), so tabbing name → tags → notes produces
    /// up to three undo steps. No union/coalescing here — it would
    /// require coordinating two different focus-tracking primitives
    /// (@FocusState for name+notes, callback for TagField) and the
    /// interleave order between them isn't guaranteed by SwiftUI.
    @State private var nameSnapshot: Clip?
    @State private var tagsSnapshot: Clip?
    @State private var notesSnapshot: Clip?
    @State private var transcriptSnapshot: Clip?
    @State private var summarySnapshot: Clip?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clip").font(.headline)

            Group {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("Clip name", text: $clip.name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onChange(of: nameFocused) { _, focused in
                        handleFocusChange(focused: focused, snapshot: $nameSnapshot)
                    }
                    .onSubmit { try? workspace.saveProject() }
            }

            Group {
                Text("Tags").font(.caption).foregroundStyle(.secondary)
                TagField(
                    tags: $clip.tags,
                    suggestions: suggestions,
                    onCommit: { try? workspace.saveProject() },
                    onFocusChange: { focused in
                        handleFocusChange(focused: focused, snapshot: $tagsSnapshot)
                    }
                )
            }

            Group {
                Text("PiP").font(.caption).foregroundStyle(.secondary)
                Toggle("Show picture-in-picture", isOn: Binding(
                    get: { clip.showPiP },
                    set: { newValue in
                        let before = clip
                        clip.showPiP = newValue
                        workspace.commitClipEdit(id: clip.id, before: before, after: clip)
                        try? workspace.saveProject()
                        workspace.setShowPiP(newValue, for: clip.id)
                    }
                ))
                .toggleStyle(.checkbox)
            }

            Group {
                Text("Summary").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $clip.summary)
                    .font(.body)
                    .frame(minHeight: 40)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .focused($summaryFocused)
                    .onChange(of: summaryFocused) { _, focused in
                        handleFocusChange(focused: focused, snapshot: $summarySnapshot)
                    }
            }

            Group {
                Text("Transcript").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $clip.transcript)
                    .font(.body)
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .focused($transcriptFocused)
                    .onChange(of: transcriptFocused) { _, focused in
                        handleFocusChange(focused: focused, snapshot: $transcriptSnapshot)
                    }
                transcribeRow
            }

            Group {
                Text("Notes").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $clip.notes)
                    .font(.body)
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .focused($notesFocused)
                    .onChange(of: notesFocused) { _, focused in
                        handleFocusChange(focused: focused, snapshot: $notesSnapshot)
                    }
            }

            Spacer()
        }
        // Safety net: if the EditorView is torn down (selection change,
        // Esc-to-source) while a field still holds an in-flight snapshot,
        // SwiftUI does NOT guarantee the field's focus-loss onChange
        // fires. Flush any remaining snapshots here so the user's edit
        // gets one undo step rather than vanishing. The bound clip is
        // already up-to-date because TextField/TextEditor write through
        // their bindings on every keystroke and TagField commits in its
        // own .onDisappear.
        .onDisappear {
            flush(&nameSnapshot)
            flush(&tagsSnapshot)
            flush(&notesSnapshot)
            flush(&transcriptSnapshot)
            flush(&summarySnapshot)
        }
    }

    @ViewBuilder
    private var transcribeRow: some View {
        let state = coordinator.state(for: clip.id)
        HStack(spacing: 8) {
            Button("Transcribe") {
                coordinator.enqueue(clipID: clip.id)
            }
            .disabled(stateIsInFlight(state))

            if stateIsInFlight(state) {
                ProgressView()
                    .controlSize(.small)
                Text(captionFor(state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        if case .failed(let msg) = state {
            Text(msg)
                .font(.callout)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stateIsInFlight(_ state: TranscriptionState) -> Bool {
        switch state {
        case .transcribing, .summarizing: return true
        default: return false
        }
    }

    private func captionFor(_ state: TranscriptionState) -> String {
        switch state {
        case .transcribing: return "Transcribing…"
        case .summarizing:  return "Summarizing…"
        default:            return ""
        }
    }

    /// Called on every focus transition for one field. On focus-gain,
    /// snapshot the clip; on focus-loss, push one commitClipEdit if the
    /// clip changed and clear the snapshot.
    private func handleFocusChange(focused: Bool, snapshot: Binding<Clip?>) {
        if focused {
            snapshot.wrappedValue = clip
            return
        }
        guard let before = snapshot.wrappedValue, before != clip else {
            snapshot.wrappedValue = nil
            return
        }
        workspace.commitClipEdit(id: clip.id, before: before, after: clip)
        try? workspace.saveProject()
        snapshot.wrappedValue = nil
    }

    /// One-arity flush over an inout snapshot (used by .onDisappear).
    private func flush(_ snapshot: inout Clip?) {
        guard let before = snapshot, before != clip else { snapshot = nil; return }
        workspace.commitClipEdit(id: clip.id, before: before, after: clip)
        try? workspace.saveProject()
        snapshot = nil
    }
}
