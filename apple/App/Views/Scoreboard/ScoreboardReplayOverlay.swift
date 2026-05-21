import SwiftUI
import AppKit
import AVFoundation
import VideoCoachCore

struct ScoreboardReplayOverlay: NSViewRepresentable {
    let player: AVPlayer
    let clip: Clip
    let workspace: Workspace

    func makeNSView(context: Context) -> ScoreboardLayerView {
        let v = ScoreboardLayerView()
        context.coordinator.attach(player: player, view: v, clip: clip, workspace: workspace)
        return v
    }

    func updateNSView(_ nsView: ScoreboardLayerView, context: Context) {
        // If the represented player or clip identity changes (SwiftUI may keep
        // the view alive across `.previewClip(id)` reuse), re-attach the
        // observer to the new player and refresh the captured clip. Without
        // this, the coordinator would keep observing the previous player.
        context.coordinator.rebindIfNeeded(player: player, clip: clip, workspace: workspace, view: nsView)
    }

    static func dismantleNSView(_ nsView: ScoreboardLayerView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private weak var player: AVPlayer?
        private var token: Any?
        private weak var view: ScoreboardLayerView?
        private weak var workspace: Workspace?
        private var clip: Clip?

        func attach(player: AVPlayer, view: ScoreboardLayerView, clip: Clip, workspace: Workspace) {
            self.player = player
            self.view = view
            self.workspace = workspace
            self.clip = clip
            // 1 Hz suffices for whole-second clock updates.
            let interval = CMTime(value: 1, timescale: 1)
            token = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                // Observer queue is `.main`, so we're already on the main
                // thread — assume the MainActor to read `workspace.project`
                // (which is @MainActor-isolated on `Workspace`).
                MainActor.assumeIsolated {
                    self?.tick(compositionTime: time.seconds)
                }
            }
        }

        /// Refreshes the captured clip on every `updateNSView`, and re-attaches
        /// the time observer when the represented `AVPlayer` instance changes.
        func rebindIfNeeded(player: AVPlayer, clip: Clip, workspace: Workspace, view: ScoreboardLayerView) {
            self.clip = clip
            self.workspace = workspace
            self.view = view
            if self.player !== player {
                detach()
                attach(player: player, view: view, clip: clip, workspace: workspace)
            }
        }

        func detach() {
            if let token, let player { player.removeTimeObserver(token) }
            token = nil
            player = nil
        }

        @MainActor
        private func tick(compositionTime t: Double) {
            guard let workspace, let clip, let view else { return }
            // Composition time → record time is 1:1 in a single-clip preview
            // (freezes baked via scaleTimeRange in ClipPreviewBuilder).
            // Record time → source time MUST go through sourceTime(atRecordTime:)
            // to correctly hold source time still during .pause segments.
            let recordTime = max(0, min(t, clip.recordingDuration))
            let sourceSeconds = clip.sourceTime(atRecordTime: recordTime)
            let state = scoreboardState(
                atSourceIndex: clip.sourceIndex,
                sourceSeconds: sourceSeconds,
                project: workspace.project)
            view.setStateIfChanged(state)
        }
    }
}
