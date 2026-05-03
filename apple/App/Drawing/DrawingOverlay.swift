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
    /// Workspace-canonical zoom state, mirrored into the overlay so its
    /// scroll/pinch gestures can compute deltas. The overlay sits on top of
    /// the MPV view during recording, so without this it'd block all zoom/
    /// pan input.
    var currentZoom: Zoom
    var onZoomChange: (Zoom) -> Void

    func makeNSView(context: Context) -> DrawingOverlayView {
        let v = DrawingOverlayView(frame: .zero)
        v.autoClearAfterSeconds = autoClearAfterSeconds
        v.onStrokeFinished = onStrokeFinished
        v.onZoomChange = onZoomChange
        v.setCurrentZoom(currentZoom)
        context.coordinator.lastClearToken = clearAllToken
        return v
    }

    func updateNSView(_ v: DrawingOverlayView, context: Context) {
        v.autoClearAfterSeconds = autoClearAfterSeconds
        v.onStrokeFinished = onStrokeFinished
        v.onZoomChange = onZoomChange
        v.setCurrentZoom(currentZoom)
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
