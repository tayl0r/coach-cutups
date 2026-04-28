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
            if let binding = clipBinding {
                EditorView(
                    workspace: workspace,
                    clip: binding,
                    suggestions: tagSuggestions
                )
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

    /// Direct binding into `workspace.project.clips[idx]`. Returns nil when no
    /// clip is selected (or the selected clip was deleted out from under us);
    /// the inspector falls back to the placeholder in that case.
    private var clipBinding: Binding<Clip>? {
        guard let id = selectedClipID,
              let idx = workspace.project.clips.firstIndex(where: { $0.id == id })
        else { return nil }
        return Binding(
            get: { workspace.project.clips[idx] },
            set: { workspace.project.clips[idx] = $0 }
        )
    }

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
