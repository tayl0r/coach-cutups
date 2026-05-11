import SwiftUI

struct KeyCommandView: NSViewRepresentable {
    let appMode: AppMode
    let onSkip: (Double) -> Void
    let onTogglePlay: () -> Void
    /// Invoked for R or Esc. Whether this starts a new recording, stops an
    /// active one, or is ignored is decided here based on `appMode`.
    let onToggleRecord: () -> Void
    /// Invoked for Esc when in a preview mode. Wired to clear the clip
    /// selection so the player returns to the source.
    let onClosePreview: () -> Void
    /// Invoked for ⌘0. Wired to reset the workspace zoom transform back to
    /// identity so the player frame fills the viewport without translation.
    let onResetZoom: () -> Void
    /// Current zoom scale, fed in so plain `2` / `3` (zoom out / in by
    /// 0.25×) can compute their absolute target without the view holding
    /// stale state.
    let currentZoomScale: Double
    /// Invoked for plain `1` (target scale 1.0×, cursor ignored), `2`
    /// (current − 0.25×, cursor-pivoted), and `3` (current + 0.25×,
    /// cursor-pivoted). First param is the absolute target scale; second
    /// is the cursor position in [0,1]² normalized to the source player
    /// view, origin top-left, clamped — so a press while the cursor is in
    /// the black surround zooms toward the nearest player edge rather than
    /// producing an out-of-range pivot.
    let onZoomLevel: (Double, CGPoint) -> Void
    /// True when ContentView's selectedTagFilter is non-nil. Lets the
    /// Esc handler fire onClearTagFilter as a third cascade layer
    /// (after stop-recording and close-preview).
    let hasTagFilter: Bool
    /// Invoked when Esc fires in scanning mode and a filter is active.
    /// Owned by ContentView; sets selectedTagFilter = nil.
    let onClearTagFilter: () -> Void

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
        v.onResetZoom = onResetZoom
        v.currentZoomScale = currentZoomScale
        v.onZoomLevel = onZoomLevel
        v.hasTagFilter = hasTagFilter
        v.onClearTagFilter = onClearTagFilter
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
    static let zero: UInt16 = 0x1D       // kVK_ANSI_0
    static let one: UInt16 = 0x12        // kVK_ANSI_1 — reset zoom to 1×
    static let two: UInt16 = 0x13        // kVK_ANSI_2 — zoom out by step
    static let three: UInt16 = 0x14      // kVK_ANSI_3 — zoom in by step
}

/// Per-press zoom step for keys 2 / 3. 0.25× lands evenly on the existing
/// snap notches (1.0, 1.25, 1.5, 2.0…) so a sequence of presses tracks the
/// notch ladder predictably.
private let zoomKeyStep: Double = 0.25

final class KeyCatchingView: NSView {
    var appMode: AppMode = .scanning
    var onSkip: (Double) -> Void = { _ in }
    var onTogglePlay: () -> Void = {}
    var onToggleRecord: () -> Void = {}
    var onClosePreview: () -> Void = {}
    var onResetZoom: () -> Void = {}
    var currentZoomScale: Double = 1.0
    var onZoomLevel: (Double, CGPoint) -> Void = { _, _ in }
    var hasTagFilter: Bool = false
    var onClearTagFilter: () -> Void = {}

    private func isPreviewMode() -> Bool {
        switch appMode {
        case .previewClip, .previewLoading: return true
        default: return false
        }
    }

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
            let textIsFocused = window.firstResponder is NSText
            // Most shortcuts must defer to a focused text field — typing
            // "space", "a", "d" into a name/tag/notes field shouldn't fire
            // transport commands. Esc is the exception while previewing a
            // clip: if focus has wandered into the inspector, the user
            // still expects Esc to bail back to the source. Field-edit
            // commits happen on focus-loss (and on Enter for the name
            // field) so nothing in-flight is dropped — the focus change
            // induced by Esc still flows through ClipInspector's
            // onChange(of: focusedField) path.
            if textIsFocused && !(event.keyCode == KeyCode.escape && self.isPreviewMode()) {
                return event
            }

