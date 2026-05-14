import AVFoundation
import Observation

enum CaptureError: Error, LocalizedError {
    case noVideoDevice
    case noAudioDevice
    case noSuitableFormat
    case permissionDenied(media: AVMediaType)
    case alreadyRecording
    case firstSampleTimeout
    /// User picked a device by `uniqueID` (via the Devices menu) that has
    /// since vanished — typically a USB camera unplugged between menu open
    /// and click. Surfaced via the menu's onChange so the UI reverts the
    /// selection back to whatever the session is actually using.
    case deviceUnavailable(String)

    /// Without LocalizedError, NSError surfaces these as "VideoCoach.CaptureError
    /// error N" — useless to diagnose. The case name + a short hint is enough
    /// to identify which path failed without round-tripping to source.
    var errorDescription: String? {
        switch self {
        case .noVideoDevice: return "No camera available."
        case .noAudioDevice: return "No microphone available."
        case .noSuitableFormat: return "Camera doesn't support a 16:9 ≤720p 30fps format."
        case .permissionDenied(let media):
            return "Permission denied for \(media == .video ? "camera" : "microphone")."
        case .alreadyRecording: return "A recording is already in progress."
        case .firstSampleTimeout:
            return "Capture timed out waiting for the first frame from the camera (5s)."
        case .deviceUnavailable(let id):
            return "Selected device (\(String(id.prefix(12)))…) is unavailable."
        }
    }
}

