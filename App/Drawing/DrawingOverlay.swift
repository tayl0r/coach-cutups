import SwiftUI
import VideoCoachCore

/// SwiftUI wrapper for `DrawingOverlayView`. Forwards finished strokes to
/// the `RecordingController` via `onStrokeFinished`. The auto-clear duration
/// is bound externally so the toolbar's "Auto-clear (5s)" toggle controls it.
struct DrawingOverlay: NSViewRepresentable {
    var autoClearAfterSeconds: Double?
    var onStrokeFinished: (Stroke) -> Void
    /// Bumped by the parent to trigger a `clearAll()` on the underlying
    /// view (e.g. when the user taps "Clear All"). SwiftUI invokes
    /// `updateNSView` whenever any property changes; we only call
    /// `clearAll()` when this counter actually moved.
    var clearAllToken: Int

    func makeNSView(context: Context) -> DrawingOverlayView {
        let v = DrawingOverlayView(frame: .zero)
        v.autoClearAfterSeconds = autoClearAfterSeconds
        v.onStrokeFinished = onStrokeFinished
        context.coordinator.lastClearToken = clearAllToken
        return v
    }

    func updateNSView(_ v: DrawingOverlayView, context: Context) {
        v.autoClearAfterSeconds = autoClearAfterSeconds
        v.onStrokeFinished = onStrokeFinished
        if context.coordinator.lastClearToken != clearAllToken {
            v.clearAll()
            context.coordinator.lastClearToken = clearAllToken
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastClearToken: Int = 0
    }
}
