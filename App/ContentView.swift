import SwiftUI
import AppKit

struct ContentView: View {
    @State private var workspace = Workspace()
    @State private var openProjectError: String?

    var body: some View {
        VStack {
            PlayerSurface(player: workspace.virtualPlayer)
                .frame(minWidth: 640, minHeight: 360)
            HStack {
                Button("Open Project Folder…") {
                    openProjectFolder()
                }
            }
        }
        .padding()
        .alert(
            "Open Project Failed",
            isPresented: .constant(openProjectError != nil),
            presenting: openProjectError
        ) { _ in
            Button("OK") { openProjectError = nil }
        } message: { Text($0) }
    }

    private func openProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    try await workspace.openProject(folder: url)
                } catch {
                    openProjectError = "Couldn't open project: \(error.localizedDescription)\n\nIf project.json is corrupted, restore it from a backup before retrying."
                }
            }
        }
    }

    // TODO(Phase 7): wire to CaptureSessionController.configure() failure.
    // When configure() throws .permissionDenied, render `permissionDeniedView`
    // instead of the main UI.
    @ViewBuilder
    static func permissionDeniedView() -> some View {
        VStack {
            Text("Video Coach needs camera and microphone access.")
            Text("Open System Settings → Privacy & Security to grant permission, then relaunch.")
            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
            }
        }
    }
}
