import SwiftUI
import AVFoundation

struct KeyCommandView: NSViewRepresentable {
    let player: AVPlayer?
    let onSkip: (Double) -> Void
    let onTogglePlay: () -> Void

    func makeNSView(context: Context) -> KeyCatchingView {
        let v = KeyCatchingView()
        v.onSkip = onSkip
        v.onTogglePlay = onTogglePlay
        return v
    }
    func updateNSView(_ v: KeyCatchingView, context: Context) {
        v.onSkip = onSkip; v.onTogglePlay = onTogglePlay
    }
}

/// Position-based key codes (work across QWERTY, Dvorak, Colemak, etc).
/// `kVK_ANSI_A` / `D` bind to the *physical* keys where A/D are on a standard ANSI layout —
/// which is where transport controls conventionally live in video editors — not to whatever
/// character those positions produce on the user's layout.
private enum KeyCode {
    static let a: UInt16 = 0x00          // kVK_ANSI_A
    static let d: UInt16 = 0x02          // kVK_ANSI_D
    static let leftArrow: UInt16 = 0x7B  // kVK_LeftArrow
    static let rightArrow: UInt16 = 0x7C // kVK_RightArrow
    static let space: UInt16 = 0x31      // kVK_Space
}

final class KeyCatchingView: NSView {
    var onSkip: (Double) -> Void = { _ in }
    var onTogglePlay: () -> Void = {}

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
            guard let self, self.window?.isKeyWindow == true else { return event }
            switch event.keyCode {
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
