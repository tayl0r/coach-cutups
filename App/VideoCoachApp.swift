import SwiftUI

@main
struct VideoCoachApp: App {
    /// Owns the live device list + the menu's selection state. Created here
    /// so the same instance is shared between the menu (via `.commands`) and
    /// `ContentView` (which observes selection changes and drives the
    /// capture session). `@State` rather than `@StateObject` because
    /// `DeviceCatalog` is `@Observable`, not `ObservableObject`.
    @State private var deviceCatalog = DeviceCatalog()

    var body: some Scene {
        WindowGroup {
            ContentView(deviceCatalog: deviceCatalog)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .commands {
            DevicesCommands(catalog: deviceCatalog)
            ClipCommands()
            DebugMenu()
        }

        Window("MPV Bring-up", id: "mpv-debug") {
            MPVDebugWindow()
        }

        Window("GL Bridge Demo", id: "gl-bridge-demo") {
            GLBridgeDemoRepresentable(r: 1, g: 0, b: 0)
        }
    }
}

struct DebugMenu: Commands {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MPVRenderBackend.userDefaultsKey) private var renderBackendRaw: String = MPVRenderBackend.glToMetal.rawValue

    var body: some Commands {
        CommandMenu("Debug") {
            Button("Open MPV Bring-up Window") {
                openWindow(id: "mpv-debug")
            }
            Button("GL Bridge Demo (Red)") {
                openWindow(id: "gl-bridge-demo")
            }
            Divider()
            Menu("Render Backend (relaunch to apply to main view)") {
                Button(checkmark(.glToMetal) + MPVRenderBackend.glToMetal.displayName) {
                    renderBackendRaw = MPVRenderBackend.glToMetal.rawValue
                }
                Button(checkmark(.sw) + MPVRenderBackend.sw.displayName) {
                    renderBackendRaw = MPVRenderBackend.sw.rawValue
                }
            }
        }
    }

    private func checkmark(_ backend: MPVRenderBackend) -> String {
        renderBackendRaw == backend.rawValue ? "✓ " : "  "
    }
}
