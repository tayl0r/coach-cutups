import SwiftUI
import AppKit
import AVFoundation
import VideoCoachCore

struct ContentView: View {
    @State private var workspace = Workspace()
    @State private var selectedClipID: Clip.ID?
    @State private var appMode: AppMode = .scanning
    @State private var openProjectError: String?

    var body: some View {
        NavigationSplitView {
            ClipSidebar(
                workspace: workspace,
                selectedClipID: $selectedClipID,
                appMode: appMode
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            VStack(spacing: 0) {
                ZStack {
                    PlayerSurface(player: currentPlayer)
                    KeyCommandView(
                        player: currentPlayer,
                        onSkip: handleSkip,
                        onTogglePlay: handleTogglePlay
                    )
                    if case .previewLoading = appMode {
                        // Cover the player surface while we wait for the preview
                        // cache to populate. Without this the user briefly sees
                        // whatever frame the previous player was paused on.
                        Color.black.opacity(0.5)
                        ProgressView("Preparing preview…")
                            .controlSize(.regular)
                            .tint(.white)
                            .foregroundStyle(.white)
                    }
                }
                .frame(minWidth: 640, minHeight: 360)

                Divider()

                TransportBar(
                    workspace: workspace,
                    appMode: $appMode,
                    openProjectError: $openProjectError
                )
                .frame(minHeight: 44)
            }
        } detail: {
            ClipInspector(
                workspace: workspace,
                selectedClipID: $selectedClipID
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        }
        #if DEBUG
        .toolbar {
            ToolbarItem(placement: .automatic) {
                // TODO(Phase 7): remove once real recording lands. Lets us
                // exercise the sidebar/inspector/reorder without a working
                // CaptureSessionController.
                Button("Add Stub Clip") { workspace.addStubClip() }
                    .disabled(workspace.folder == nil)
            }
        }
        #endif
        .alert(
            "Open Project Failed",
            isPresented: .constant(openProjectError != nil),
            presenting: openProjectError
        ) { _ in
            Button("OK") { openProjectError = nil }
        } message: { Text($0) }
        .onChange(of: selectedClipID) { _, newID in
            handleSelectionChange(newID)
        }
    }

    // MARK: - Player routing

    private var currentPlayer: AVPlayer? {
        switch appMode {
        case .scanning, .recordingStarting, .recording:
            return workspace.virtualPlayer
        case .previewLoading:
            return nil
        case .previewClip(let id):
            return workspace.previewPlayer(for: id)
        }
    }

    // MARK: - Mode transitions

    private func handleSelectionChange(_ newID: Clip.ID?) {
        guard let newID else { appMode = .scanning; return }
        if workspace.previewPlayer(for: newID) != nil {
            appMode = .previewClip(newID)
            return
        }
        appMode = .previewLoading(newID)
        // TODO(Phase 8): triggered when ClipPreviewBuilder lands. The cache is
        // populated off-main-actor by the builder; this loop polls for the
        // player to appear and flips into `.previewClip`. Without the builder
        // the cache never populates, so we cap the wait at 2 seconds and fall
        // back to `.scanning` to keep Phase 6 testable in isolation.
        Task {
            let deadline = Date().addingTimeInterval(2.0)
            while Date() < deadline {
                if workspace.previewPlayer(for: newID) != nil { break }
                // If selection moved on (or was cleared) while we were waiting,
                // stop polling — a fresh handler is already running.
                guard case .previewLoading(let pid) = appMode, pid == newID else { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard case .previewLoading(let pid) = appMode, pid == newID else { return }
            if workspace.previewPlayer(for: newID) != nil {
                appMode = .previewClip(newID)
            } else {
                // Builder never delivered — drop selection and revert to scanning
                // so the UI doesn't get stuck on the loading overlay.
                selectedClipID = nil
                appMode = .scanning
            }
        }
    }

    // MARK: - Keyboard handling

    private func handleSkip(_ delta: Double) {
        guard let player = currentPlayer else { return }
        let target = player.currentTime() + CMTime(seconds: delta, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func handleTogglePlay() {
        guard let player = currentPlayer else { return }
        player.rate == 0 ? player.play() : player.pause()
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
