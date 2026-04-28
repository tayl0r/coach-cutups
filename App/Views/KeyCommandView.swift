import SwiftUI
import AVFoundation

struct KeyCommandView: NSViewRepresentable {
    let player: AVPlayer?
    let appMode: AppMode
    let onSkip: (Double) -> Void
    let onTogglePlay: () -> Void
    /// Invoked for R or Esc. Whether this starts a new recording, stops an
    /// active one, or is ignored is decided here based on `appMode`.
    let onToggleRecord: () -> Void
    /// Invoked for Esc when in a preview mode. Wired to clear the clip
    /// selection so the player returns to the source virtual concat.
    let onClosePreview: () -> Void

    func makeNSView(context: Context) -> KeyCatchingView {
        let v = KeyCatchingView()
        apply(to: v)
        return v
    }
    func updateNSView(_ v: KeyCatchingView, context: Context) {
        apply(to: v)
    }

    private func apply(to v: KeyCatchingView) {
        v.appMode = appMode
        v.onSkip = onSkip
        v.onTogglePlay = onTogglePlay
        v.onToggleRecord = onToggleRecord
        v.onClosePreview = onClosePreview
    }
}

/// Position-based key codes (work across QWERTY, Dvorak, Colemak, etc).
/// `kVK_ANSI_A` / `D` bind to the *physical* keys where A/D are on a standard ANSI layout —
/// which is where transport controls conventionally live in video editors — not to whatever
/// character those positions produce on the user's layout.
private enum KeyCode {
    static let a: UInt16 = 0x00          // kVK_ANSI_A
    static let d: UInt16 = 0x02          // kVK_ANSI_D
    static let r: UInt16 = 0x0F          // kVK_ANSI_R
    static let leftArrow: UInt16 = 0x7B  // kVK_LeftArrow
    static let rightArrow: UInt16 = 0x7C // kVK_RightArrow
    static let space: UInt16 = 0x31      // kVK_Space
    static let escape: UInt16 = 0x35     // kVK_Escape
}

final class KeyCatchingView: NSView {
    var appMode: AppMode = .scanning
    var onSkip: (Double) -> Void = { _ in }
    var onTogglePlay: () -> Void = {}
    var onToggleRecord: () -> Void = {}
    var onClosePreview: () -> Void = {}

    private var monitor: Any?

    /// Mouse events fall through to the AVPlayerView underneath so the transport controls
    /// (play, scrub, volume) stay clickable. Keyboard capture happens via a window-scoped
    /// NSEvent monitor instead of first-responder chain — that way clicking the play button
    /// (which makes AVPlayerView first responder) doesn't disable our shortcuts.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, window.isKeyWindow else { return event }

            // While the recording is being prepared (waiting for the first
            // sample buffer), ignore every shortcut. Recording any event in
            // this window would anchor it to a t < 0 once t0 lands.
            if self.appMode == .recordingStarting { return nil }

            // Escape gets evaluated BEFORE the text-field passthrough check.
            // In `.previewClip` we want one Escape to always exit back to
            // scanning even if the user is typing in the Name/Notes/Tags
            // fields; ending field editing first commits any in-flight text
            // (SwiftUI binding writes already happened on each keystroke;
            // resigning first responder also ensures TagField's
            // onDisappear-commit fires cleanly).
            if event.keyCode == KeyCode.escape {
                switch self.appMode {
                case .previewClip, .previewLoading:
                    if window.firstResponder is NSText {
                        // Commits any pending edit by resigning first responder.
                        window.makeFirstResponder(nil)
                    }
                    self.onClosePreview()
                    return nil
                case .recording:
                    self.onToggleRecord()
                    return nil
                default:
                    // Scanning: let AppKit handle Esc normally (e.g., abort
                    // a field edit, dismiss a popover). Don't intercept.
                    return event
                }
            }

            // For every other shortcut, defer to text fields. Otherwise
            // typing "space", "a", "d" into a name/tag/notes field would
            // silently trigger video transport commands instead of inserting
            // characters.
            if window.firstResponder is NSText { return event }

            switch event.keyCode {
            case KeyCode.r:
                // R toggles recording in scanning and recording modes; preview
                // modes ignore it (the user already exits via Esc above).
                switch self.appMode {
                case .scanning, .recording:
                    self.onToggleRecord()
                    return nil
                default:
                    return event
                }
            case KeyCode.leftArrow, KeyCode.a:  self.onSkip(-3); return nil
            case KeyCode.rightArrow, KeyCode.d: self.onSkip(+3); return nil
            case KeyCode.space:                 self.onTogglePlay(); return nil
            default: return event
            }
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
