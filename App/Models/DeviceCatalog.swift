import AVFoundation
import Observation

/// The set of currently-available cameras and microphones, plus the user's
/// menu selection. `ContentView` observes the selection via `.onChange` and
/// drives `CaptureSessionController.switchVideoDevice` /
/// `switchAudioDevice` — keeping the catalog ignorant of the capture
/// session itself, so it stays trivially testable / previewable.
///
/// `lockedByRecording` is mirrored from `appMode` so the menu can disable
/// the pickers while a recording is in progress (the swap call would refuse
/// at the capture layer, but the UI affordance has to come from here).
@Observable
@MainActor
final class DeviceCatalog {
    private(set) var availableCameras: [AVCaptureDevice] = []
    private(set) var availableMicrophones: [AVCaptureDevice] = []

    /// `nil` means "system default." Bound from the menu Pickers and watched
    /// by `ContentView`.
    var selectedCameraID: String? = nil
    var selectedMicID: String? = nil

    /// True while recording — drives `.disabled(...)` on the menu pickers.
    var lockedByRecording: Bool = false

    // `@ObservationIgnored` so the `@Observable` macro leaves them as plain
    // stored properties (without it, the macro injects a wrapper that bars
    // nonisolated reads). They're cleanup-only — no UI ever observes them.
    @ObservationIgnored
    private nonisolated(unsafe) var connectObserver: NSObjectProtocol?
    @ObservationIgnored
    private nonisolated(unsafe) var disconnectObserver: NSObjectProtocol?

    init() {
        refresh()
        // Hot-plug events. AVFoundation posts these on a background queue;
        // pinning to .main lets the @Observable-driven SwiftUI menu update
        // without a manual hop. We hold the tokens so deinit can detach
        // even though this object usually lives for the full app lifetime.
        connectObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVCaptureDeviceWasConnected,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVCaptureDeviceWasDisconnected,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    deinit {
        if let connectObserver {
            NotificationCenter.default.removeObserver(connectObserver)
        }
        if let disconnectObserver {
            NotificationCenter.default.removeObserver(disconnectObserver)
        }
    }

    func refresh() {
        availableCameras = CaptureSessionController.availableCameras()
        availableMicrophones = CaptureSessionController.availableMicrophones()
    }
}
