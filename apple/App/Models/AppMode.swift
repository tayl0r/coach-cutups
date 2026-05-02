import Foundation
import VideoCoachCore

/// Mutually exclusive UI modes that drive transport, sidebar enablement, and which
/// AVPlayer is mounted on the player surface. The order/cases here are referenced
/// by Phases 6, 7, and 8 — keep the layout stable.
enum AppMode: Equatable {
    case scanning
    /// `R` pressed; awaiting first sample buffer from the capture session before
    /// flipping to `.recording`. Phase 7 territory; included here because the
    /// transport bar must already understand the case.
    case recordingStarting
    case recording
    /// Building the AVPlayer + pre-decoding freeze frames for the selected clip.
    /// Phase 6.1 ships a 2-second timeout fallback; Phase 8.1 wires
    /// `ClipPreviewBuilder` so the cache actually populates.
    case previewLoading(Clip.ID)
    case previewClip(Clip.ID)
}
