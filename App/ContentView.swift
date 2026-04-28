import SwiftUI
import AppKit
import AVFoundation
import VideoCoachCore

struct ContentView: View {
    /// Owned by `VideoCoachApp` so the same instance backs both the
    /// top-level Devices menu and this view's onChange handlers. Passed in
    /// rather than created here so the menu's selection edits actually
    /// reach the capture session.
    @Bindable var deviceCatalog: DeviceCatalog

    @State private var workspace = Workspace()
    @State private var selectedClipID: Clip.ID?
    @State private var appMode: AppMode = .scanning
    @State private var openProjectError: String?

    // MARK: - Capture / recording state

    @State private var capture = CaptureSessionController()
    /// Surfaces a `ClipPreviewBuilder` failure as a one-shot alert. Cleared
    /// when the user dismisses; the failure stays in
    /// `Workspace._previewFailed` so re-selecting the same clip surfaces it
    /// again rather than silently retrying.
    @State private var previewBuildErrorAlert: String?
    /// Set when capture configuration fails because the user denied camera
    /// or microphone access. Renders `permissionDeniedView()` in place of
    /// the main UI so the user sees how to fix it.
    @State private var permissionDenied = false
    /// Set when a previously-saved preferred camera/mic isn't present (e.g.
    /// USB camera unplugged between sessions). Surfaced as a non-fatal
    /// alert; the session keeps running with the system default.
    @State private var deviceFallbackAlert: String?
    /// Active during `.recording`. Created on the main actor only after the
    /// first sample buffer lands. nil between recordings.
    @State private var recordingController: RecordingController?
    /// Captured at R-press time so the finished clip can record where in the
    /// virtual concat the recording started, even if the playhead has moved
    /// in the interim.
    @State private var pendingRecording: PendingRecording?
    /// Auto-clear toggle for the drawing overlay during recording. When on,
    /// finished strokes get `autoClearAfterSeconds = 5.0`; otherwise nil
    /// (persists until the user clicks Clear All).
    @State private var autoClearStrokes = true
    /// Bumped to push a `clearAll` into the live drawing overlay; the
    /// overlay's NSViewRepresentable diffs the value to fire `clearAll()`
    /// at most once per change.
    @State private var drawingClearToken = 0
    @State private var recordingError: String?

    private struct PendingRecording {
        var clipID: UUID
        var filename: String
        var sourceIndex: Int
        var startSourceSeconds: Double
    }

    var body: some View {
        rootContent
            .modifier(AlertsModifier(
                openProjectError: $openProjectError,
                recordingError: $recordingError,
                deviceFallbackAlert: $deviceFallbackAlert,
                previewBuildErrorAlert: $previewBuildErrorAlert
            ))
            .modifier(DeviceWiringModifier(
                appMode: appMode,
                workspaceFolder: workspace.folder,
                catalog: deviceCatalog,
                onProjectOpened: seedAndApplyPreferredDevices,
                onCameraChange: handleCameraSelectionChange,
                onMicChange: handleMicSelectionChange
            ))
            .onChange(of: selectedClipID) { _, newID in
                handleSelectionChange(newID)
            }
            .task {
                // Configure the capture session once on first appearance.
                // If the user denies permission, surface
                // `permissionDeniedView()`. Preferred IDs aren't known yet
                // — no project is open at this point — so we use system
                // defaults; the project-opened handler swaps to the saved
                // devices afterward.
                do {
                    try await capture.configure()
                } catch CaptureError.permissionDenied {
                    permissionDenied = true
                } catch {
                    // Capture-config failures other than permission denial
                    // fail softly: the user can still scan footage,
                    // recording is just disabled. Pressing R will surface
                    // the error via the alert.
                }
            }
    }

    @ViewBuilder
    private var rootContent: some View {
        if permissionDenied {
            Self.permissionDeniedView()
        } else {
            mainSplit
        }
    }

    // MARK: - Device handling

