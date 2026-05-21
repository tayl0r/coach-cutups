import SwiftUI
import VideoCoachCore

@main
struct VideoCoachApp: App {
    /// Owns the live device list + the menu's selection state. Created here
    /// so the same instance is shared between the menu (via `.commands`) and
    /// `ContentView`.
    @State private var deviceCatalog: DeviceCatalog

    /// Project + recording state. Owned at the App level so the
    /// transcription coordinator can be constructed with a reference to
    /// it AT INIT TIME (no placeholder + rebind pattern).
    @State private var workspace: Workspace

    /// AI transcription pipeline. Built once at app launch with the
    /// real `AppleClipIntelligence`; bound to the workspace owned above.
    @State private var transcription: TranscriptionCoordinator

    init() {
        let catalog = DeviceCatalog()
        let ws = Workspace()
        let tc = TranscriptionCoordinator(
            workspace: ws,
            intelligence: AppleClipIntelligence()
        )
        _deviceCatalog = State(initialValue: catalog)
        _workspace     = State(initialValue: ws)
        _transcription = State(initialValue: tc)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                deviceCatalog: deviceCatalog,
                workspace: workspace,
                transcription: transcription
            )
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
