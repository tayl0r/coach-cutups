import SwiftUI
import AppKit
import AVFoundation
import VideoCoachCore

struct ContentView: View {
    @State private var workspace = Workspace()
    @State private var selectedClipID: Clip.ID?
    @State private var appMode: AppMode = .scanning
    @State private var openProjectError: String?

    // MARK: - Capture / recording state

    @State private var capture = CaptureSessionController()
    /// Set when capture configuration fails because the user denied camera
    /// or microphone access. Renders `permissionDeniedView()` in place of
    /// the main UI so the user sees how to fix it.
    @State private var permissionDenied = false
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
        Group {
            if permissionDenied {
                Self.permissionDeniedView()
            } else {
                mainSplit
            }
        }
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
        .onChange(of: selectedClipID) { _, newID in
            handleSelectionChange(newID)
        }
        .task {
            // Configure the capture session once on first appearance. If the
            // user denies permission, surface `permissionDeniedView()`.
            do {
                try await capture.configure()
            } catch CaptureError.permissionDenied {
                permissionDenied = true
            } catch {
                // Capture-config failures other than permission denial fail
                // softly: the user can still scan footage, recording is just
                // disabled. Pressing R will surface the error via the alert.
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
                        onToggleRecord: handleToggleRecord
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
                    onStopRecording: handleToggleRecord
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
        guard let newID else { appMode = .scanning; return }
        if workspace.previewPlayer(for: newID) != nil {
            appMode = .previewClip(newID)
            return
        }
        // TODO(Phase 8): kick off ClipPreviewBuilder and transition to
        // .previewLoading → .previewClip when the cache populates. Until then,
        // stay on .scanning so the player keeps showing the virtual concat
        // and the inspector keeps the clip selected for metadata editing.
        appMode = .scanning
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