    /// Called when a project just finished opening (or was switched). Reads
    /// the project's preferred camera/mic IDs into the catalog and asks the
    /// capture session to switch to them. If the saved device is gone, we
    /// fall back to system default and surface a one-shot alert; the
    /// preference is intentionally NOT cleared so reattaching the device
    /// restores it.
    private func seedAndApplyPreferredDevices() {
        let cameraID = workspace.project.preferences.preferredCameraID
        let micID = workspace.project.preferences.preferredMicID
        // Seed the catalog WITHOUT firing the onChange handlers' usual
        // save-back logic — we set the IDs to match the project, so
        // there's no new value to save. The onChange handlers will see
        // `oldID == newID` for the project's saved values and bail early
        // (Picker assignment with the same value is a no-op anyway).
        deviceCatalog.selectedCameraID = cameraID
        deviceCatalog.selectedMicID = micID

        Task {
            var fallbackMessages: [String] = []
            if cameraID != nil {
                do {
                    try await capture.switchVideoDevice(uniqueID: cameraID)
                } catch CaptureError.deviceUnavailable {
                    fallbackMessages.append(
                        "Saved camera was unavailable; falling back to the system default."
                    )
                    try? await capture.switchVideoDevice(uniqueID: nil)
                    // Reflect reality in the menu so the checkmark is on
                    // "System Default", but DON'T overwrite the project's
                    // preferredCameraID — leave it so reattaching the
                    // device restores the selection on next launch.
                    deviceCatalog.selectedCameraID = nil
                } catch {
                    // Other errors (permission, AVFoundation refusing the
                    // input) fall through silently — recording will surface
                    // the underlying problem when the user presses R.
                }
            }
            if micID != nil {
                do {
                    try await capture.switchAudioDevice(uniqueID: micID)
                } catch CaptureError.deviceUnavailable {
                    fallbackMessages.append(
                        "Saved microphone was unavailable; falling back to the system default."
                    )
                    try? await capture.switchAudioDevice(uniqueID: nil)
                    deviceCatalog.selectedMicID = nil
                } catch {
                    // Same rationale as the camera branch.
                }
            }
            if !fallbackMessages.isEmpty {
                await MainActor.run {
                    self.deviceFallbackAlert = fallbackMessages.joined(separator: "\n")
                }
            }
        }
    }

    private func handleCameraSelectionChange(_ newID: String?) {
        // Don't try to swap mid-recording — the menu disables itself in
        // that state, but a stale notification could still slip through.
        guard !deviceCatalog.lockedByRecording else { return }
        // No-op if the project's saved preference already matches —
        // happens during `seedAndApplyPreferredDevices`.
        if workspace.project.preferences.preferredCameraID == newID,
           capture.videoDeviceUniqueID == newID
        { return }
        Task {
            do {
                try await capture.switchVideoDevice(uniqueID: newID)
                await MainActor.run {
                    workspace.project.preferences.preferredCameraID = newID
                    try? workspace.saveProject()
                }
            } catch CaptureError.deviceUnavailable(let id) {
                await MainActor.run {
                    self.deviceFallbackAlert = "Camera (\(String(id.prefix(12)))…) was unavailable."
                    // Revert the menu selection back to whatever the
                    // session is actually using right now.
                    self.deviceCatalog.selectedCameraID = self.capture.videoDeviceUniqueID
                }
            } catch CaptureError.alreadyRecording {
                // Stop trying — UI was supposed to disable. Revert the
                // menu so the checkmark stays on the live device.
                await MainActor.run {
                    self.deviceCatalog.selectedCameraID = self.capture.videoDeviceUniqueID
                }
            } catch {
                await MainActor.run {
                    self.deviceFallbackAlert = "Couldn't switch camera: \(error.localizedDescription)"
                    self.deviceCatalog.selectedCameraID = self.capture.videoDeviceUniqueID
                }
            }
        }
    }

