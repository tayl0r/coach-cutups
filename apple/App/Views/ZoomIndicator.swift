import SwiftUI
import VideoCoachCore

/// Floating overlay that surfaces the current zoom scale in the top-right
/// corner of the player area. Shows the scale as `1.5×` plus a horizontal
/// track with tick marks at the snap notches and a dot for the current
/// position. Hidden at identity since the user has nothing to read.
///
/// Position on the track is logarithmic (1× → 0, 10× → 1), matching how
/// pinch / scroll-wheel zoom feels — a fixed factor per gesture step gives
/// even visual spacing between notches.
struct ZoomIndicator: View {
    let zoom: Zoom

    private var scaleText: String { String(format: "%.2f×", zoom.scale) }

    /// `log2(scale) / log2(10)` clamped to [0, 1].
    private static func logPosition(_ scale: Double) -> Double {
        let denom = log2(10.0)
        return max(0, min(1, log2(max(scale, 1.0)) / denom))
    }

    private static let trackWidth: CGFloat = 140
    private static let trackHeight: CGFloat = 3

    var body: some View {
        HStack(spacing: 10) {
            Text(scaleText)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 56, alignment: .leading)

            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(0.25))
                    .frame(width: Self.trackWidth, height: Self.trackHeight)

                // Notch ticks
                ForEach(Zoom.snapNotches, id: \.self) { n in
                    let x = Self.logPosition(n) * Self.trackWidth
                    Rectangle()
                        .fill(Color.white.opacity(0.55))
                        .frame(width: 1, height: 9)
                        .offset(x: x - 0.5, y: 0)
                }

                // Current position dot
                let dx = Self.logPosition(zoom.scale) * Self.trackWidth
                Circle()
                    .fill(Color.white)
                    .frame(width: 9, height: 9)
                    .offset(x: dx - 4.5, y: 0)
            }
            .frame(width: Self.trackWidth, height: 12)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.55))
        )
        .opacity(zoom.scale > 1.0 ? 1.0 : 0.0)
        .animation(.easeOut(duration: 0.18), value: zoom)
        .allowsHitTesting(false)
    }
}
