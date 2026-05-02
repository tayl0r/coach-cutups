# AVCaptureSession sessionQueue Refactor — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move every `AVCaptureSession` interaction in `CaptureSessionController` onto a dedicated serial dispatch queue (`sessionQueue`), matching Apple's canonical AVCam pattern. Eliminates the cold-session race that caused first-record failures and removes the polling-based warmup workaround.

**Architecture:** Add `private let sessionQueue = DispatchQueue(label: "videoCoach.capture.session")`. All `session.{begin/commit}Configuration / addInput / addOutput / removeInput / removeOutput / startRunning / stopRunning` calls and `movieOutput.startRecording` happen inside `sessionQueue.async` blocks. Public async methods bridge via `withCheckedContinuation`. The data-output delegate keeps using its existing `dataQueue` — sessionQueue and dataQueue are distinct queues with distinct purposes.

**Tech Stack:** Swift 5.9+, AVFoundation on macOS 14.0+, Xcode 16+. The `@Observable` macro on `CaptureSessionController` doesn't require main-thread mutation; SwiftUI tracking handles cross-thread observation.

**Authoritative references:**
- [AVCaptureSession.startRunning() docs](https://developer.apple.com/documentation/avfoundation/avcapturesession/1388185-startrunning) — "blocking call, dispatch to background queue"
- [Apple AVCam Swift sample](https://github.com/Lax/Learn-iOS-Swift-by-Examples/blob/master/AVCam/Swift/AVCam/CameraViewController.swift) — canonical sessionQueue pattern
- [AVCaptureSession docs](https://developer.apple.com/documentation/avfoundation/avcapturesession) — "all calls to a capture session are blocking"

**Verification approach:** No automated tests for AVFoundation behavior (no real-hardware test rig). After each task, build via `scripts/run.sh` and verify the build succeeds. Final manual smoke test: cold launch → press R → recording starts cleanly with NO error alert; subsequent records also work.

**Out of scope:**
- The `@Observable` data race smell on cross-thread property writes — works in practice on Swift 5.9 strict-concurrency-relaxed mode; revisit only if Swift 6 strict concurrency surfaces an actual diagnostic.
- Replacing the `awaitingFirstSample` / `t0Continuation` machinery — that lives on `dataQueue` and is independent of the session-queue refactor.
- Reverting the `pauseSession()`/warmup-flag/host-time-fallback additions from commits `6915881` and `57a6888`. The fallback (`CACurrentMediaTime()` when `CMSyncConvertTime` returns invalid) and `pauseSession` semantics stay; only the *polling-based warmup wait* gets removed (Task 6).

**Files touched (all in this repo):**
- Modify: `App/Capture/CaptureSessionController.swift`
- Modify: `App/ContentView.swift` (only if any callsite signature changes — likely no changes)

---

## Task 1: Add sessionQueue and a small async dispatch helper

**Files:**
- Modify: `App/Capture/CaptureSessionController.swift` — add property + helper method

**Step 1: Edit CaptureSessionController.swift**

Locate the existing queue declaration (search for `private let dataQueue = DispatchQueue(label: "videoCoach.capture.data")`) and immediately below it add:

```swift
    /// Serial queue for all `AVCaptureSession` interactions. Apple's AVCam
    /// sample dispatches every session op to a queue like this because
    /// `startRunning()` is documented as blocking, and AVFoundation's own
    /// callbacks can race a stepped-on main runloop. Distinct from
    /// `dataQueue` (sample-buffer delivery) on purpose — the two queues
    /// have unrelated lifecycles.
    private let sessionQueue = DispatchQueue(label: "videoCoach.capture.session")
```

Then, near the bottom of the class (right before the closing `}` of `CaptureSessionController`, after `audioDeviceUniqueID`'s computed property), add this helper:

```swift
    // MARK: - Session-queue dispatch

    /// Bridges async/await callers onto the serial `sessionQueue` so
    /// `session.startRunning()`, configuration changes, and
    /// `movieOutput.startRecording(...)` all run there. The serial queue's
    /// FIFO ordering replaces the polling-based warmup wait — by the time
    /// a later block runs, every prior session op has fully returned.
    private func runOnSessionQueue<T>(
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
```

**Step 2: Build**

Run: `scripts/run.sh`
Expected: `** BUILD SUCCEEDED **` and the app launches. (The new property + helper are unused so far — no behavior change.)

**Step 3: Commit**

```bash
git add App/Capture/CaptureSessionController.swift
git commit -m "$(cat <<'EOF'
refactor(capture): add sessionQueue and runOnSessionQueue helper

Inert addition — no callsites yet. Subsequent commits move each
session interaction (configure, prepareForRecording, startRecording,
stop/pause/teardown, switchVideoDevice/switchAudioDevice) onto this
queue, matching Apple's canonical AVCam pattern.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Move `configure(...)`'s session work onto sessionQueue

**Files:**
- Modify: `App/Capture/CaptureSessionController.swift` — `configure(preferredCameraID:preferredMicID:)`

**Step 1: Replace the session-mutation block**

Find the existing `configure(...)` body (search for `func configure(`). Inside it, locate the block that begins `session.beginConfiguration()` and ends `session.startRunning()` (lines ~126–146 currently). Replace **only that block** with a `runOnSessionQueue` call. The new shape:

```swift
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
```

The lines `self.videoDevice = video` and `self.lastFallbackReason = ...` should remain BEFORE the `runOnSessionQueue` block (they're cheap state writes on the calling actor, no session interaction).

**Step 2: Build**

Run: `scripts/run.sh`
Expected: `** BUILD SUCCEEDED **`

**Step 3: Manual smoke test (user)**

Cold launch the app, open a project with a source video, press R. The first record should still work (existing warmup polling is still in place). If the build crashes or recording fails with a NEW error, revert this task before continuing.

**Step 4: Commit**

```bash
git add App/Capture/CaptureSessionController.swift
git commit -m "$(cat <<'EOF'
refactor(capture): run configure() session ops on sessionQueue

Wraps the session.beginConfiguration → addInput → setPreferredFormat
→ commitConfiguration → startRunning chain in runOnSessionQueue so
the blocking startRunning no longer holds the main thread, matching
Apple's AVCam pattern.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Move `pauseSession()` and `teardown()` onto sessionQueue

**Files:**
- Modify: `App/Capture/CaptureSessionController.swift` — `pauseSession()`, `teardown()`

**Step 1: Make `pauseSession()` async on the queue**

Replace the existing `pauseSession()` body. Note: signature changes to `async`. Caller (`ContentView.swift`) currently calls `capture.pauseSession()` from synchronous context inside an async Task — needs to become `await capture.pauseSession()`.

```swift
    /// Stops the session running so the indicator light goes off, but keeps
    /// the configuration intact (inputs, outputs, format). The next
    /// `prepareForRecording` just calls `startRunning` again, which is much
    /// faster than a full reconfigure. Refuses while recording is active.
    func pauseSession() async {
        guard !isRecording else { return }
        try? await runOnSessionQueue {
            if self.session.isRunning { self.session.stopRunning() }
        }
        // Clear so the next warmup waits for a fresh frame rather than
        // accepting the stale-true from the previous session run.
        dataQueue.sync { hasProducedSampleSinceStart = false }
    }
```

**Step 2: Make `teardown()` async on the queue**

Replace the existing `teardown()` body:

```swift
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
```

**Step 3: Update `ContentView.swift` callsites**

Search for `capture.pauseSession()` and `capture.teardown()` in `App/ContentView.swift`. Each occurrence is inside an `await MainActor.run { ... }` block within a Task. Inside MainActor.run they're synchronous now. Move them OUT of the MainActor.run block and `await` them on the surrounding Task:

For example, this pattern:
```swift
await MainActor.run {
    self.recordingController = nil
    self.pendingRecording = nil
    self.appMode = .scanning
    self.recordingStartedAtHostTime = nil
    capture.pauseSession()
}
```

becomes:

```swift
await MainActor.run {
    self.recordingController = nil
    self.pendingRecording = nil
    self.appMode = .scanning
    self.recordingStartedAtHostTime = nil
}
await capture.pauseSession()
```

There are TWO occurrences inside `stopRecording()` and TWO occurrences inside `startRecording()`'s catch blocks (CaptureError.permissionDenied and the general catch). Update all four. Use `Edit` with `replace_all: false` for each one — the surrounding context is slightly different per call site, so handle them individually.

`teardown()` is currently called nowhere in production code (I added it speculatively). Search confirms — if `grep -n "capture.teardown" App/ContentView.swift` returns nothing, no callsite update needed. Skip this sub-step in that case.

**Step 4: Build**

Run: `scripts/run.sh`
Expected: `** BUILD SUCCEEDED **`. Ignore any pre-existing `@Sendable` capture warning at line 199-ish — it pre-dates this refactor.

**Step 5: Commit**

```bash
git add App/Capture/CaptureSessionController.swift App/ContentView.swift
git commit -m "$(cat <<'EOF'
refactor(capture): run pauseSession/teardown session ops on sessionQueue

Hoists session.stopRunning + input/output removals onto the serial
session queue. Both methods become async; ContentView callsites move
the await out of MainActor.run since the actual session work is no
longer main-bound.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Move `switchVideoDevice` / `switchAudioDevice` onto sessionQueue

**Files:**
- Modify: `App/Capture/CaptureSessionController.swift` — `switchVideoDevice(uniqueID:)`, `switchAudioDevice(uniqueID:)`

**Step 1: Wrap `switchVideoDevice`'s session block**

The existing method already is `async throws`. The body currently calls `session.beginConfiguration()` … `session.commitConfiguration()` synchronously. Replace just the session-mutation block with a `runOnSessionQueue` call. Keep the device-resolution and `AVCaptureDeviceInput(device:)` instantiation BEFORE the queue call (they don't touch the session).

The new shape:

```swift
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
```

**Step 2: Wrap `switchAudioDevice`'s session block**

Apply the same pattern:

```swift
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
```

**Step 3: Build**

Run: `scripts/run.sh`
Expected: `** BUILD SUCCEEDED **`

**Step 4: Commit**

```bash
git add App/Capture/CaptureSessionController.swift
git commit -m "$(cat <<'EOF'
refactor(capture): run device-swap session ops on sessionQueue

switchVideoDevice/switchAudioDevice's session.beginConfiguration →
removeInput → addInput → commitConfiguration chains hop onto
sessionQueue. The AVCaptureDeviceInput init still happens on the
caller's thread — only the actual session mutation is dispatched.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Move `startRecording(to:)`'s `movieOutput.startRecording` onto sessionQueue

**Files:**
- Modify: `App/Capture/CaptureSessionController.swift` — `startRecording(to:)`

**Step 1: Replace the `withCheckedThrowingContinuation` block**

The current body uses `withCheckedThrowingContinuation` directly, with `dataQueue.sync` to register `t0Continuation` and a synchronous `movieOutput.startRecording` call at line ~190. The session-touching call is `movieOutput.startRecording(to: url, recordingDelegate: self)` and the `isRecording = true` assignment.

Replace the existing `func startRecording(to url: URL) async throws -> Double { ... }` body with:

```swift
    func startRecording(to url: URL) async throws -> Double {
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
    }
```

The key change: the `dataQueue.sync` (registering t0Continuation) and `movieOutput.startRecording` calls now live INSIDE `sessionQueue.async`. The serial-queue ordering means the data-output delegate is guaranteed to see `t0Continuation` populated before `awaitingFirstSample` is flipped by `didStartRecordingTo`, even on a cold session.

**Step 2: Build**

Run: `scripts/run.sh`
Expected: `** BUILD SUCCEEDED **`. The pre-existing `@Sendable` warning may move to a slightly different line — that's fine.

**Step 3: Commit**

```bash
git add App/Capture/CaptureSessionController.swift
git commit -m "$(cat <<'EOF'
refactor(capture): run movieOutput.startRecording on sessionQueue

Hoists the file-output kickoff onto the serial session queue, which
guarantees session.startRunning (also on this queue, via prepareForRecording)
fully completed before AVCaptureMovieFileOutput sees the start call.
Eliminates the cold-session race that produced firstSampleTimeout on
the first record after launch.

The data-output continuation registration moves inside the same
queue block so `t0Continuation` is populated before
`didStartRecordingTo` arms `awaitingFirstSample`.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Remove the polling-based warmup wait

**Files:**
- Modify: `App/Capture/CaptureSessionController.swift` — `prepareForRecording`, `waitForWarmup`, `hasProducedSampleSinceStart`

**Why:** sessionQueue's serial ordering replaces the polling. `session.startRunning()` (Task 2 / Task 3) and `movieOutput.startRecording` (Task 5) now both run on sessionQueue; the second is guaranteed to see the first fully complete. The polling helper becomes dead code.

**Step 1: Simplify `prepareForRecording`**

Replace the existing `prepareForRecording` body:

```swift
    /// Brings the session up to "ready to record" state: configures it on
    /// first call, then ensures it's running. Both ops dispatch through
    /// `sessionQueue`, whose serial ordering guarantees that by the time
    /// `startRecording(to:)` enqueues `movieOutput.startRecording`, the
    /// session is fully running. No explicit warmup wait needed —
    /// sessionQueue ordering replaces it. Idempotent.
    func prepareForRecording(
        preferredCameraID: String? = nil,
        preferredMicID: String? = nil
    ) async throws {
        if !isReady {
            try await configure(
                preferredCameraID: preferredCameraID,
                preferredMicID: preferredMicID
            )
        }
        try await runOnSessionQueue {
            if !self.session.isRunning { self.session.startRunning() }
        }
    }
```

The `timeout: TimeInterval = 5.0` parameter goes away. Search ContentView for any callsite passing a timeout — there shouldn't be one, but if there is, remove that argument.

**Step 2: Delete `waitForWarmup`**

Remove the entire `private func waitForWarmup(timeout:) async throws { ... }` method.

**Step 3: Delete `hasProducedSampleSinceStart` and its bookkeeping**

Three places to clean up:

a) Remove the property declaration (the `private var hasProducedSampleSinceStart = false` plus its docstring).

b) In `captureOutput(_:didOutput:from:)` remove the `if !hasProducedSampleSinceStart { ... hasProducedSampleSinceStart = true ... }` block. The remaining body of `captureOutput` keeps using `awaitingFirstSample` / `t0Continuation` exactly as before — that machinery is independent of the warmup flag.

c) In `pauseSession()` and `teardown()`, remove the `dataQueue.sync { hasProducedSampleSinceStart = false }` lines.

**Step 4: Build**

Run: `scripts/run.sh`
Expected: `** BUILD SUCCEEDED **`

**Step 5: Manual smoke test (user)**

This is the load-bearing test. Cold-launch the app via `scripts/run.sh`, open a project with a source video, press R **once**. The first record should start cleanly with no firstSampleTimeout error.

If it still fails: do NOT proceed. Revert Task 6 (`git revert HEAD`) so the polling warmup stays in as a safety net. The sessionQueue refactor (Tasks 1–5) is still a correctness improvement on its own.

**Step 6: Commit**

```bash
git add App/Capture/CaptureSessionController.swift
git commit -m "$(cat <<'EOF'
refactor(capture): drop polling warmup — sessionQueue ordering replaces it

With session.startRunning and movieOutput.startRecording both
dispatched onto the serial sessionQueue, the file output is
guaranteed to see a running session by the time it's asked to
record. The hasProducedSampleSinceStart flag, the
waitForWarmup polling helper, and prepareForRecording's timeout
parameter all become dead code.

Reverts to the AVCam pattern: serial-queue ordering is the synch
mechanism, no explicit wait needed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Final manual integration smoke

**Files:** none (user-driven verification)

**Step 1: Cold-launch test**

Run: `scripts/run.sh`
- Press R immediately on first launch — recording starts without error.
- Stop, press R again — still works.
- Switch camera in Devices menu while idle — no error, light stays off.
- Press R — recording uses the new camera.
- Stop, switch mic, press R — recording uses the new mic.

**Step 2: Permission denial path (optional but recommended)**

In System Settings → Privacy & Security → Camera, revoke access for VideoCoach. Relaunch via `scripts/run.sh`. Press R — should surface the new "Coach Cutups needs camera access…" alert.
Re-grant access in System Settings.

**Step 3: No commit**

This task is verification, not code. If everything passes, the refactor is complete.

---

## Reference skills

- @superpowers:executing-plans — task-by-task execution discipline
- @superpowers:verification-before-completion — build + smoke check between tasks
- @superpowers:systematic-debugging — if any task surfaces unexpected AVFoundation behavior