    private func handleMicSelectionChange(_ newID: String?) {
        guard !deviceCatalog.lockedByRecording else { return }
        if workspace.project.preferences.preferredMicID == newID,
           capture.audioDeviceUniqueID == newID
        { return }
        Task {
            do {
                try await capture.switchAudioDevice(uniqueID: newID)
                await MainActor.run {
                    workspace.project.preferences.preferredMicID = newID
                    try? workspace.saveProject()
                }
            } catch CaptureError.deviceUnavailable(let id) {
                await MainActor.run {
                    self.deviceFallbackAlert = "Microphone (\(String(id.prefix(12)))…) was unavailable."
                    self.deviceCatalog.selectedMicID = self.capture.audioDeviceUniqueID
                }
            } catch CaptureError.alreadyRecording {
                await MainActor.run {
                    self.deviceCatalog.selectedMicID = self.capture.audioDeviceUniqueID
                }
            } catch {
                await MainActor.run {
                    self.deviceFallbackAlert = "Couldn't switch microphone: \(error.localizedDescription)"
                    self.deviceCatalog.selectedMicID = self.capture.audioDeviceUniqueID
                }
            }
        }
    }

    private var mainSplit: some View {
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
                    // Mode C overlays — only mounted when previewing so the
                    // periodic time observer in StrokeReplayLayer doesn't run
                    // during scanning/recording.
                    if case .previewClip(let id) = appMode,
                       let player = workspace.previewPlayer(for: id),
                       let clip = workspace.project.clips.first(where: { $0.id == id }) {
                        StrokeReplayOverlay(player: player, clip: clip)
                            .allowsHitTesting(false)
                        previewTextBar(for: clip)
                            .allowsHitTesting(false)
                    }
                    if appMode == .recording {
                        // Drawing overlay sits between the player and the key
                        // monitor — clicks/drags here become strokes; everything
                        // else (keyboard) keeps falling through.
                        DrawingOverlay(
                            autoClearAfterSeconds: autoClearStrokes ? 5.0 : nil,
                            onStrokeFinished: { stroke in
                                recordingController?.appendStroke(stroke)
                            },
                            clearAllToken: drawingClearToken
                        )
                    }
                    KeyCommandView(
                        player: currentPlayer,
                        appMode: appMode,
                        onSkip: handleSkip,
                        onTogglePlay: handleTogglePlay,
                        onToggleRecord: handleToggleRecord,
                        onClosePreview: handleClosePreview
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

                if appMode == .recording {
                    Divider()
                    drawingToolbar
                }

                Divider()

                TransportBar(
                    workspace: workspace,
                    appMode: $appMode,
                    openProjectError: $openProjectError,
                    onStopRecording: handleToggleRecord,
                    onClosePreview: handleClosePreview
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
    }

    /// Bottom strip mirroring the export's text bar: dark background pinned
    /// to the bottom 8% of the player area, white "i/N, name, tags" text.
    /// Mode C only ever previews a single clip at a time so the index is
    /// always 1/1.
    @ViewBuilder
    private func previewTextBar(for clip: Clip) -> some View {
        VStack {
            Spacer()
            HStack {
                Text(textBarLine(for: clip))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                Spacer()
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.6))
        }
    }

    private func textBarLine(for clip: Clip) -> String {
        var parts: [String] = ["1/1", clip.name]
        if !clip.tags.isEmpty { parts.append(clip.tags.joined(separator: " ")) }
        return parts.joined(separator: ", ")
    }

    private var drawingToolbar: some View {
        HStack(spacing: 12) {
            Toggle("Auto-clear (5s)", isOn: $autoClearStrokes)
                .toggleStyle(.checkbox)
            Button("Clear All") {
                drawingClearToken &+= 1
                recordingController?.appendClearAll()
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
        // Pause whatever was playing — switching selection should park the
        // prior player so audio doesn't bleed across clips.
        workspace.virtualPlayer?.pause()
        if case .previewClip(let priorID) = appMode {
            workspace.previewPlayer(for: priorID)?.pause()
        }

        guard let newID else { appMode = .scanning; return }

        // Already-cached: instant transition.
        if workspace.previewPlayer(for: newID) != nil {
            appMode = .previewClip(newID)
            return
        }
        // Already-failed: surface and revert to scanning. Don't loop into
        // .previewLoading; the build won't be re-attempted while the failure
        // is recorded.
        if let err = workspace.previewBuildError(for: newID) {
            previewBuildErrorAlert = err.localizedDescription
            appMode = .scanning
            return
        }

        // Cache miss + no prior failure: kick off the build (the call to
        // previewPlayer above already started the Task; that's intentional
        // — the inflight Set deduplicates) and poll for completion.
        appMode = .previewLoading(newID)
        Task {
            // 50ms ticks until either the cache populates or an error lands.
            // Bails out if the user re-selects a different clip mid-load.
            for _ in 0..<400 { // ~20s upper bound — long-GOP HEVC freeze pre-decode can be slow
                try? await Task.sleep(nanoseconds: 50_000_000)
                if Task.isCancelled { return }
                let stillPending: Bool = await MainActor.run {
                    if self.selectedClipID != newID { return false }
                    if self.workspace.previewPlayer(for: newID) != nil {
                        self.appMode = .previewClip(newID)
                        return false
                    }
                    if let err = self.workspace.previewBuildError(for: newID) {
                        self.previewBuildErrorAlert = err.localizedDescription
                        self.appMode = .scanning
                        return false
                    }
                    return true
                }
                if !stillPending { return }
            }
            // Timeout fallback — preserve the user's selection in the
            // inspector but stop pretending we're loading.
            await MainActor.run {
                if case .previewLoading(let pendingID) = self.appMode, pendingID == newID {
                    self.previewBuildErrorAlert = "Preview took too long to prepare. Try again."
                    self.appMode = .scanning
                }
            }
        }
    }

    // MARK: - Keyboard handling

    private func handleSkip(_ delta: Double) {
        guard let player = currentPlayer else { return }
        let target = player.currentTime() + CMTime(seconds: delta, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        if appMode == .recording { recordingController?.appendSkip(delta: delta) }
    }

    private func handleTogglePlay() {
        guard let player = currentPlayer else { return }
        let wasPlaying = player.rate != 0
        wasPlaying ? player.pause() : player.play()
        if appMode == .recording {
            wasPlaying
                ? recordingController?.appendPause()
                : recordingController?.appendPlay()
        }
    }

    private func handleToggleRecord() {
        switch appMode {
        case .scanning:
            startRecording()
        case .recording:
            stopRecording()
        default:
            break    // ignored — gating is also enforced in KeyCommandView
        }
    }

    /// Deselect the current clip and route the player back to the source
    /// virtual concat. Wired to the Source button in `PreviewTransport` and
    /// to the Esc key when `appMode` is a preview state.
    private func handleClosePreview() {
        // Pause the preview player so audio doesn't keep playing if AVPlayer
        // somehow holds a reference past the swap.
        workspace.previewPlayer(for: selectedClipID ?? UUID())?.pause()
        selectedClipID = nil
    }

    // MARK: - Recording flow

    private func startRecording() {
        guard let recordingsDir = workspace.recordingsDir else {
            recordingError = "Open a project folder before recording."
            return
        }
        guard let player = workspace.virtualPlayer else {
            recordingError = "Add a source video before recording."
            return
        }
        appMode = .recordingStarting

        let clipID = UUID()
        let filename = "clip-\(clipID).mov"
        let url = recordingsDir.appendingPathComponent(filename)

        // Capture (sourceIndex, startSourceSeconds) as the playhead is RIGHT
        // NOW. The playhead may move while we await the first sample; the
        // clip's source mapping is anchored to R-press, not to first-frame.
        let global = player.currentTime().seconds
        let mapped = workspace.sourceTime(at: global.isFinite ? global : 0)
        pendingRecording = PendingRecording(
            clipID: clipID,
            filename: filename,
            sourceIndex: mapped.sourceIndex,
            startSourceSeconds: mapped.sourceLocalSeconds
        )

        Task {
            do {
                let t0 = try await capture.startRecording(to: url)
                await MainActor.run {
                    let controller = RecordingController(t0Seconds: t0)
                    // Start the source playing AFTER constructing the
                    // controller, BEFORE appending the .play event — so the
                    // event's recordTime is computed against the same t0
                    // and ordered before the user's first space/skip.
                    workspace.virtualPlayer?.play()
                    controller.appendPlay()
                    self.recordingController = controller
                    self.appMode = .recording
                }
            } catch {
                await MainActor.run {
                    self.appMode = .scanning
                    self.pendingRecording = nil
                    self.recordingError = "Couldn't start recording: \(error.localizedDescription)"
                }
            }
        }
    }

    private func stopRecording() {
        guard let pending = pendingRecording, let controller = recordingController else { return }
        // Pre-emptively pause and reset live drawing so the UI returns to
        // a clean scanning state regardless of how the stop call resolves.
        workspace.virtualPlayer?.pause()
        drawingClearToken &+= 1

        Task {
            do {
                let duration = try await capture.stopRecording()
                let events = controller.finish()
                await MainActor.run {
                    let count = workspace.project.clips.count
                    let clip = Clip(
                        id: pending.clipID,
                        name: "Clip \(count + 1)",
                        sourceIndex: pending.sourceIndex,
                        startSourceSeconds: pending.startSourceSeconds,
                        recordingDuration: duration,
                        recordingFilename: pending.filename,
                        events: events,
                        sortIndex: count
                    )
                    workspace.addClip(clip)
                    self.recordingController = nil
                    self.pendingRecording = nil
                    self.appMode = .scanning
                }
            } catch {
                await MainActor.run {
                    self.recordingController = nil
                    self.pendingRecording = nil
                    self.appMode = .scanning
                    self.recordingError = "Recording finished with an error: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Rendered in place of the main UI when `CaptureSessionController.configure()`
    /// throws `.permissionDenied`. The user must grant access in System
    /// Settings, then relaunch.
    @ViewBuilder
    static func permissionDeniedView() -> some View {
        VStack(spacing: 12) {
            Text("Video Coach needs camera and microphone access.")
                .font(.headline)
            Text("Open System Settings → Privacy & Security to grant permission, then relaunch.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Bundles the three string-bound alerts so the body's modifier chain stays
/// short enough for the Swift type-checker to handle in reasonable time.
private struct AlertsModifier: ViewModifier {
    @Binding var openProjectError: String?
    @Binding var recordingError: String?
    @Binding var deviceFallbackAlert: String?
    @Binding var previewBuildErrorAlert: String?

    func body(content: Content) -> some View {
        content
            .alert(
                "Open Project Failed",
                isPresented: .constant(openProjectError != nil),
                presenting: openProjectError
            ) { _ in
                Button("OK") { openProjectError = nil }
            } message: { Text($0) }
            .alert(
                "Recording Failed",
                isPresented: .constant(recordingError != nil),
                presenting: recordingError
            ) { _ in
                Button("OK") { recordingError = nil }
            } message: { Text($0) }
            .alert(
                "Device Unavailable",
                isPresented: .constant(deviceFallbackAlert != nil),
                presenting: deviceFallbackAlert
            ) { _ in
                Button("OK") { deviceFallbackAlert = nil }
            } message: { Text($0) }
            .alert(
                "Preview Failed",
                isPresented: .constant(previewBuildErrorAlert != nil),
                presenting: previewBuildErrorAlert
            ) { _ in
                Button("OK") { previewBuildErrorAlert = nil }
            } message: { Text($0) }
    }
}

/// All Devices-menu wiring: mirror appMode into the catalog's lock flag,
/// react to project-open by reading saved device prefs, and pipe menu
/// selection edits back to the capture-session swap callbacks.
private struct DeviceWiringModifier: ViewModifier {
    let appMode: AppMode
    let workspaceFolder: URL?
    let catalog: DeviceCatalog
    let onProjectOpened: () -> Void
    let onCameraChange: (String?) -> Void
    let onMicChange: (String?) -> Void

    func body(content: Content) -> some View {
        let stepOne = content
            .onChange(of: appMode) { _, newMode in
                catalog.lockedByRecording =
                    (newMode == .recording || newMode == .recordingStarting)
            }
            .onChange(of: workspaceFolder) { _, newFolder in
                guard newFolder != nil else { return }
                onProjectOpened()
            }
        return stepOne
            .onChange(of: catalog.selectedCameraID) { _, newID in
                onCameraChange(newID)
            }
            .onChange(of: catalog.selectedMicID) { _, newID in
                onMicChange(newID)
            }
    }
}
