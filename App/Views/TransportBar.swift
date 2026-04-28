import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import VideoCoachCore

/// Switches the bar's contents on `appMode` so each mode shows only the
/// controls that actually do something. Phase 6.1 ships `ScanningTransport`
/// fully and stubs the recording / preview transports for later phases.
struct TransportBar: View {
    @Bindable var workspace: Workspace
    @Binding var appMode: AppMode
    @Binding var openProjectError: String?

    var body: some View {
        HStack(spacing: 12) {
            switch appMode {
            case .scanning:
                ScanningTransport(
                    workspace: workspace,
                    openProjectError: $openProjectError
                )
            case .recordingStarting, .recording:
                RecordingTransport(workspace: workspace, appMode: $appMode)
            case .previewLoading:
                ProgressView("Preparing preview…")
                    .controlSize(.small)
                Spacer()
            case .previewClip(let id):
                PreviewTransport(workspace: workspace, clipID: id)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Scanning

/// Mode A controls: open/add commands, transport for the virtual concat,
/// and the scan-volume slider that gates how loud the source plays back
/// while the user is reviewing footage (and during recording).
struct ScanningTransport: View {
    @Bindable var workspace: Workspace
    @Binding var openProjectError: String?

    var body: some View {
        HStack(spacing: 12) {
            Button("Open Project Folder…") { openProjectFolder() }
            Button("Add Source Video…") { addSourceVideo() }
                .disabled(workspace.folder == nil)

            Divider().frame(height: 20)

            Button(action: togglePlay) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .disabled(workspace.virtualPlayer == nil)
            .help(isPlaying ? "Pause" : "Play")

            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                Slider(
                    value: Bindable(workspace).project.preferences.scanVolume,
                    in: 0...1
                )
                .frame(width: 120)
                .onChange(of: workspace.project.preferences.scanVolume) { _, new in
                    workspace.virtualPlayer?.volume = Float(new)
                    // TODO(Phase 10): debounce + persist on slider release rather
                    // than every drag tick. For now we accept the write amplification.
                    try? workspace.saveProject()
                }
            }

            Spacer()
        }
    }

    private var isPlaying: Bool {
        (workspace.virtualPlayer?.rate ?? 0) != 0
    }

    private func togglePlay() {
        guard let player = workspace.virtualPlayer else { return }
        if player.rate == 0 {
            player.volume = Float(workspace.project.preferences.scanVolume)
            player.play()
        } else {
            player.pause()
        }
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

    private func addSourceVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { try? await workspace.addSourceVideo(url: url) }
        }
    }
}

// MARK: - Recording (placeholder)

/// Phase 7 wires this to `RecordingController`. For Phase 6.1 we ship a
/// placeholder so the switch above type-checks and the layout slots are
/// visible during manual UI exploration.
struct RecordingTransport: View {
    @Bindable var workspace: Workspace
    @Binding var appMode: AppMode

    var body: some View {
        HStack {
            Text("Recording (Phase 7)")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

// MARK: - Preview (Mode C)

/// Mode C controls: play/pause for the cached preview player, a scrubber
/// driven by a periodic time observer, and the two mix sliders. The actual
/// `AVMutableAudioMix` rebuild on slider change is Phase 8 territory.
struct PreviewTransport: View {
    @Bindable var workspace: Workspace
    let clipID: Clip.ID
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isPlaying: Bool = false
    @State private var timeObserver: Any?

    private var player: AVPlayer? { workspace.previewPlayer(for: clipID) }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: togglePlay) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .disabled(player == nil)

            // Scrubber. Bound to currentTime; on edit-end we seek the player.
            Slider(
                value: $currentTime,
                in: 0...max(duration, 0.001),
                onEditingChanged: { editing in
                    guard !editing, let player else { return }
                    player.seek(
                        to: CMTime(seconds: currentTime, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    )
                }
            )
            .disabled(player == nil || duration <= 0)

            Text(formatDuration(currentTime) + " / " + formatDuration(duration))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Divider().frame(height: 20)

            // TODO(Phase 8): debounce + live audio mix update. Rebuild
            // AVMutableAudioMix from the new volume and assign to
            // player.currentItem?.audioMix on slider release.
            VolumeSlider(
                label: "Source",
                value: Bindable(workspace).project.preferences.previewSourceVolume,
                onCommit: { try? workspace.saveProject() }
            )
            VolumeSlider(
                label: "Commentary",
                value: Bindable(workspace).project.preferences.previewCommentaryVolume,
                onCommit: { try? workspace.saveProject() }
            )

            Spacer()
        }
        .onAppear { attachObserver() }
        .onDisappear { detachObserver() }
        .onChange(of: clipID) { _, _ in
            detachObserver()
            attachObserver()
        }
    }

    private func togglePlay() {
        guard let player else { return }
        if player.rate == 0 { player.play() } else { player.pause() }
        isPlaying = player.rate != 0
    }

    private func attachObserver() {
        guard let player else { return }
        if let item = player.currentItem {
            duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
        }
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            currentTime = time.seconds.isFinite ? time.seconds : 0
            isPlaying = player.rate != 0
            // Duration may resolve asynchronously after the player item loads.
            if duration <= 0, let item = player.currentItem,
               item.duration.seconds.isFinite, item.duration.seconds > 0 {
                duration = item.duration.seconds
            }
        }
    }

    private func detachObserver() {
        if let token = timeObserver, let player {
            player.removeTimeObserver(token)
        }
        timeObserver = nil
    }
}

private struct VolumeSlider: View {
    let label: String
    @Binding var value: Double
    let onCommit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Slider(
                value: $value,
                in: 0...1,
                onEditingChanged: { editing in if !editing { onCommit() } }
            )
            .frame(width: 100)
        }
    }
}
