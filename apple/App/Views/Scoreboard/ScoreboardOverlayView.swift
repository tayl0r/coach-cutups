import SwiftUI
import AppKit
import VideoCoachCore

struct ScoreboardOverlayView: NSViewRepresentable {
    let workspace: Workspace

    func makeNSView(context: Context) -> ScoreboardLayerView {
        let v = ScoreboardLayerView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    func updateNSView(_ nsView: ScoreboardLayerView, context: Context) {
        let next: ScoreboardState?
        if let player = workspace.sourcePlayer {
            next = scoreboardState(
                atSourceIndex: player.playlistPos,
                sourceSeconds: player.timePos,
                project: workspace.project)
        } else {
            next = nil
        }
        nsView.setStateIfChanged(next)
    }
}

final class ScoreboardLayerView: NSView {
    private var lastState: ScoreboardState?

    override var isFlipped: Bool { true }   // top-left user space

    func setStateIfChanged(_ s: ScoreboardState?) {
        if s != lastState {
            lastState = s
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let state = lastState else { return }
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        drawScoreboard(into: cg, size: bounds.size, state: state)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
