import AVFoundation
import Observation

enum CaptureError: Error {
    case noVideoDevice
    case noAudioDevice
    case noSuitableFormat
    case permissionDenied(media: AVMediaType)
    case alreadyRecording
    case firstSampleTimeout
    /// Sample-buffer PTS could not be converted from the device clock to the
    /// host clock (the two clocks aren't synchronizable). Should be impossible
    /// on the standard built-in camera / Continuity Camera path; would only
    /// fire on a pathological external pro-capture device.
    case clockConversionFailed
    /// User picked a device by `uniqueID` (via the Devices menu) that has
    /// since vanished — typically a USB camera unplugged between menu open
    /// and click. Surfaced via the menu's onChange so the UI reverts the
    /// selection back to whatever the session is actually using.
    case deviceUnavailable(String)
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

    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let dataOutput = AVCaptureVideoDataOutput()
    private let dataQueue = DispatchQueue(label: "videoCoach.capture.data")

    /// Resumed with the host-time PTS (in seconds) of the first sample buffer
    /// that lands AFTER the file output has opened. nil between recordings.
    /// All access to the next three fields happens on `dataQueue`.
    private var t0Continuation: CheckedContinuation<Double, Error>?
    private var awaitingFirstSample = false
    private var firstSampleTimeoutTask: Task<Void, Never>?

    private var stopContinuation: CheckedContinuation<Double, Error>?
    private var videoDevice: AVCaptureDevice?

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

        session.beginConfiguration()
        // NOTE: `AVCaptureSession.Preset.inputPriority` is iOS-only. On macOS
        // we leave the preset alone — setting `device.activeFormat` after
        // `addInput` transitions the session's effective preset to
        // input-priority semantics automatically, which is exactly what we
        // want (the explicit `device.activeFormat` we set below wins).
        if session.canAddInput(videoInput) { session.addInput(videoInput) }
        if session.canAddInput(audioInput) { session.addInput(audioInput) }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        if session.canAddOutput(dataOutput) {
            dataOutput.setSampleBufferDelegate(self, queue: dataQueue)
            dataOutput.alwaysDiscardsLateVideoFrames = true
            session.addOutput(dataOutput)
        }
        // Canonical AVCam ordering: `addInput` resets the device to the
        // preset's default format, so `activeFormat` MUST be set after the
        // input is added (otherwise it's silently undone — notably back to
        // 1920×1440 4:3 on Continuity Camera).
        try setPreferredFormat(on: video)
        session.commitConfiguration()
        session.startRunning()
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
            dataQueue.sync {
                self.t0Continuation = cont
                self.awaitingFirstSample = false   // armed in didStartRecordingTo
            }
            movieOutput.startRecording(to: url, recordingDelegate: self)
            isRecording = true
            firstSampleTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
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

    func stopRecording() async throws -> Double {
        try await withCheckedThrowingContinuation { cont in
            self.stopContinuation = cont
            movieOutput.stopRecording()
        }
    }

    /// Tears the session down so the OS frees the camera/mic — turns off the
    /// recording-indicator light. Called after `stopRecording` returns (or
    /// after a failed `configure`) so the camera isn't held while the user is
    /// just scanning footage. Calls to `configure` after `teardown` are
    /// expected to succeed: this restores the controller to its initial
    /// state. Refuses while a recording is still in flight.
    func teardown() {
        guard !isRecording else { return }
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.commitConfiguration()
        videoDevice = nil
        lastFallbackReason = nil
        isReady = false
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Runs on `dataQueue`.
        guard awaitingFirstSample, let cont = t0Continuation else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // Some external capture devices occasionally emit invalid/NaN PTS
        // during clock resets. Discard and wait for the next sample; the 2s
        // timeout still protects against pathological cases.
        guard pts.flags.contains(.valid), pts.seconds.isFinite else { return }

        // Re-read the session clock per-sample. With deferred-capture the
        // session has only been running for tens of milliseconds when the
        // first frame arrives, so `synchronizationClock` may have been nil
        // (or still calibrating against host time) at startRecording-time.
        // Reading fresh here picks up the device clock as soon as it lands.
        let hostClock = CMClockGetHostTimeClock()
        let currentSessionClock = session.synchronizationClock ?? hostClock
        let hostTime: CMTime
        if currentSessionClock === hostClock {
            hostTime = pts
        } else {
            hostTime = CMSyncConvertTime(pts, from: currentSessionClock, to: hostClock)
        }
        guard hostTime.flags.contains(.valid), hostTime.seconds.isFinite else {
            // Conversion failed — typical on a cold session before the device
            // clock has been calibrated against host time. Discard this frame
            // and let the next one try; the 2s `firstSampleTimeout` catches
            // genuinely-unsynchronizable devices (which surfaces a clearer
            // error than clockConversionFailed anyway).
            return
        }

        awaitingFirstSample = false
        t0Continuation = nil
        firstSampleTimeoutTask?.cancel()
        firstSampleTimeoutTask = nil
        cont.resume(returning: hostTime.seconds)
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
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        isRecording = false
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

        session.beginConfiguration()
        for input in session.inputs {
            guard let deviceInput = input as? AVCaptureDeviceInput,
                  deviceInput.device.hasMediaType(.video)
            else { continue }
            session.removeInput(deviceInput)
        }
        if session.canAddInput(newInput) { session.addInput(newInput) }
        // Same canonical ordering as `configure()` — addInput resets
        // activeFormat, so the explicit format selection MUST follow it.
        try setPreferredFormat(on: newDevice)
        session.commitConfiguration()
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

        session.beginConfiguration()
        for input in session.inputs {
            guard let deviceInput = input as? AVCaptureDeviceInput,
                  deviceInput.device.hasMediaType(.audio)
            else { continue }
            session.removeInput(deviceInput)
        }
        if session.canAddInput(newInput) { session.addInput(newInput) }
        session.commitConfiguration()
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
}
