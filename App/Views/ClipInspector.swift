import SwiftUI
import VideoCoachCore

/// Right pane: clip metadata editor. Reads/writes go through a `Binding<Clip>`
/// resolved from `selectedClipID`, and each commit calls `workspace.saveProject()`
/// so disk state matches what's on screen.
struct ClipInspector: View {
    @Bindable var workspace: Workspace
    @Binding var selectedClipID: Clip.ID?

    var body: some View {
        Group {
            if let id = selectedClipID, let binding = clipBinding(for: id) {
                EditorView(
                    workspace: workspace,
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Inspector").font(.headline)
            Text("No clip selected").foregroundStyle(.secondary)
            Spacer()
        }
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

private struct EditorView: View {
    let workspace: Workspace
    @Binding var clip: Clip
    let suggestions: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clip").font(.headline)

            Group {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("Clip name", text: $clip.name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { try? workspace.saveProject() }
            }

            Group {
                Text("Tags").font(.caption).foregroundStyle(.secondary)
                TagField(
                    tags: $clip.tags,
                    suggestions: suggestions,
                    onCommit: { try? workspace.saveProject() }
                )
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
                    // TextEditor has no `.onSubmit` (Return inserts a newline),
                    // so we persist on focus loss via .onChange + a save call.
                    // Cheap: ProjectStore writes a small JSON blob.
                    .onChange(of: clip.notes) { _, _ in try? workspace.saveProject() }
            }

            Spacer()
        }
    }
}
