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
            ProjectCommands()
            DebugMenu()
        }

        Window("MPV Bring-up", id: "mpv-debug") {
            MPVDebugWindow()
        }
    }
}

struct DebugMenu: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Debug") {
            Button("Open MPV Bring-up Window") {
                openWindow(id: "mpv-debug")
            }
        }
    }
}
