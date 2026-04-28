import AVFoundation
import Observation

enum CaptureError: Error {
    case noVideoDevice
    case noAudioDevice
    case noSuitableFormat
    case permissionDenied(media: AVMediaType)
    case alreadyRecording
    case firstSampleTimeout
    /// `AVCaptureSession.synchronizationClock` is not the host-time clock.
    /// We refuse to start in this case rather than silently producing
    /// misaligned timestamps; a future v2 can convert PTS via
    /// `CMSyncConvertTime` instead.
    case unsynchronizedClock
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

    func configure() async throws {
        try await ensurePermission(.video)
        try await ensurePermission(.audio)

        guard let video = AVCaptureDevice.default(for: .video) else {
            throw CaptureError.noVideoDevice
        }
        guard let audio = AVCaptureDevice.default(for: .audio) else {
            throw CaptureError.noAudioDevice
        }
        self.videoDevice = video

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
        try checkSessionClock()
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

    /// `AVCaptureSession.synchronizationClock` is normally
    /// `CMClockGetHostTimeClock()`, matching `CACurrentMediaTime()`. On
    /// certain Continuity Camera or external pro-capture paths it's a
    /// device-derived clock; we refuse rather than silently produce
    /// misaligned timestamps. A future v2 can convert via `CMSyncConvertTime`.
    private func checkSessionClock() throws {
        let clock: CMClock? = session.synchronizationClock
        if let c = clock, c !== CMClockGetHostTimeClock() {
            throw CaptureError.unsynchronizedClock
        }
    }

    func stopRecording() async throws -> Double {
        try await withCheckedThrowingContinuation { cont in
            self.stopContinuation = cont
            movieOutput.stopRecording()
        }
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
        awaitingFirstSample = false
        t0Continuation = nil
        firstSampleTimeoutTask?.cancel()
        firstSampleTimeoutTask = nil
        cont.resume(returning: pts.seconds)   // host-time clock; same as CACurrentMediaTime()
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
}
