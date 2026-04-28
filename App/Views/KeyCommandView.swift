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

final class KeyCatchingView: NSView {
    var onSkip: (Double) -> Void = { _ in }
    var onTogglePlay: () -> Void = {}

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
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

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case KeyCode.leftArrow, KeyCode.a:  onSkip(-3)
        case KeyCode.rightArrow, KeyCode.d: onSkip(+3)
        case KeyCode.space:                 onTogglePlay()
        default: super.keyDown(with: event)
        }
    }
}