            // While the recording is being prepared (waiting for the first
            // sample buffer), ignore every shortcut. Recording any event in
            // this window would anchor it to a t < 0 once t0 lands.
            if self.appMode == .recordingStarting { return nil }

            switch event.keyCode {
            case KeyCode.r:
                // R toggles recording in scanning and recording modes; preview
                // modes ignore it (the user may still want to flip back via Esc/Cmd).
                switch self.appMode {
                case .scanning, .recording:
                    self.onToggleRecord()
                    return nil
                default:
                    return event
                }
            case KeyCode.escape:
                // Esc cascade: stop recording, close preview, clear tag
                // filter, then fall through to AppKit (close popover,
                // dismiss sheet). Each layer unwinds one piece of view
                // state so two Esc presses from "previewing with a
                // filter" leave you at default scanning + no filter.
                switch self.appMode {
                case .recording:
                    self.onToggleRecord()
                    return nil
                case .previewClip, .previewLoading:
                    self.onClosePreview()
                    return nil
                default:
                    if self.hasTagFilter {
                        self.onClearTagFilter()
                        return nil
                    }
                    return event
                }
            case KeyCode.leftArrow, KeyCode.a:
                let delta: Double = event.modifierFlags.contains(.shift) ? -10 : -3
                self.onSkip(delta)
                return nil
            case KeyCode.rightArrow, KeyCode.d:
                let delta: Double = event.modifierFlags.contains(.shift) ? +10 : +3
                self.onSkip(delta)
                return nil
            case KeyCode.space:                 self.onTogglePlay(); return nil
            case KeyCode.zero:
                // ⌘0 resets the video zoom transform. Without ⌘ the keystroke
                // falls through so typing "0" elsewhere (e.g. number-only
                // fields once we add them) still works normally.
                if event.modifierFlags.contains(.command) {
                    self.onResetZoom()
                    return nil
                }
                return event
            case KeyCode.one, KeyCode.two, KeyCode.three:
                // Plain `1` / `2` / `3` set or step the source zoom. Only
                // active in source-visible modes; preview modes have no MPV
                // view to pivot against, so the keystrokes fall through
                // (AppKit's default beep is fine — the user shouldn't be
                // attempting source-zoom shortcuts mid-preview).
                let modSignificant: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
                guard event.modifierFlags.intersection(modSignificant).isEmpty else { return event }
                switch self.appMode {
                case .scanning, .recording:
                    let target: Double
                    switch event.keyCode {
                    case KeyCode.one:   target = 1.0
                    case KeyCode.two:   target = self.currentZoomScale - zoomKeyStep
                    case KeyCode.three: target = self.currentZoomScale + zoomKeyStep
                    default:            return event
                    }
                    let cursor = self.cursorInPlayerView() ?? CGPoint(x: 0.5, y: 0.5)
                    self.onZoomLevel(target, cursor)
                    return nil
                default:
                    return event
                }
            default: return event
            }
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// Cursor position in the source player view, normalized to [0,1]² with
    /// origin at top-left, clamped. Returns nil when the MPV view isn't in
    /// the hierarchy (e.g. the user pressed a zoom key in a preview mode
    /// the switch above didn't already gate out — defensive). Mirrors
    /// `ZoomGesture.cursor(in:event:)`'s normalization so a cursor-pivoted
    /// hotkey lands on the same source point a scroll-wheel zoom would.
    private func cursorInPlayerView() -> CGPoint? {
        guard let window, let target = Self.findMPVView(in: window.contentView) else { return nil }
        let mouseInWindow = window.mouseLocationOutsideOfEventStream
        let p = target.convert(mouseInWindow, from: nil)
        let bw = target.bounds.width
        let bh = target.bounds.height
        guard bw > 0, bh > 0 else { return nil }
        let nx = p.x / bw
        let ny = (target.isFlipped ? p.y : (bh - p.y)) / bh
        return CGPoint(x: max(0, min(1, nx)), y: max(0, min(1, ny)))
    }

    private static func findMPVView(in view: NSView?) -> MPVRenderingNSView? {
        guard let view else { return nil }
        if let mpv = view as? MPVRenderingNSView { return mpv }
        for sub in view.subviews {
            if let mpv = findMPVView(in: sub) { return mpv }
        }
        return nil
    }
}
