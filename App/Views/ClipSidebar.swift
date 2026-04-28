import SwiftUI
import VideoCoachCore

/// Left pane: editable project name + a `List` of clips bound to
/// `selectedClipID`. Drag-to-reorder rewrites `sortIndex` via
/// `Workspace.reorderClips`. Selection is disabled while recording so users
/// can't switch modes mid-capture.
struct ClipSidebar: View {
    @Bindable var workspace: Workspace
    @Binding var selectedClipID: Clip.ID?
    let appMode: AppMode
    /// Pops the destructive confirm alert. Owned by ContentView so the alert
    /// has access to the workspace + selection state.
    var onRequestDeleteClip: (Clip.ID) -> Void

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
                    .contextMenu {
                        Button(role: .destructive) {
                            onRequestDeleteClip(clip.id)
                        } label: {
                            Label("Delete Clip…", systemImage: "trash")
                        }
                        .disabled(isRecording)
                    }
                }
                .onMove { indices, dest in
                    workspace.reorderClips(from: indices, to: dest)
                }
            }
            .disabled(isRecording)
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
