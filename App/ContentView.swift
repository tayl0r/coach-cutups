import SwiftUI

struct ContentView: View {
    var body: some View {
        Text("Video Coach")
            .font(.largeTitle)
            .padding()
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
