import AVFoundation
import Foundation

public enum AssetTrackError: Error {
    case noVideoTrack(URL)
}

public extension AVAsset {
    /// Returns the first enabled video track if any, otherwise the first video track,
    /// otherwise throws `AssetTrackError.noVideoTrack`.
    func primaryVideoTrack() async throws -> AVAssetTrack {
        let tracks = try await loadTracks(withMediaType: .video)
        if let primary = tracks.first(where: { $0.isEnabled }) ?? tracks.first {
            return primary
        }
        throw AssetTrackError.noVideoTrack((self as? AVURLAsset)?.url ?? URL(fileURLWithPath: "/"))
    }

    /// Returns the first enabled audio track if any, otherwise the first audio track,
    /// otherwise nil. Never throws when audio is simply absent.
    func optionalAudioTrack() async throws -> AVAssetTrack? {
        let tracks = try await loadTracks(withMediaType: .audio)
        return tracks.first(where: { $0.isEnabled }) ?? tracks.first
    }
}
