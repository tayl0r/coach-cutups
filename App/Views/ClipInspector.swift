import SwiftUI
import VideoCoachCore

/// Right pane: clip metadata editor. Phase 6.1 ships a placeholder version
/// that just shows the selected clip's name as readable text; Phase 6.2
/// fleshes this out with TextFields, a notes editor, and `TagField`.
struct ClipInspector: View {
    @Bindable var workspace: Workspace
    @Binding var selectedClipID: Clip.ID?

    private var selectedClip: Clip? {
        guard let id = selectedClipID else { return nil }
        return workspace.project.clips.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Inspector")
                .font(.headline)
            if let clip = selectedClip {
                Text(clip.name)
                Text("(metadata editor: Phase 6.2)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No clip selected")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
