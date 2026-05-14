import SwiftUI
import AppKit
import AVFoundation
import QuartzCore
import VideoCoachCore

struct ContentView: View {
    /// Owned by `VideoCoachApp` so the same instance backs both the
    /// top-level Devices menu and this view's onChange handlers. Passed in
    /// rather than created here so the menu's selection edits actually
    /// reach the capture session.
    @Bindable var deviceCatalog: DeviceCatalog

    @State private var workspace = Workspace()
    @State private var skipCoordinator = SkipCoordinator(burstWindowSeconds: 0.15)
    @State private var skipDebounceTask: Task<Void, Never>?
    /// Bumped on every selectedClipID change so a late preview-mode seek
    /// completion is dropped (D12 — also fixes the preexisting AVPlayer
    /// cache-hit A→B→A bug previously documented at the .onChange site).
    @State private var previewSkipGeneration: UInt64 = 0
    /// True while a coarse (keyframe-tolerant) FF/RW seek is in flight in
    /// preview mode. StrokeReplayLayer reads this via the overlay
    /// representable and freezes its periodic redraw so strokes don't flash
    /// to wrong positions during the keyframe-decode window.
    @State private var coarseSeekInFlight: Bool = false
    @State private var selectedClipID: Clip.ID?
    @State private var appMode: AppMode = .scanning
    @State private var openProjectError: String?
    /// Drives the Export Compilations sheet. Toggled by the toolbar button
    /// (disabled when there's no project open or the project has no clips —
    /// a no-op export sheet would have nothing to do anyway).
    @State private var showExportSheet = false
    /// Currently active sidebar tag filter. nil = show all clips.
    /// Toggled by clicking rows in the inspector's TagOverview when
    /// no clip is selected. Cleared on project switch (below) and by
    /// Esc in scanning mode (Task 3). View-state only; never persisted.
    @State private var selectedTagFilter: String? = nil

    // MARK: - Capture / recording state

    @State private var capture = CaptureSessionController()
    /// Surfaces a `ClipPreviewBuilder` failure as a one-shot alert. Cleared
    /// when the user dismisses; the failure stays in
    /// `Workspace._previewFailed` so re-selecting the same clip surfaces it
    /// again rather than silently retrying.
    @State private var previewBuildErrorAlert: String?
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
    /// Bumped on each successful recording start so an overlay can briefly
    /// flash to confirm the transition. Animation owned in the player ZStack.
    @State private var recordingFlashToken: Int = 0
    /// Host time (`CACurrentMediaTime()`) of `t = 0` for the active
    /// recording. nil between recordings. The transport bar reads this to
    /// render the live elapsed counter.
    @State private var recordingStartedAtHostTime: Double?

    private struct PendingRecording {
        var clipID: UUID
        var filename: String
        var sourceIndex: Int
        var startSourceSeconds: Double
    }

