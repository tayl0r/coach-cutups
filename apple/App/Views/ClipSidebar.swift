import SwiftUI
import VideoCoachCore

/// Left pane: editable project name + a `List` with two sections —
/// collapsible Sources (drag-to-reorder, X to unload) and Clips (selection
/// drives the inspector + preview). Drag-to-reorder rewrites `sortIndex`
/// for clips and re-permutes `sourceIndex` for sources via Workspace.
/// Selection is disabled while recording so users can't switch modes
/// mid-capture.
struct ClipSidebar: View {
    @Bindable var workspace: Workspace
    @Binding var selectedClipID: Clip.ID?
    let appMode: AppMode
    var onRequestDeleteClip: (Clip.ID) -> Void

    /// Persisted across launches — the user picked their preference once,
    /// don't re-impose the default each session.
    @AppStorage("sidebar.sourcesExpanded") private var sourcesExpanded: Bool = true

    private var sortedClips: [Clip] {
        workspace.project.clips.sorted(by: { $0.sortIndex < $1.sortIndex })
    }

    private var isRecording: Bool {
        appMode == .recording || appMode == .recordingStarting
    }

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
            // Selection-aware context menu for Clips. Sources rows have
            // no `.tag()` so they can't be selected and won't ever
            // trigger this — only Clip.IDs land here.
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
            .disabled(isRecording)
        }
    }

    // MARK: - Sources

    @ViewBuilder
    private var sourcesSection: some View {
        Section(isExpanded: $sourcesExpanded) {
            if workspace.project.sourceVideos.isEmpty {
                Text("No source videos · add one from the toolbar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Bookmark Data is Hashable and uniquely identifies a
                // source ref; using it as the ForEach id keeps row
                // identity stable across reorders.
                ForEach(workspace.project.sourceVideos, id: \.bookmark) { src in
                    sourceRow(src)
                }
                .onMove { offsets, dest in
                    Task { try? await workspace.reorderSourceVideos(from: offsets, to: dest) }
                }
            }
        } header: {
            Text("Sources")
        }
    }

    @ViewBuilder
    private func sourceRow(_ src: SourceRef) -> some View {
        // Look the index up by bookmark on every render — cheap (handful
        // of items at most) and stays correct after reorders/removes.
        let idx = workspace.project.sourceVideos.firstIndex(where: { $0.bookmark == src.bookmark })
        let refCount = idx.map { workspace.clipsReferencing(sourceIndex: $0) } ?? 0
        HStack(spacing: 6) {
            Text(src.displayName).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(formatDuration(src.durationSeconds))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button {
                if let i = idx {
                    Task { try? await workspace.removeSourceVideo(at: i) }
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(refCount > 0)
            .help(refCount > 0
                  ? "\(refCount) clip\(refCount == 1 ? "" : "s") reference this source — delete those first"
                  : "Unload this source")
        }
    }

    // MARK: - Clips

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
}

/// Renders a duration as M:SS (or MM:SS when ≥10 minutes). Negative or NaN
/// inputs render as "0:00" rather than producing a misleading "-:--".
func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    let m = total / 60
    let s = total % 60
    return String(format: "%d:%02d", m, s)
}