/// Owns the single `AVCaptureSession` for the app. Two outputs:
///
/// - `AVCaptureMovieFileOutput` writes the `.mov` (camera + mic).
/// - `AVCaptureVideoDataOutput` companion exists solely to grab the first
///   `CMSampleBuffer`'s host-time PTS as the recording's `t = 0` anchor.
///
/// `startRecording(to:)` returns the host-time seconds of the first sample
/// buffer that lands AFTER the file output has actually opened — sub-frame
/// accurate, no retroactive offset math. See the design's "Time anchoring"
/// section for the full rationale.
@Observable
final class CaptureSessionController: NSObject,
    AVCaptureFileOutputRecordingDelegate,
    AVCaptureVideoDataOutputSampleBufferDelegate
{
    private(set) var isReady = false
    private(set) var isRecording = false
    /// Set by `configure(...)` when a preferred device ID was supplied but
    /// the device wasn't found at launch — the session falls back to the
    /// system default and the UI surfaces this as a non-fatal alert. Cleared
    /// by every successful `switchVideoDevice` / `switchAudioDevice` call.
    private(set) var lastFallbackReason: String?

    /// Live average power level (decibels, typically -160…0) from the
    /// recording's audio connection. `nil` between recordings.
    private(set) var audioAveragePowerDB: Float?

    /// Companion ~1s peak hold to `audioAveragePowerDB`.
    private(set) var audioPeakHoldDB: Float?

    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let dataOutput = AVCaptureVideoDataOutput()
    private let dataQueue = DispatchQueue(label: "videoCoach.capture.data")

    /// Serial queue for all `AVCaptureSession` interactions. Apple's AVCam
    /// sample dispatches every session op to a queue like this because
    /// `startRunning()` is documented as blocking, and AVFoundation's own
    /// callbacks can race a stepped-on main runloop. Distinct from
    /// `dataQueue` (sample-buffer delivery) on purpose — the two queues
    /// have unrelated lifecycles.
    private let sessionQueue = DispatchQueue(label: "videoCoach.capture.session")

    /// Flips to true the first time the data-output delegate receives a
    /// valid sample buffer after the session starts running. `waitForWarmup`
    /// polls this; cleared in `pauseSession`/`teardown` so the next resume
    /// waits for a fresh frame rather than reading a stale flag from the
    /// prior session run. All access serialized on `dataQueue`.
    private var hasProducedSampleSinceStart = false

    /// Resumed with the host-time PTS (in seconds) of the first sample buffer
    /// that lands AFTER the file output has opened. nil between recordings.
    /// `t0Continuation` and `awaitingFirstSample` are accessed only on
    /// `dataQueue`. `firstSampleTimeoutTask` is assigned on `sessionQueue`
    /// (alongside `movieOutput.startRecording`) and read/cancelled on
    /// `dataQueue` — the cross-queue handoff is safe because
    /// `didStartRecordingTo → dataQueue.async` provides the memory barrier.
    private var t0Continuation: CheckedContinuation<Double, Error>?
    private var awaitingFirstSample = false
    private var firstSampleTimeoutTask: Task<Void, Never>?

    private var stopContinuation: CheckedContinuation<Double, Error>?
    private var videoDevice: AVCaptureDevice?

    @ObservationIgnored
    private var levelMonitorTimer: Timer?
    @ObservationIgnored
    private var peakHoldUntilHostTime: Double = 0

    func configure(
        preferredCameraID: String? = nil,
        preferredMicID: String? = nil
    ) async throws {
        try await ensurePermission(.video)
        try await ensurePermission(.audio)

        // Resolve preferred-or-default for each media type. If the user has a
        // saved preference but the device isn't present (unplugged USB cam,
        // a different host machine, etc.), we silently fall back to the
        // system default and stash a reason for the UI to alert on. We do
        // NOT throw — a missing preferred device is a recoverable condition,
        // not a configuration failure.
        var fallbackMessages: [String] = []
        let video = Self.resolveDevice(
            preferredID: preferredCameraID,
            mediaType: .video,
            fallbackMessages: &fallbackMessages,
            kind: "Camera"
        )
        guard let video else { throw CaptureError.noVideoDevice }

        let audio = Self.resolveDevice(
            preferredID: preferredMicID,
            mediaType: .audio,
            fallbackMessages: &fallbackMessages,
            kind: "Microphone"
        )
        guard let audio else { throw CaptureError.noAudioDevice }

        self.videoDevice = video
        self.lastFallbackReason = fallbackMessages.isEmpty
            ? nil
            : fallbackMessages.joined(separator: "\n")

        let videoInput = try AVCaptureDeviceInput(device: video)
        let audioInput = try AVCaptureDeviceInput(device: audio)

        try await runOnSessionQueue {
            self.session.beginConfiguration()
            // NOTE: `AVCaptureSession.Preset.inputPriority` is iOS-only. On macOS
            // we leave the preset alone — setting `device.activeFormat` after
            // `addInput` transitions the session's effective preset to
            // input-priority semantics automatically, which is exactly what we
            // want (the explicit `device.activeFormat` we set below wins).
            if self.session.canAddInput(videoInput) { self.session.addInput(videoInput) }
            if self.session.canAddInput(audioInput) { self.session.addInput(audioInput) }
            if self.session.canAddOutput(self.movieOutput) { self.session.addOutput(self.movieOutput) }
            if self.session.canAddOutput(self.dataOutput) {
                self.dataOutput.setSampleBufferDelegate(self, queue: self.dataQueue)
                self.dataOutput.alwaysDiscardsLateVideoFrames = true
                self.session.addOutput(self.dataOutput)
            }
            // Canonical AVCam ordering: `addInput` resets the device to the
            // preset's default format, so `activeFormat` MUST be set after the
            // input is added (otherwise it's silently undone — notably back to
            // 1920×1440 4:3 on Continuity Camera).
            try self.setPreferredFormat(on: video)
            self.session.commitConfiguration()
            self.session.startRunning()
        }
        isReady = true
    }

    private func ensurePermission(_ media: AVMediaType) async throws {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: media)
            if !granted { throw CaptureError.permissionDenied(media: media) }
        default:
            throw CaptureError.permissionDenied(media: media)
        }
    }

    private func setPreferredFormat(on device: AVCaptureDevice) throws {
        let candidates = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let aspect = Double(dims.width) / Double(max(dims.height, 1))
            return abs(aspect - 16.0 / 9.0) < 0.01
                && dims.width <= 1280
                && format.videoSupportedFrameRateRanges.contains(where: {
                    $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
                })
        }
        // Prefer the highest-resolution 16:9 format ≤ 1280×720 supporting 30fps.
        let best = candidates.max(by: { a, b in
            CMVideoFormatDescriptionGetDimensions(a.formatDescription).width
            < CMVideoFormatDescriptionGetDimensions(b.formatDescription).width
        })
        guard let chosen = best else { throw CaptureError.noSuitableFormat }
        try device.lockForConfiguration()
        device.activeFormat = chosen
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        device.unlockForConfiguration()
    }

    /// Returns the host-time PTS (seconds) of the first frame that lands in
    /// the recorded file. This is our event-log `t = 0`.
    ///
    /// Two-stage gating:
    /// - Continuation is registered on `dataQueue` BEFORE `startRecording`.
    /// - `awaitingFirstSample` flips to `true` only inside
    ///   `didStartRecordingTo`, so any sample buffers in flight before the
    ///   file actually opened are correctly discarded. The first buffer that
    ///   lands after both conditions is, by definition, the first frame in
    ///   the recorded file.
    ///
    /// 2-second timeout protects against camera failure (e.g. another app
    /// holding exclusive access). Refuses re-entry if a recording is pending.
    func startRecording(to url: URL) async throws -> Double {
        // The data-output delegate reads `session.synchronizationClock`
        // fresh per-sample (see `captureOutput` below) — capturing it here
        // would race the cold-session window where the clock hasn't yet
        // calibrated against host time, producing a CMSyncConvertTime
        // failure on the first frame.
        try dataQueue.sync {
            guard t0Continuation == nil, !isRecording else {
                throw CaptureError.alreadyRecording
            }
        }
        return try await withCheckedThrowingContinuation { cont in
            sessionQueue.async {
                self.dataQueue.sync {
                    self.t0Continuation = cont
                    self.awaitingFirstSample = false   // armed in didStartRecordingTo
                }
                self.movieOutput.startRecording(to: url, recordingDelegate: self)
                self.isRecording = true
                self.firstSampleTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    self?.dataQueue.async {
                        guard let self, let cont = self.t0Continuation else { return }
                        self.t0Continuation = nil
                        self.awaitingFirstSample = false
                        cont.resume(throwing: CaptureError.firstSampleTimeout)
                        self.movieOutput.stopRecording()
                    }
                }
            }
        }
    }

    func stopRecording() async throws -> Double {
        try await withCheckedThrowingContinuation { cont in
            self.stopContinuation = cont
            movieOutput.stopRecording()
        }
    }

    /// Tears the session down so the OS frees the camera/mic — turns off the
    /// recording-indicator light. Calls to `configure` after `teardown` are
    /// expected to succeed: this restores the controller to its initial
    /// state. Refuses while a recording is still in flight.
    func teardown() async {
        guard !isRecording else { return }
        try? await runOnSessionQueue {
            if self.session.isRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            for input in self.session.inputs { self.session.removeInput(input) }
            for output in self.session.outputs { self.session.removeOutput(output) }
            self.session.commitConfiguration()
        }
        videoDevice = nil
        lastFallbackReason = nil
        isReady = false
        dataQueue.sync { hasProducedSampleSinceStart = false }
    }

    /// Stops the session running so the indicator light goes off, but keeps
    /// the configuration intact (inputs, outputs, format). The next
    /// `prepareForRecording` just calls `startRunning` again, which is much
    /// faster than a full reconfigure. Refuses while recording is active.
    func pauseSession() async {
        guard !isRecording else { return }
        try? await runOnSessionQueue {
            if self.session.isRunning { self.session.stopRunning() }
        }
        // Clear so the next prepareForRecording waits for a fresh frame
        // rather than accepting the stale-true from the prior session run.
        dataQueue.sync { hasProducedSampleSinceStart = false }
    }

    /// Brings the session up to "ready to record" state: configures it on
    /// first call, ensures it's running, and waits for the data output to
    /// deliver at least one valid frame so we know the camera pipeline is
    /// actually producing. Without that warmup, `movieOutput.startRecording`
    /// races AVFoundation's startup window and times out on a cold session.
    /// Idempotent — safe to call repeatedly.
    ///
    /// On warm calls (already configured), the preferred-or-default device
    /// is re-resolved and swapped if it differs from the live input. This
    /// is what makes a freshly-plugged-in mic (AirPods between recordings,
    /// USB interface hot-plugged) actually take effect on the next record —
    /// without this, the inputs added by the first `configure` call would
    /// be reused forever and the user would silently keep recording with
    /// the device that was default at app launch.
    func prepareForRecording(
        preferredCameraID: String? = nil,
        preferredMicID: String? = nil
    ) async throws {
        if !isReady {
            try await configure(
                preferredCameraID: preferredCameraID,
                preferredMicID: preferredMicID
            )
        } else {
            try await reconcileLiveDevices(
                preferredCameraID: preferredCameraID,
                preferredMicID: preferredMicID
            )
        }
        try await runOnSessionQueue {
            if !self.session.isRunning { self.session.startRunning() }
        }
        // sessionQueue ordering guarantees `startRunning` has been called
        // before this line, but `startRunning` is documented to return
        // BEFORE the camera is producing frames. Wait for the data output
        // to actually deliver a sample so `movieOutput.startRecording` can
        // race-free assume the session is hot.
        try await waitForWarmup(timeout: 5.0)
    }

    /// Resolve preferred-or-default camera/mic and, for each one whose
    /// resolved uniqueID differs from the currently-installed input, call
    /// the existing `switchXDevice` swap. Same fallback-message machinery
    /// as `configure(...)` so a saved-but-vanished device surfaces an
    /// alert rather than failing silently. Called only on warm
    /// `prepareForRecording` — cold calls go through `configure` instead.
    private func reconcileLiveDevices(
        preferredCameraID: String?,
        preferredMicID: String?
    ) async throws {
        var fallbackMessages: [String] = []
        let targetVideo = Self.resolveDevice(
            preferredID: preferredCameraID,
            mediaType: .video,
            fallbackMessages: &fallbackMessages,
            kind: "Camera"
        )
        guard let targetVideo else { throw CaptureError.noVideoDevice }
        let targetAudio = Self.resolveDevice(
            preferredID: preferredMicID,
            mediaType: .audio,
            fallbackMessages: &fallbackMessages,
            kind: "Microphone"
        )
        guard let targetAudio else { throw CaptureError.noAudioDevice }
        if targetVideo.uniqueID != videoDeviceUniqueID {
            try await switchVideoDevice(uniqueID: targetVideo.uniqueID)
        }
        if targetAudio.uniqueID != audioDeviceUniqueID {
            try await switchAudioDevice(uniqueID: targetAudio.uniqueID)
        }
        // `switchXDevice` clears `lastFallbackReason` on each successful
        // swap, so set it last to preserve any new fallback we computed.
        lastFallbackReason = fallbackMessages.isEmpty
            ? nil
            : fallbackMessages.joined(separator: "\n")
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Runs on `dataQueue`.
        // Always note that frames are flowing — `waitForWarmup` polls this
        // before we kick off `movieOutput.startRecording`, which prevents the
        // file output from racing a session that hasn't fully spun up.
        if !hasProducedSampleSinceStart {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if pts.flags.contains(.valid), pts.seconds.isFinite {
                hasProducedSampleSinceStart = true
            }
        }

        guard awaitingFirstSample, let cont = t0Continuation else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // Some external capture devices occasionally emit invalid/NaN PTS
        // during clock resets. Discard and wait for the next sample.
        guard pts.flags.contains(.valid), pts.seconds.isFinite else { return }

        // Try precise device-clock → host-clock conversion first (sub-frame
        // accurate). On a cold session — particularly the very first record
        // after launch — the device clock hasn't had time to calibrate
        // against host time, and CMSyncConvertTime returns kCMTimeInvalid
        // for several seconds. We fall back to CACurrentMediaTime() at
        // delivery, which is at most one frame (~33ms at 30fps) later than
        // true capture time. That latency bias is shared by all user-input
        // events we'll later anchor with CACurrentMediaTime() too, so the
        // relative timing within the recording stays self-consistent.
        let t0Seconds: Double
        let hostClock = CMClockGetHostTimeClock()
        let currentSessionClock = session.synchronizationClock ?? hostClock
        let hostTime: CMTime
        if currentSessionClock === hostClock {
            hostTime = pts
        } else {
            hostTime = CMSyncConvertTime(pts, from: currentSessionClock, to: hostClock)
        }
        if hostTime.flags.contains(.valid), hostTime.seconds.isFinite {
            t0Seconds = hostTime.seconds
        } else {
            t0Seconds = CACurrentMediaTime()
        }

        awaitingFirstSample = false
        t0Continuation = nil
        firstSampleTimeoutTask?.cancel()
        firstSampleTimeoutTask = nil
        cont.resume(returning: t0Seconds)
    }

    // MARK: AVCaptureFileOutputRecordingDelegate

    func fileOutput(_ output: AVCaptureFileOutput,
                    didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        // The file is now open. Arm the data-output sample-buffer delegate
        // to capture the FIRST buffer that arrives AFTER this point (any
        // buffers in flight before this are pre-recording and must be
        // ignored). Dispatched to `dataQueue` so the flag flip is serialized
        // against the delegate's reads.
        dataQueue.async { [weak self] in
            self?.awaitingFirstSample = true
        }
        // Audio-channel power levels only update while the file output is
        // actively writing, so the meter polling lifecycle is bracketed by
        // these two delegate calls. Hop to main because Timer.scheduledTimer
        // requires a thread with a runloop and we touch @Observable state.
        Task { @MainActor [weak self] in
            self?.startLevelMonitoring()
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        isRecording = false
        Task { @MainActor [weak self] in
            self?.stopLevelMonitoring()
        }
        if let error {
            stopContinuation?.resume(throwing: error)
            stopContinuation = nil
            return
        }
        let cont = stopContinuation
        stopContinuation = nil
        Task {
            // `.duration` is async-only on the latest macOS; load it off the
            // delegate thread.
            let asset = AVURLAsset(url: outputFileURL)
            do {
                let dur = try await asset.load(.duration)
                cont?.resume(returning: dur.seconds)
            } catch {
                cont?.resume(throwing: error)
            }
        }
    }

    /// `uniqueID` of the live video input, or nil if the session has no
    /// video input (shouldn't normally happen). Used by the UI to revert a
    /// failed menu selection back to the live device's checkmark.
    var videoDeviceUniqueID: String? {
        for input in session.inputs {
            guard let deviceInput = input as? AVCaptureDeviceInput,
                  deviceInput.device.hasMediaType(.video)
            else { continue }
            return deviceInput.device.uniqueID
        }
        return nil
    }

    /// Same as `videoDeviceUniqueID` for the audio input.
    var audioDeviceUniqueID: String? {
        for input in session.inputs {
            guard let deviceInput = input as? AVCaptureDeviceInput,
                  deviceInput.device.hasMediaType(.audio)
            else { continue }
            return deviceInput.device.uniqueID
        }
        return nil
    }

    // MARK: - Audio level monitoring

    /// Must run on the main runloop — `Timer.scheduledTimer` requires one,
    /// and the values it writes are SwiftUI-observed @Observable properties.
    @MainActor
    private func startLevelMonitoring() {
        stopLevelMonitoring()
        peakHoldUntilHostTime = 0
        levelMonitorTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 20.0, repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            guard let channel = self.movieOutput
                .connection(with: .audio)?.audioChannels.first
            else {
                if self.audioAveragePowerDB != nil { self.audioAveragePowerDB = nil }
                if self.audioPeakHoldDB != nil { self.audioPeakHoldDB = nil }
                return
            }
            // Custom peak hold on top of AVFoundation's `peakHoldLevel` so a
            // brief transient stays visible ~1s — long enough for a glance
            // at the bar to register that audio is actually flowing.
            let avg = channel.averagePowerLevel
            // Skip identical-value writes — @Observable doesn't diff and
            // every assignment triggers a SwiftUI redraw of the meter.
            if avg != self.audioAveragePowerDB {
                self.audioAveragePowerDB = avg
            }
            let now = CACurrentMediaTime()
            let currentPeak = self.audioPeakHoldDB ?? -160
            if avg >= currentPeak || now > self.peakHoldUntilHostTime {
                if avg != self.audioPeakHoldDB {
                    self.audioPeakHoldDB = avg
                }
                self.peakHoldUntilHostTime = now + 1.0
            }
        }
    }

    @MainActor
    private func stopLevelMonitoring() {
        levelMonitorTimer?.invalidate()
        levelMonitorTimer = nil
        audioAveragePowerDB = nil
        audioPeakHoldDB = nil
    }

    deinit {
        // Safety net for the (theoretically possible) case where the
        // controller is released between `didStartRecordingTo` and
        // `didFinishRecordingTo` — the timer's [weak self] returns nil
        // and self-cleans on the next tick, but invalidating here means
        // the runloop drops it immediately rather than firing one more
        // dead tick.
        levelMonitorTimer?.invalidate()
    }

    // MARK: - Device discovery

    /// All cameras the app can currently see. Includes the built-in wide
    /// angle, any externals (USB capture devices), Continuity Camera (iPhone
    /// over Wi-Fi), and Desk View.
    static func availableCameras() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .external,
            .continuityCamera,
            .deskViewCamera,
        ]
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    /// All microphones the app can currently see — built-in and any external
    /// USB / aggregate audio devices.
    static func availableMicrophones() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = [
            .microphone,
            .external,
        ]
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    // MARK: - Live device swap

    /// Swap the session's video input. `nil` means "system default."
    /// Refuses while a recording is in progress — the UI must disable the
    /// menu items in that state, but we double-check here so a stale event
    /// can't corrupt the file. Re-runs `setPreferredFormat` after the swap
    /// since `addInput` resets the device's `activeFormat` (canonical AVCam
    /// rule, same as `configure()`).
    func switchVideoDevice(uniqueID: String?) async throws {
        guard !isRecording else { throw CaptureError.alreadyRecording }
        let newDevice: AVCaptureDevice
        if let uniqueID {
            guard let dev = AVCaptureDevice(uniqueID: uniqueID) else {
                throw CaptureError.deviceUnavailable(uniqueID)
            }
            newDevice = dev
        } else {
            guard let dev = AVCaptureDevice.default(for: .video) else {
                throw CaptureError.noVideoDevice
            }
            newDevice = dev
        }
        let newInput = try AVCaptureDeviceInput(device: newDevice)

        try await runOnSessionQueue {
            self.session.beginConfiguration()
            for input in self.session.inputs {
                guard let deviceInput = input as? AVCaptureDeviceInput,
                      deviceInput.device.hasMediaType(.video)
                else { continue }
                self.session.removeInput(deviceInput)
            }
            if self.session.canAddInput(newInput) { self.session.addInput(newInput) }
            // Same canonical ordering as `configure()` — addInput resets
            // activeFormat, so the explicit format selection MUST follow it.
            try self.setPreferredFormat(on: newDevice)
            self.session.commitConfiguration()
        }
        self.videoDevice = newDevice
        self.lastFallbackReason = nil
    }

    /// Swap the session's audio input. `nil` means "system default." Same
    /// recording-guard and configuration-bracket pattern as the video swap;
    /// no `setPreferredFormat` step (audio inputs negotiate format inside
    /// AVCaptureSession).
    func switchAudioDevice(uniqueID: String?) async throws {
        guard !isRecording else { throw CaptureError.alreadyRecording }
        let newDevice: AVCaptureDevice
        if let uniqueID {
            guard let dev = AVCaptureDevice(uniqueID: uniqueID) else {
                throw CaptureError.deviceUnavailable(uniqueID)
            }
            newDevice = dev
        } else {
            guard let dev = AVCaptureDevice.default(for: .audio) else {
                throw CaptureError.noAudioDevice
            }
            newDevice = dev
        }
        let newInput = try AVCaptureDeviceInput(device: newDevice)

        try await runOnSessionQueue {
            self.session.beginConfiguration()
            for input in self.session.inputs {
                guard let deviceInput = input as? AVCaptureDeviceInput,
                      deviceInput.device.hasMediaType(.audio)
                else { continue }
                self.session.removeInput(deviceInput)
            }
            if self.session.canAddInput(newInput) { self.session.addInput(newInput) }
            self.session.commitConfiguration()
        }
        self.lastFallbackReason = nil
    }

    /// Resolve a preferred-or-default device for `configure()`. If a
    /// preferred ID is supplied but the device isn't present, append a
    /// human-readable fallback message and return the system default — the
    /// app stays usable; the UI surfaces the message via
    /// `lastFallbackReason`.
    private static func resolveDevice(
        preferredID: String?,
        mediaType: AVMediaType,
        fallbackMessages: inout [String],
        kind: String
    ) -> AVCaptureDevice? {
        if let preferredID, let dev = AVCaptureDevice(uniqueID: preferredID) {
            return dev
        }
        let defaultDevice = AVCaptureDevice.default(for: mediaType)
        if preferredID != nil {
            // We had a saved preference but couldn't find it. Build a
            // friendly message — we don't know the device's localizedName
            // anymore (it's gone) so reference it by the saved ID with a
            // short prefix so the user has at least a clue.
            let shortID = String(preferredID!.prefix(12))
            fallbackMessages.append(
                "Saved \(kind.lowercased()) (\(shortID)…) was unavailable; using the system default."
            )
        }
        return defaultDevice
    }

    // MARK: - Session-queue dispatch

    /// Polls `hasProducedSampleSinceStart` until a frame lands or the timeout
    /// expires. AVFoundation's `session.startRunning()` returns before the
    /// camera pipeline is actually producing frames; without this wait,
    /// `movieOutput.startRecording` can race and time out on a cold session.
    /// Polling at 50ms granularity is plenty fast for the ~hundreds-of-ms
    /// warmup we expect.
    private func waitForWarmup(timeout: TimeInterval) async throws {
        let start = Date()
        while !dataQueue.sync(execute: { hasProducedSampleSinceStart }) {
            if Date().timeIntervalSince(start) > timeout {
                throw CaptureError.firstSampleTimeout
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Bridges async/await callers onto the serial `sessionQueue` so
    /// `session.startRunning()`, configuration changes, and
    /// `movieOutput.startRecording(...)` all run there. The serial queue's
    /// FIFO ordering replaces the polling-based warmup wait — by the time
    /// a later block runs, every prior session op has fully returned.
    private func runOnSessionQueue<T: Sendable>(
        _ work: @Sendable @escaping () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            sessionQueue.async {
                do {
                    cont.resume(returning: try work())
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
