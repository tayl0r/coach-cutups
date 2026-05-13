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
    /// Host time (`CACurrentMediaTime()`) when the active recording's t=0
    /// landed. Drives the live elapsed counter in `RecordingTransport`.
    /// nil when not recording.
    var recordingStartedAtHostTime: Double?
    /// Invoked when the user clicks the Stop button during `.recording`.
    /// Wired by `ContentView` to the same handler as the R/Esc key path.
    var onStopRecording: () -> Void
    /// Invoked when the user clicks the Close button during `.previewClip`.
    /// Wired by `ContentView` to clear `selectedClipID`, which deselects the
    /// sidebar row and routes `appMode` back to `.scanning`.
    var onClosePreview: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            switch appMode {
            case .scanning:
                ScanningTransport(
                    workspace: workspace,
                    openProjectError: $openProjectError
                )
            case .recordingStarting, .recording:
                RecordingTransport(
                    workspace: workspace,
                    appMode: $appMode,
                    startedAtHostTime: recordingStartedAtHostTime,
                    onStop: onStopRecording
                )
            case .previewLoading:
                ProgressView("Preparing preview…")
                    .controlSize(.small)
                Spacer()
                Button(action: onClosePreview) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Cancel and return to source (Esc)")
            case .previewClip(let id):
                PreviewTransport(
                    workspace: workspace,
                    clipID: id,
                    onClose: onClosePreview
                )
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
    /// While the user is dragging the scrubber, we hold the slider's value
    /// at `sliderValue` so live `timePos` updates don't fight the drag. On
    /// release (`onEditingChanged(false)`), we seek and stop holding.
    @State private var sliderValue: Double = 0
    @State private var isDragging: Bool = false

    /// Player position in cumulative-concat seconds. Reads `playlistPos`
    /// and `timePos` (both `@Observable`) so SwiftUI redraws as playback
    /// advances.
    private var cumulativeCurrent: Double {
        guard let p = workspace.sourcePlayer, p.hasLoadedFile else { return 0 }
        return workspace.project.cumulativeOffset(forSourceIndex: p.playlistPos) + p.timePos
    }
    private var totalDuration: Double {
        workspace.project.totalSourceDuration
    }

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
            .disabled(workspace.sourcePlayer == nil)
            .help(isPlaying ? "Pause" : "Play")

            // Scrubber. Bound to a "lifted" value so the user's drag isn't
            // fought by live timePos updates. While dragging, the slider
            // holds the user's value; on release we seek and stop holding.
            Slider(
                value: Binding(
                    get: { isDragging ? sliderValue : cumulativeCurrent },
                    set: { sliderValue = $0 }
                ),
                in: 0...max(totalDuration, 0.001),
                onEditingChanged: { editing in
                    isDragging = editing
                    if !editing { seekTo(sliderValue) }
                }
            )
            .disabled(workspace.sourcePlayer == nil || totalDuration <= 0)
            .frame(maxWidth: .infinity)

            Text(formatDurationHMS(cumulativeCurrent) + " / " + formatDurationHMS(totalDuration))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                Slider(
                    value: Bindable(workspace).project.preferences.scanVolume,
                    in: 0...1
                )
                .frame(width: 120)
                .onChange(of: workspace.project.preferences.scanVolume) { _, new in
                    workspace.sourcePlayer?.setVolume(new)
                    // TODO(Phase 10): debounce + persist on slider release rather
                    // than every drag tick. For now we accept the write amplification.
                    try? workspace.saveProject()
                }
            }

            Spacer()
        }
    }

    private var isPlaying: Bool {
        guard let p = workspace.sourcePlayer else { return false }
        return !p.isPaused
    }

    private func togglePlay() {
        guard let player = workspace.sourcePlayer else { return }
        if player.isPaused {
            player.setVolume(workspace.project.preferences.scanVolume)
            player.play()
        } else {
            player.pause()
        }
    }

    /// Drag-release seek. Mirrors the cumulative→per-file translation used
    /// in `ContentView.handleSkip`'s source branch. We bump the player's
    /// generation so any in-flight FF/RW seek from the SkipCoordinator path
    /// is dropped — the user's drag is the new authoritative target.
    private func seekTo(_ cumulativeSeconds: Double) {
        guard let player = workspace.sourcePlayer else { return }
        let endEpsilon: Double = 0.05
        let total = totalDuration
        let clamped = max(0, min(cumulativeSeconds, max(0, total - endEpsilon)))
        let mapped = workspace.sourceTime(at: clamped)
        player.bumpGeneration()
        player.seek(
            playlistPos: mapped.sourceIndex,
            timeSeconds: mapped.sourceLocalSeconds,
            exact: true,
            completion: {}
        )
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
            Task {
                do {
                    try await workspace.addSourceVideo(url: url)
                } catch {
                    await MainActor.run {
                        openProjectError = "Couldn't add source: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}

// MARK: - Recording

/// Mode B controls. While `appMode == .recordingStarting`, the REC dot is
/// yellow and the Stop button is disabled (we're still waiting for the first
/// sample buffer — see `CaptureSessionController.startRecording`). Once the
/// first sample lands and `appMode` flips to `.recording`, the dot turns red
/// and the Stop button is enabled.
struct RecordingTransport: View {
    @Bindable var workspace: Workspace
    @Binding var appMode: AppMode
    /// Host time of t=0 for the active recording. Used to derive elapsed
    /// time. nil while `.recordingStarting`.
    var startedAtHostTime: Double?
    var onStop: () -> Void

    private var isStarting: Bool { appMode == .recordingStarting }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(isStarting ? Color.yellow : Color.red)
                .frame(width: 12, height: 12)
                .overlay(
                    // Subtle outer ring while starting so the user reads
                    // "preparing" rather than "recording".
                    Circle()
                        .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                )
            Text(isStarting ? "Preparing recording…" : "Recording")
                .font(.subheadline)
                .foregroundStyle(.primary)
                .monospacedDigit()

            // Live elapsed counter. TimelineView ticks at 1Hz so the digits
            // only redraw once per second — cheaper than a 30Hz redraw and
            // matches the seconds resolution we're displaying.
            if !isStarting, let startedAt = startedAtHostTime {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let elapsed = max(0, CACurrentMediaTime() - startedAt)
                    Text(formatElapsed(elapsed))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button(action: onStop) {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                    Text("Stop")
                }
            }
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(isStarting)
            .help("Stop recording (R or Esc)")
        }
    }

    private func formatElapsed(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Preview (Mode C)

/// Mode C controls: play/pause for the cached preview player, a scrubber
/// driven by a periodic time observer, and the two mix sliders. The actual
/// `AVMutableAudioMix` rebuild on slider change is Phase 8 territory.
struct PreviewTransport: View {
    @Bindable var workspace: Workspace
    let clipID: Clip.ID
    var onClose: () -> Void
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isPlaying: Bool = false
    /// Bundles the time-observer token with the AVPlayer it was registered
    /// against. Removing a token from the WRONG player throws an Obj-C
    /// exception (which crashes the process), so we must keep the pair
    /// together. The plain `player` computed property resolves to the
    /// *current* clip's player — fine for play/pause/seek, but useless for
    /// removeTimeObserver after a clip switch.
    @State private var observerBinding: ObserverBinding?

    private struct ObserverBinding {
        let player: AVPlayer
        let token: Any
    }

    private var player: AVPlayer? { workspace.previewPlayer(for: clipID) }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Label("Source", systemImage: "chevron.left")
            }
            .help("Close clip preview and return to source (Esc)")

            Divider().frame(height: 20)

            Button(action: togglePlay) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .disabled(player == nil)

            // Scrubber. Bound to currentTime; on edit-end we seek the player.
            // Tolerance is `.positiveInfinity` (snap to nearest keyframe) —
            // exact-frame seek (.zero / .zero) on long-GOP HEVC requires
            // decoding back to the nearest IDR (often 1-2s away on match
            // footage), and during that decode window the compositor renders
            // black. For preview scrubbing the user can't perceive the
            // few-frame snap; instant response wins.
            Slider(
                value: $currentTime,
                in: 0...max(duration, 0.001),
                onEditingChanged: { editing in
                    guard !editing, let player else { return }
                    player.seek(
                        to: CMTime(seconds: currentTime, preferredTimescale: 600),
                        toleranceBefore: .positiveInfinity,
                        toleranceAfter: .positiveInfinity
                    )
                }
            )
            .disabled(player == nil || duration <= 0)

            Text(formatDuration(currentTime) + " / " + formatDuration(duration))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Divider().frame(height: 20)

            // Live audio mix update — rebuild AVMutableAudioMix on every
            // slider tick (cheap; ~2 microseconds per build) and reassign to
            // `currentItem.audioMix`. Mutating an existing mix in place
            // doesn't take effect on a playing item, only reassignment does.
            // Persistence is debounced via `onCommit` (slider release) to
            // avoid write amplification on `project.json`.
            VolumeSlider(
                label: "Source",
                value: Bindable(workspace).project.preferences.previewSourceVolume,
                onChange: { _ in workspace.updatePreviewVolumes(for: clipID) },
                onCommit: { try? workspace.saveProject() }
            )
            VolumeSlider(
                label: "Commentary",
                value: Bindable(workspace).project.preferences.previewCommentaryVolume,
                onChange: { _ in workspace.updatePreviewVolumes(for: clipID) },
                onCommit: { try? workspace.saveProject() }
            )

            Spacer()
        }
        .onAppear { attachObserver() }
        .onDisappear { detachObserver() }
        .onChange(of: clipID) { _, _ in
            // Detach uses observerBinding (which holds the OLD player); attach
            // grabs the NEW player from the computed property. Order matters
            // — detach first so the old player's observer is cleanly removed
            // before we install a new one.
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
        let token = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            currentTime = time.seconds.isFinite ? time.seconds : 0
            isPlaying = player.rate != 0
            // Duration may resolve asynchronously after the player item loads.
            if duration <= 0, let item = player.currentItem,
               item.duration.seconds.isFinite, item.duration.seconds > 0 {
                duration = item.duration.seconds
            }
        }
        observerBinding = ObserverBinding(player: player, token: token)
    }

    private func detachObserver() {
        // CRITICAL: remove the token from the SAME AVPlayer it was registered
        // against. Removing from a different player throws
        // NSInternalInconsistencyException which crashes the process.
        if let binding = observerBinding {
            binding.player.removeTimeObserver(binding.token)
        }
        observerBinding = nil
    }
}

/// `H:MM:SS` when hours > 0, else `M:SS`. Used by the source-mode scrubber
/// because the cumulative concat timeline frequently exceeds an hour. The
/// module-internal `formatDuration` (in `ClipSidebar.swift`) emits M:SS
/// only and is kept for short clip durations.
fileprivate func formatDurationHMS(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%d:%02d", m, s)
}

private struct VolumeSlider: View {
    let label: String
    @Binding var value: Double
    /// Fires on every value change (slider drag). Used by Mode C to live-
    /// rebuild the player's `AVMutableAudioMix` so volume changes take
    /// effect during playback.
    var onChange: ((Double) -> Void)? = nil
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
            .onChange(of: value) { _, new in onChange?(new) }
        }
    }
}