    var body: some View {
        rootContent
            // Window title + subtitle. The subtitle exposes the build's git
            // SHA + timestamp (set by scripts/run.sh into App/BuildInfo.swift)
            // so the user can visually confirm which build they're testing.
            .navigationTitle("Coach Cutups")
            .navigationSubtitle(buildSubtitle)
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
            .onChange(of: selectedClipID) { _, _ in
                // Bump both generations so any late completions from the
                // prior selection's seeks are dropped. Even if the user
                // navigates A → B → A, the cache may return the *same*
                // AVPlayer for A — generation bumps invalidate stale state
                // unconditionally.
                previewSkipGeneration &+= 1
                workspace.sourcePlayer?.bumpGeneration()
                resetSkipState()
            }
            .onChange(of: selectedClipID) { _, newID in
                handleSelectionChange(newID)
            }
            .onChange(of: workspace.folder) { _, _ in
                // Filter is view-state tied to the current project; reset
                // it when the user opens or switches projects.
                selectedTagFilter = nil
            }
            .task {
                // Auto-restore last project on launch. Silently skip on any error
                // (folder deleted, permissions changed, project.json corrupt).
                guard workspace.folder == nil else { return }
                guard let path = UserDefaults.standard.string(forKey: "VideoCoach.lastProjectFolder") else { return }
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: path) else {
                    // Folder is gone; clear the stale key.
                    UserDefaults.standard.removeObject(forKey: "VideoCoach.lastProjectFolder")
                    return
                }
                do {
                    try await workspace.openProject(folder: url)
                } catch {
                    UserDefaults.standard.removeObject(forKey: "VideoCoach.lastProjectFolder")
                }
            }
            // Publish the delete handler to the top-level Clip menu — nil
            // when no clip is selected or we're recording, so the menu item
            // (and its Cmd+Delete shortcut) auto-disable in those states.
            .focusedValue(\.deleteSelectedClip, deleteSelectedClipHandler)
            // Undo / redo are gated on Workspace.canUndo / canRedo — both
            // nil while recording so the menu items auto-disable.
            .focusedValue(\.undoAction, undoHandler)
            .focusedValue(\.redoAction, redoHandler)
            // No `.task { capture.configure() }` here on purpose: opening the
            // capture session at launch turns on the camera/mic indicator
            // light and triggers the OS permission prompt before the user
            // has shown any intent to record. We defer configuration to the
            // first `startRecording()` instead, then pause on stop so the
            // light goes off between recordings.
    }

    @ViewBuilder
    private var rootContent: some View {
        mainSplit
    }

    /// Renders the navigation subtitle as "<sha> · <built-at>" when both
    /// pieces are populated by `scripts/run.sh`, falling back to "dev" when
    /// running an Xcode-direct build that didn't go through the script.
    private var buildSubtitle: String {
        if BuildInfo.builtAt.isEmpty { return BuildInfo.commit }
        return "\(BuildInfo.commit) · \(BuildInfo.builtAt)"
    }

    private var isPreviewMode: Bool {
        switch appMode {
        case .previewClip, .previewLoading: return true
        default: return false
        }
    }

    // MARK: - Device handling

    /// Called when a project just finished opening (or was switched). Seeds
    /// the device catalog's selection from the project's saved preferences
    /// so the Devices menu shows the right checkmark. We do NOT touch the
    /// capture session here — opening it would light up the camera before
    /// the user has shown any intent to record. The preferences flow into
    /// `capture.configure(...)` lazily, on first record press.
    private func seedAndApplyPreferredDevices() {
        deviceCatalog.selectedCameraID = workspace.project.preferences.preferredCameraID
        deviceCatalog.selectedMicID = workspace.project.preferences.preferredMicID
    }

    private func handleCameraSelectionChange(_ newID: String?) {
        // Don't try to swap mid-recording — the menu disables itself in
        // that state, but a stale notification could still slip through.
        guard !deviceCatalog.lockedByRecording else { return }
        // No-op if the project's saved preference already matches.
        if workspace.project.preferences.preferredCameraID == newID { return }
        // Persist immediately so the next record-time configure picks it up.
        workspace.project.preferences.preferredCameraID = newID
        try? workspace.saveProject()
        // Live-swap only when the session is currently up. When idle we
        // intentionally skip the swap — instantiating an
        // `AVCaptureDeviceInput` would light the camera while the user is
        // just scanning, which is exactly what we're avoiding by deferring
        // capture.
        guard capture.isReady else { return }
        Task {
            do {
                try await capture.switchVideoDevice(uniqueID: newID)
            } catch CaptureError.deviceUnavailable(let id) {
                await MainActor.run {
                    self.deviceFallbackAlert = "Camera (\(String(id.prefix(12)))…) was unavailable."
                    self.deviceCatalog.selectedCameraID = self.capture.videoDeviceUniqueID
                }
            } catch CaptureError.alreadyRecording {
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
        if workspace.project.preferences.preferredMicID == newID { return }
        workspace.project.preferences.preferredMicID = newID
        try? workspace.saveProject()
        guard capture.isReady else { return }
        Task {
            do {
                try await capture.switchAudioDevice(uniqueID: newID)
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
                appMode: appMode,
                selectedTagFilter: $selectedTagFilter,
                onRequestDeleteClip: { id in requestDeleteClip(id) },
                onJumpToClipStart: { id in jumpToClipStart(id) }
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            VStack(spacing: 0) {
                ZStack {
                    // Black surround for any chrome between the
                    // aspect-locked player and the outer frame.
                    Color.black

                    // Aspect-locked player area. The mpv view (recording)
                    // and AVPlayer view (preview) both render at source
                    // aspect; locking the SwiftUI frame to the same aspect
                    // means there's no letterbox math to do — recording
                    // and playback render pixel-identical at every zoom.
                    // Aspect comes from `workspace.sourceAspect`; falls
                    // back to 16:9 during the brief async load between
                    // project open and track-naturalSize resolution.
                    ZStack {
                        switch appMode {
                        case .scanning, .recordingStarting, .recording:
                            MPVPlayerView(
                                player: workspace.sourcePlayer,
                                currentZoom: workspace.currentZoom,
                                onZoomChange: { newZoom in workspace.currentZoom = newZoom }
                            )
                        case .previewLoading:
                            Color.black
                        case .previewClip(let id):
                            PreviewPlayerSurface(player: workspace.previewPlayer(for: id))
                        }
                        // Mode C overlays — only mounted when previewing so the
                        // periodic time observer in StrokeReplayLayer doesn't run
                        // during scanning/recording.
                        if case .previewClip(let id) = appMode,
                           let player = workspace.previewPlayer(for: id),
                           let clip = workspace.project.clips.first(where: { $0.id == id }) {
                            StrokeReplayOverlay(player: player, clip: clip, replayFrozen: coarseSeekInFlight)
                                .allowsHitTesting(false)
                            previewTextBar(for: clip)
                                .allowsHitTesting(false)
                        }
                        if appMode == .recording {
                            // Drawing overlay sits between the player and the key
                            // monitor — clicks/drags here become strokes; scroll/
                            // pinch are forwarded to currentZoom so the user can
                            // still zoom and pan the source while recording.
                            DrawingOverlay(
                                autoClearAfterSeconds: autoClearStrokes ? 5.0 : nil,
                                onStrokeFinished: { stroke in
                                    recordingController?.appendStroke(stroke)
                                },
                                clearAllToken: drawingClearToken,
                                currentZoom: workspace.currentZoom,
                                onZoomChange: { newZoom in workspace.currentZoom = newZoom }
                            )
                        }
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
                        // Brief red flash to confirm "recording started." Token
                        // increments on each successful start; the modifier
                        // animates 0 → 0.45 → 0 over ~400ms then idles.
                        RecordingStartFlash(trigger: recordingFlashToken)
                            .allowsHitTesting(false)
                    }
                    .aspectRatio(workspace.sourceAspect ?? 16.0/9.0, contentMode: .fit)

                    // Zoom indicator moved to top toolbar (.principal slot).
                    // Drawing controls (auto-clear / clear all) moved there
                    // too so the player area's height stays constant when
                    // entering recording — having a bottom drawingToolbar
                    // appear/disappear was rescaling the source video which
                    // made it harder to land precise drawing strokes.
                    KeyCommandView(
                        appMode: appMode,
                        onSkip: handleSkip,
                        onTogglePlay: handleTogglePlay,
                        onToggleRecord: handleToggleRecord,
                        onClosePreview: handleClosePreview,
                        onResetZoom: { workspace.currentZoom = .identity },
                        currentZoomScale: workspace.currentZoom.scale,
                        onZoomLevel: { newScale, cursor in
                            // Cursor-pivoted absolute zoom — `zoomedToCursor`
                            // collapses to .identity for newScale ≤ 1, so key
                            // 1's reset doesn't need a separate path.
                            let next = workspace.currentZoom
                                .zoomedToCursor(newScale: newScale, cursor: cursor)
                            workspace.setCurrentZoomImmediate(next)
                        },
                        hasTagFilter: selectedTagFilter != nil,
                        onClearTagFilter: { selectedTagFilter = nil }
                    )
                    // Empty / error states cover the player area when there's
                    // nothing meaningful to show. They sit ON TOP of preview
                    // overlays intentionally — if a source goes missing
                    // mid-session, the relink banner trumps the playhead.
                    playerEmptyStateOverlay
                }
                .frame(minWidth: 640, minHeight: 360)

                Divider()

                TransportBar(
                    workspace: workspace,
                    appMode: $appMode,
                    openProjectError: $openProjectError,
                    recordingStartedAtHostTime: recordingStartedAtHostTime,
                    capture: capture,
                    onStopRecording: handleToggleRecord,
                    onClosePreview: handleClosePreview
                )
                .frame(minHeight: 44)
            }
        } detail: {
            ClipInspector(
                workspace: workspace,
                selectedClipID: $selectedClipID,
                selectedTagFilter: $selectedTagFilter
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        }
        .toolbar {
            // Top-left BACK affordance: shown only while previewing a
            // clip, mirrors the Esc shortcut and the existing Source
            // button in TransportBar. Hidden (not just disabled) outside
            // preview modes so it doesn't visually clutter the toolbar
            // during scanning/recording.
            ToolbarItem(placement: .navigation) {
                if isPreviewMode {
                    Button(action: handleClosePreview) {
                        Label("Source", systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                            .font(.headline)
                    }
                    .controlSize(.large)
                    .help("Return to source video (Esc)")
                }
            }
            // Centered always-on cluster: zoom level + drawing controls.
            // The drawing controls used to live in a `drawingToolbar`
            // mounted below the player area only during recording, but
            // mounting/unmounting it changed the player's height which
            // shifted the on-screen layout right when the user wanted to
            // start drawing precisely. Pinning them to the toolbar keeps
            // the player's frame constant across mode switches.
            ToolbarItem(placement: .principal) {
                HStack(spacing: 16) {
                    ZoomIndicator(zoom: workspace.currentZoom)
                    Toggle("Auto-clear (5s)", isOn: $autoClearStrokes)
                        .toggleStyle(.checkbox)
                        .disabled(appMode != .recording)
                    Button("Clear All") {
                        drawingClearToken &+= 1
                        recordingController?.appendClearAll()
                    }
                    .disabled(appMode != .recording)
                }
            }
            // Right side: just the Export button. The window's
            // navigationTitle("Coach Cutups") already renders the app
            // name in the macOS title bar — no need to duplicate it in
            // the toolbar, where SwiftUI would cram it into the
            // primaryAction capsule alongside Export.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showExportSheet = true
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                // Disabled when the export would have nothing to render —
                // either no project folder open or no clips recorded yet.
                // ExportSheet itself enforces "at least one tag checked" on
                // the Export button; this gate just prevents users opening
                // an empty sheet.
                .disabled(workspace.folder == nil || workspace.project.clips.isEmpty)
                .help(workspace.folder == nil
                      ? "Open a project to export"
                      : (workspace.project.clips.isEmpty
                         ? "Record at least one clip to export"
                         : "Export compilations…"))
            }
        }
        .sheet(isPresented: $showExportSheet) {
            ExportSheet(workspace: workspace, isPresented: $showExportSheet)
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

    /// Mirrors the export's compositor text bar exactly so what the user
    /// sees in preview matches what they'll see in the exported file.
    /// Position is "1 / 1" in preview (single-clip context); export shows
    /// the real clip-in-compilation index.
    private func textBarLine(for clip: Clip) -> String {
        var parts: [String] = ["1 / 1"]
        let trimmedName = clip.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { parts.append(trimmedName) }
        if !clip.tags.isEmpty { parts.append(clip.tags.joined(separator: ", ")) }
        return parts.joined(separator: " | ")
    }

    // MARK: - Mode transitions

    private func handleSelectionChange(_ newID: Clip.ID?) {
        // Pause whatever was playing — switching selection should park the
        // prior player so audio doesn't bleed across clips.
        workspace.sourcePlayer?.pause()
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
            previewBuildErrorAlert = "\(err)"
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
                        self.previewBuildErrorAlert = "\(err)"
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
        if appMode == .recording { recordingController?.appendSkip(delta: delta) }
        let now = CACurrentMediaTime()

        switch appMode {
        case .scanning, .recordingStarting, .recording:
            guard let player = workspace.sourcePlayer else { return }
            // Don't issue seeks while the playlist is empty (Relink banner
            // state). mpv would refuse the seek anyway and the cumulative
            // math would feed the coordinator a bogus zero.
            guard player.hasLoadedFile else { return }
            let project = workspace.project
            let cumulativeCurrent = project.cumulativeOffset(forSourceIndex: player.playlistPos) + player.timePos
            let total = project.totalSourceDuration
            // SkipCoordinator does NOT walk a playlist; it operates on a
            // single scalar `current/duration`. We feed it cumulative-time
            // semantics so its target lands in [0, total].
            let decision = skipCoordinator.requestSkip(
                deltaSeconds: delta,
                currentPlayerTimeSeconds: cumulativeCurrent.isFinite ? cumulativeCurrent : 0,
                clipDurationSeconds: total > 0 ? total : .greatestFiniteMagnitude,
                nowMonotonicSeconds: now
            )
            let gen = player.generation
            driveSkipDecision(decision, generation: gen) { params, completion in
                // Translate cumulative target back to (sourceIndex, sourceLocal),
                // applying the D9 end-clamp epsilon to ensure mpv never
                // refuses the seek.
                let endEpsilon: Double = 0.05
                let clamped = max(0, min(params.targetSeconds, max(0, total - endEpsilon)))
                let mapped = workspace.sourceTime(at: clamped)
                player.seek(
                    playlistPos: mapped.sourceIndex,
                    timeSeconds: mapped.sourceLocalSeconds,
                    exact: params.exact,
                    completion: completion
                )
            }

        case .previewClip(let id):
            guard let player = workspace.previewPlayer(for: id) else { return }
            let durRaw = player.currentItem?.duration.seconds ?? .infinity
            let dur = (durRaw.isFinite && durRaw > 0) ? durRaw : .greatestFiniteMagnitude
            let curr = player.currentTime().seconds
            let decision = skipCoordinator.requestSkip(
                deltaSeconds: delta,
                currentPlayerTimeSeconds: curr.isFinite ? curr : 0,
                clipDurationSeconds: dur,
                nowMonotonicSeconds: now
            )
            let gen = previewSkipGeneration
            driveSkipDecision(decision, generation: gen) { params, completion in
                let t = CMTime(seconds: params.targetSeconds, preferredTimescale: 600)
                let tol: CMTime = params.exact ? .zero : .positiveInfinity
                if !params.exact { coarseSeekInFlight = true }
                player.seek(to: t, toleranceBefore: tol, toleranceAfter: tol) { _ in
                    Task { @MainActor in
                        // Generation-guard the state mutation so it doesn't
                        // bleed into a fresh preview the user has navigated to.
                        if gen == previewSkipGeneration {
                            coarseSeekInFlight = false
                        }
                        completion()
                    }
                }
            }

        case .previewLoading:
            return
        }
    }

    /// Side-effecting executor for SkipCoordinator decisions. Re-enters via
    /// the seek-completion handler or debounce-fire Task; never synchronous
    /// self-recursion. Closure-based so source (mpv) and preview (AVPlayer)
    /// paths can share the control flow while issuing different seek calls.
    @MainActor
    private func driveSkipDecision(
        _ decision: SkipDecision,
        generation: UInt64,
        issueSeek: @escaping (SeekParams, _ completion: @escaping @MainActor () -> Void) -> Void
    ) {
        if let s = decision.seek {
            issueSeek(s) {
                // Late-completion guard.
                guard generation == self.currentSkipGeneration() else { return }
                let next = self.skipCoordinator.seekCompleted(
                    nowMonotonicSeconds: CACurrentMediaTime()
                )
                self.driveSkipDecision(next, generation: generation, issueSeek: issueSeek)
            }
        }
        if let after = decision.armDebounceSeconds {
            skipDebounceTask?.cancel()
            skipDebounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
                if Task.isCancelled { return }
                guard generation == self.currentSkipGeneration() else { return }
                let next = self.skipCoordinator.burstEnded(
                    nowMonotonicSeconds: CACurrentMediaTime()
                )
                self.driveSkipDecision(next, generation: generation, issueSeek: issueSeek)
            }
        }
    }

    private func currentSkipGeneration() -> UInt64 {
        switch appMode {
        case .scanning, .recordingStarting, .recording:
            return workspace.sourcePlayer?.generation ?? 0
        case .previewClip, .previewLoading:
            return previewSkipGeneration
        }
    }

    private func handleTogglePlay() {
        switch appMode {
        case .scanning, .recordingStarting, .recording:
            guard let player = workspace.sourcePlayer else { return }
            let wasPlaying = !player.isPaused
            // Capture BOTH the keystroke host-time AND mpv's current source
            // playhead BEFORE calling player.pause/play.
            //   * host-time before mpv: `mpv_set_property("pause")` can
            //     block for tens to hundreds of ms while mpv processes the
            //     flag; reading `now` after that block lands the event late
            //     and playback's pause arrives that long after the user
            //     pressed space.
            //   * source-time anchor: mpv may have play/pause latency or
            //     frame-boundary rounding that makes the segment-builder's
            //     1×-wall-clock cursor drift from where the user actually
            //     saw the source freeze. Pinning the captured `timePos` on
            //     the event lets the segment-builder anchor the freeze
            //     frame to the exact mpv state at the keystroke.
            //
            // Use `currentSourceTimeSync()` (a synchronous
            // `mpv_get_property("time-pos", ...)` call) rather than
            // `player.timePos` (the @Observable cache populated by mpv
            // property-change events): the cache lags the actual
            // playback head by up to one frame because property events
            // hop through `DispatchQueue.main.async` before reaching
            // Swift, and on a fast-moving source that lag is visible —
            // the user pauses on the soccer ball at frame N+1 but the
            // recorded freeze shows frame N, so any drawing made on top
            // of the paused frame doesn't line up with the ball on
            // playback.
            let keystrokeHostTime = CACurrentMediaTime()
            let sourceTime = player.currentSourceTimeSync()
            wasPlaying ? player.pause() : player.play()
            if appMode == .recording {
                wasPlaying
                    ? recordingController?.appendPause(atHostTime: keystrokeHostTime, sourceTime: sourceTime)
                    : recordingController?.appendPlay(atHostTime: keystrokeHostTime, sourceTime: sourceTime)
            }
        case .previewClip(let id):
            guard let player = workspace.previewPlayer(for: id) else { return }
            let wasPlaying = player.rate != 0
            wasPlaying ? player.pause() : player.play()
        case .previewLoading:
            return
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

    /// Cancels any in-flight debounce and resets coordinator state.
    /// Idempotent. Call on close and on every sidebar selection change —
    /// anywhere the active player might have flipped. Generation bumps
    /// (sourcePlayer.bumpGeneration / previewSkipGeneration) handle late
    /// completions that race past this reset.
    private func resetSkipState() {
        skipDebounceTask?.cancel()
        skipDebounceTask = nil
        skipCoordinator.reset()
        coarseSeekInFlight = false
    }

    /// Deselect the current clip and route the player back to the source.
    /// Wired to the Source button in `PreviewTransport` and to the Esc key
    /// when `appMode` is a preview state.
    private func handleClosePreview() {
        previewSkipGeneration &+= 1
        resetSkipState()
        // Pause the preview player so audio doesn't keep playing if AVPlayer
        // somehow holds a reference past the swap.
        workspace.previewPlayer(for: selectedClipID ?? UUID())?.pause()
        selectedClipID = nil
    }

    /// Right-click action from the sidebar: closes any active preview,
    /// then positions the source player at the clip's recorded start.
    /// Leaves the source paused — the user presses Space if they want
    /// to play.
    ///
    /// Uses `setReplayPosition` rather than `seek` because the call
    /// may fire while the source mpv handle is detached (preview mode
    /// unmounts `MPVPlayerView`, which destroys the handle via
    /// `detachLayer` → `mpv_terminate_destroy`). `seek` would no-op
    /// in that state; `setReplayPosition` mutates the cached Swift
    /// state so the attach-replay on next mount lands at the right
    /// position.
    private func jumpToClipStart(_ id: Clip.ID) {
        guard let clip = workspace.project.clips.first(where: { $0.id == id })
        else { return }
        guard let player = workspace.sourcePlayer else { return }

        // Prime the player's position state FIRST. If currently
        // attached (scanning mode), this also issues a real seek so
        // the change is visible immediately. If detached (preview
        // mode), the call just mutates cached state; the seek will
        // take effect when the preview close triggers a re-attach.
        player.setReplayPosition(
            playlistPos: clip.sourceIndex,
            timeSeconds: clip.startSourceSeconds
        )
        player.pause()

        // Close any active preview so the player view swaps back to
        // MPVPlayerView. On re-attach, attachLayer's replay path picks
        // up the playlistPos/timePos we just set.
        if selectedClipID != nil { handleClosePreview() }
    }

    /// Delete a specific clip. No confirm alert — the action is recoverable
    /// via Clip ▸ Undo Delete Clip / ⌘Z while the app is running. Ignored
    /// during recording, and a no-op when no clip is selected. If the clip
    /// is currently previewing, close the preview first so the player isn't
    /// left holding a stale reference.
    private func requestDeleteClip(_ id: Clip.ID?) {
        guard let id else { return }
        if appMode == .recording || appMode == .recordingStarting { return }
        if selectedClipID == id { handleClosePreview() }
        do {
            try workspace.deleteClip(id: id)
        } catch {
            recordingError = "Couldn't delete clip: \(error.localizedDescription)"
        }
    }

    /// Computed handler published to the Clip menu via `@FocusedValue`.
    /// nil when there's nothing to delete OR while recording — the menu
    /// item disables itself in either case.
    private var deleteSelectedClipHandler: (() -> Void)? {
        guard let id = selectedClipID else { return nil }
        if appMode == .recording || appMode == .recordingStarting { return nil }
        return { requestDeleteClip(id) }
    }

    /// Handler published to the Clip ▸ Undo (⌘Z) menu. nil when the undo
    /// stack is empty OR while recording — the menu item disables itself
    /// in either case. ALWAYS selects the affected clip after undoing —
    /// without this, an undo of an edit on a non-selected clip is silent
    /// (model reverts but the user sees nothing change) and the user
    /// can't tell whether Cmd+Z actually did anything.
    private var undoHandler: (() -> Void)? {
        guard workspace.canUndo else { return nil }
        if appMode == .recording || appMode == .recordingStarting { return nil }
        return {
            guard let undone = workspace.undo() else { return }
            switch undone {
            case let .editClip(id, _, _):
                selectedClipID = id
            case let .deleteClip(stash):
                selectedClipID = stash.clip.id
            case .reorderClips:
                // Position changed, identity didn't — leave the
                // selection alone so the user's focus is preserved.
                break
            }
        }
    }

    /// Handler published to the Clip ▸ Redo (⇧⌘Z) menu. Same gating
    /// rules as undo. For an `.editClip` redo, selects the affected
    /// clip (mirrors undo). For a `.deleteClip` redo, clears selection
    /// if the deleted clip was selected — same behavior as a fresh
    /// delete in `requestDeleteClip`.
    private var redoHandler: (() -> Void)? {
        guard workspace.canRedo else { return nil }
        if appMode == .recording || appMode == .recordingStarting { return nil }
        return {
            guard let redone = workspace.redo() else { return }
            switch redone {
            case let .editClip(id, _, _):
                selectedClipID = id
            case let .deleteClip(stash):
                if selectedClipID == stash.clip.id {
                    selectedClipID = nil
                }
            case .reorderClips:
                break
            }
        }
    }

    // MARK: - Recording flow

    private func startRecording() {
        guard let recordingsDir = workspace.recordingsDir else {
            recordingError = "Open a project folder before recording."
            return
        }
        guard let player = workspace.sourcePlayer else {
            recordingError = "Add a source video before recording."
            return
        }
        // Force-pause the source on R-press. Every clip then begins with a
        // `.freeze` segment whose source-time is the playhead at R-press,
        // collapsing the event-log shape that downstream code (preview,
        // export) has to handle. KeyCommandView gates space while we're in
        // .recordingStarting, so the source stays paused all the way to t0.
        player.pause()
        appMode = .recordingStarting

        let clipID = UUID()
        let filename = "clip-\(clipID).mov"
        let url = recordingsDir.appendingPathComponent(filename)

        // Capture source-time anchor synchronously at R-press via
        // `currentSourceTimeSync()` — the cached `timePos` can still
        // lag mpv's actual state right after a recent pause (the
        // property-change → DispatchQueue.main.async hop can leave the
        // cache one update behind), and we'd rather the clip's
        // `startSourceSeconds` reflect the exact frame on screen than
        // a value from a few frames ago.
        let initialSourceSeconds = player.currentSourceTimeSync()
        pendingRecording = PendingRecording(
            clipID: clipID,
            filename: filename,
            sourceIndex: player.playlistPos,
            startSourceSeconds: initialSourceSeconds
        )

        let preferredCameraID = deviceCatalog.selectedCameraID
        let preferredMicID = deviceCatalog.selectedMicID

        Task {
            do {
                // Lazy configure: the capture session is paused (stopRunning)
                // between recordings so the indicator light is off while the
                // user is just scanning. prepareForRecording configures on
                // first call, restarts the session on resumes, and waits for
                // the data output to actually deliver a frame before we kick
                // off movieOutput.startRecording — otherwise the file output
                // races a session that hasn't fully spun up yet.
                try await capture.prepareForRecording(
                    preferredCameraID: preferredCameraID,
                    preferredMicID: preferredMicID
                )
                let t0 = try await capture.startRecording(to: url)
                let fallback = capture.lastFallbackReason
                await MainActor.run {
                    let controller = RecordingController(t0Seconds: t0)
                    // Inherit-on-record: capture the live zoom snapshot at
                    // recordTime=0 BEFORE the .pause anchor, so replay sees
                    // [zoom @ t=0, pause @ t=0+ε] rather than briefly rendering
                    // at identity before snapping to the inherited zoom.
                    controller.appendInitialZoom(workspace.currentZoom)
                    // Source was paused on R-press and KeyCommandView blocks
                    // space during .recordingStarting, so the source is
                    // guaranteed paused at t0. Anchor the event log with
                    // .pause AT recordTime=0 (not `now`) — the async hop
                    // between capture.startRecording and MainActor.run can
                    // land at `now > 0`, which would emit a phantom
                    // leading .play segment of `now` seconds at the start
                    // of the clip (the source was actually frozen during
                    // that window).
                    // Reuse the sync-fetched startSourceSeconds rather
                    // than re-reading `player.timePos` here. By the time
                    // this MainActor.run closure runs, mpv has had several
                    // dispatch hops to update its state — but we want the
                    // initial pause anchor to match the clip's
                    // startSourceSeconds exactly so the freeze frame at
                    // recordTime=0 is the same source-time the clip is
                    // semantically anchored to.
                    controller.appendInitialPause(sourceTime: initialSourceSeconds)
                    self.recordingController = controller
                    workspace.recordingController = controller
                    self.appMode = .recording
                    self.recordingStartedAtHostTime = t0
                    self.recordingFlashToken &+= 1
                    if let fallback {
                        self.deviceFallbackAlert = fallback
                    }
                }
            } catch CaptureError.permissionDenied(let media) {
                await MainActor.run {
                    self.appMode = .scanning
                    self.pendingRecording = nil
                    let kind = media == .video ? "camera" : "microphone"
                    self.recordingError = "Coach Cutups needs \(kind) access to record. " +
                        "Open System Settings → Privacy & Security → \(media == .video ? "Camera" : "Microphone") " +
                        "to grant permission, then try again."
                }
                await capture.pauseSession()
            } catch {
                await MainActor.run {
                    self.appMode = .scanning
                    self.pendingRecording = nil
                    self.recordingError = "Couldn't start recording: \(error.localizedDescription)"
                }
                await capture.pauseSession()
            }
        }
    }

    private func stopRecording() {
        guard let pending = pendingRecording, let controller = recordingController else { return }
        // Reset the live drawing overlay so the next recording starts clean.
        // Source-video playback state is intentionally NOT touched — the
        // user's pre-record play/pause state is preserved across the whole
        // recording flow.
        drawingClearToken &+= 1

        Task {
            do {
                let duration = try await capture.stopRecording()
                let events = controller.finish()
                await MainActor.run {
                    let count = workspace.project.clips.count
                    let clip = Clip(
                        id: pending.clipID,
                        name: Self.defaultClipName(
                            sourceIndex: pending.sourceIndex,
                            startSourceSeconds: pending.startSourceSeconds
                        ),
                        sourceIndex: pending.sourceIndex,
                        startSourceSeconds: pending.startSourceSeconds,
                        recordingDuration: duration,
                        recordingFilename: pending.filename,
                        events: events,
                        sortIndex: count
                    )
                    workspace.addClip(clip)
                    self.recordingController = nil
                    workspace.recordingController = nil
                    self.pendingRecording = nil
                    self.appMode = .scanning
                    self.recordingStartedAtHostTime = nil
                }
                // Free the camera/mic so the indicator light goes off
                // between recordings. Next record reconfigures lazily.
                await capture.pauseSession()
            } catch {
                await MainActor.run {
                    self.recordingController = nil
                    workspace.recordingController = nil
                    self.pendingRecording = nil
                    self.appMode = .scanning
                    self.recordingStartedAtHostTime = nil
                    self.recordingError = "Recording finished with an error: \(error.localizedDescription)"
                }
                await capture.pauseSession()
            }
        }
    }

    /// Default clip name format: `<sourceIndex+1>-HH:MM:SS` where the time
    /// is the playhead within the source at R-press. Lets users scan their
    /// clip list and immediately know where each clip came from in the
    /// match. They can rename in the inspector when they want a tag-style
    /// label.
    static func defaultClipName(sourceIndex: Int, startSourceSeconds: Double) -> String {
        let total = max(0, Int(startSourceSeconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%d-%02d:%02d:%02d", sourceIndex + 1, h, m, s)
    }

    // MARK: - Empty / error state overlays

    /// Returns the appropriate centered "blocker" view for the player area
    /// when the user can't actually use the player yet (no project, no
    /// source, or one or more sources are missing). Returns `EmptyView` when
    /// playback is fine. Always rendered on top of the player ZStack.
    @ViewBuilder
    private var playerEmptyStateOverlay: some View {
        if workspace.folder == nil {
            emptyStateCard(
                icon: "folder.badge.plus",
                title: "No project open",
                message: "Open a folder to start tagging match footage. " +
                    "Coach Cutups stores its project file (project.json) and " +
                    "your recorded commentary clips inside the folder.",
                primary: ("Open Project Folder…", openProjectFolderPanel)
            )
        } else if workspace.project.sourceVideos.isEmpty {
            emptyStateCard(
                icon: "video.badge.plus",
                title: "No source video added",
                message: "Add the match video you want to commentate on. " +
                    "You can add up to two sources (e.g., two halves) per project.",
                primary: ("Add Source Video…", addSourceVideoPanel)
            )
        } else if let missingIndex = workspace.missingSourceIndices.sorted().first {
            // Only the first missing source is offered for relink at a time —
            // after the user picks a replacement we rebuild and re-evaluate.
            // If multiple sources are still missing, the banner reappears
            // for the next one.
            let name = workspace.project.sourceVideos[missingIndex].displayName
            emptyStateCard(
                icon: "exclamationmark.triangle.fill",
                title: "Source video is missing",
                message: "Coach Cutups can't find “\(name)”. It may have been " +
                    "moved, renamed, or deleted. Pick its current location to " +
                    "continue.",
                primary: ("Relink…", { relinkSourcePanel(at: missingIndex) })
            )
        }
    }

    @ViewBuilder
    private func emptyStateCard(
        icon: String,
        title: String,
        message: String,
        primary: (label: String, action: () -> Void)
    ) -> some View {
        ZStack {
            Color.black
            VStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.white.opacity(0.7))
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: 420)
                Button(primary.label, action: primary.action)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 4)
            }
            .padding(40)
        }
    }

    private func openProjectFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await workspace.openProject(folder: url)
            } catch {
                openProjectError = "Couldn't open project: \(error.localizedDescription)\n\nIf project.json is corrupted, restore it from a backup before retrying."
            }
        }
    }

    private func addSourceVideoPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
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

    private func relinkSourcePanel(at index: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        // Hint the user with the original filename so they know what to find.
        panel.message = "Locate the original file (or a replacement) for " +
            "“\(workspace.project.sourceVideos[index].displayName)”."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await workspace.relinkSource(at: index, to: url)
            } catch {
                openProjectError = "Couldn't relink source: \(error.localizedDescription)"
            }
        }
    }

}

/// Brief red-flash overlay used to confirm "recording started." The
/// `trigger` is a token bumped by ContentView each time a recording
/// successfully starts; on change we run a short animation from
/// 0 → 0.45 → 0 over ~400ms. Self-contained so the parent ZStack doesn't
/// need any animation plumbing.
private struct RecordingStartFlash: View {
    let trigger: Int
    @State private var opacity: Double = 0

    var body: some View {
        Color.red
            .opacity(opacity)
            .onChange(of: trigger) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) { opacity = 0.45 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    withAnimation(.easeIn(duration: 0.22)) { opacity = 0 }
                }
            }
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
