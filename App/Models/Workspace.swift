import Foundation
import VideoCoachCore
import AVFoundation
import Observation

enum WorkspaceError: Error {
    case noVideoTrack(URL)
    case bookmarkResolutionFailed(displayName: String)
}

@Observable
@MainActor
final class Workspace {
    var folder: URL?
    var project: Project = Project(name: "Untitled")
    var virtualPlayer: AVPlayer?
    var virtualComposition: AVMutableComposition?

    func openProject(folder: URL) async throws {
        self.folder = folder
        // Distinguish "folder is empty" (create new project) from "project.json exists but
        // is unreadable" (refuse to overwrite — surface to UI). The naive
        // `try? ProjectStore.read(...) ?? Project(...)` would silently destroy a corrupt
        // project file by writing a fresh empty one over it.
        let p: Project
        do {
            p = try ProjectStore.read(from: folder)
        } catch ProjectStoreError.missingProjectJSON {
            p = Project(name: folder.lastPathComponent)
            try ProjectStore.write(p, to: folder)
        }
        // Other errors (corrupt JSON, unsupported format version) propagate to the caller,
        // which surfaces a "Couldn't open project" alert without overwriting the file.
        self.project = p
        try await rebuildVirtualPlayer()
    }

    func saveProject() throws {
        guard let folder else { return }
        try ProjectStore.write(project, to: folder)
    }

    func addSourceVideo(url: URL) async throws {
        let bookmark = try url.bookmarkData(options: [])  // plain — we're unsandboxed
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        project.sourceVideos.append(.init(
            bookmark: bookmark,
            displayName: url.lastPathComponent,
            durationSeconds: duration.seconds))
        try saveProject()
        try await rebuildVirtualPlayer()
    }

    func rebuildVirtualPlayer() async throws {
        guard !project.sourceVideos.isEmpty else { virtualPlayer = nil; return }
        let comp = AVMutableComposition()
        // The virtual-concat composition has no custom compositor reading by track ID,
        // so kCMPersistentTrackID_Invalid (auto-assigned IDs) is fine here. The strict
        // explicit-track-ID rule from the design applies only to the export composition.
        guard let v = comp.addMutableTrack(withMediaType: .video,
                                           preferredTrackID: kCMPersistentTrackID_Invalid),
              let a = comp.addMutableTrack(withMediaType: .audio,
                                           preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return }

        var cursor = CMTime.zero
        for index in project.sourceVideos.indices {
            let url = try resolveAndRefreshBookmark(&project.sourceVideos[index])
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.load(.tracks)
            guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
                throw WorkspaceError.noVideoTrack(url)
            }
            let audioTrack = tracks.first(where: { $0.mediaType == .audio })
            let range = CMTimeRange(start: .zero, duration: duration)
            try v.insertTimeRange(range, of: videoTrack, at: cursor)
            if let audioTrack { try? a.insertTimeRange(range, of: audioTrack, at: cursor) }
            cursor = cursor + duration
        }
        self.virtualComposition = comp
        self.virtualPlayer = AVPlayer(playerItem: AVPlayerItem(asset: comp))
    }

    private func resolveBookmark(_ data: Data, displayName: String) throws -> (URL, isStale: Bool) {
        var stale = false
        // Plain (non-security-scoped) bookmarks: we run unsandboxed under hardened runtime.
        do {
            let url = try URL(resolvingBookmarkData: data,
                              options: [],
                              relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            return (url, isStale: stale)
        } catch {
            throw WorkspaceError.bookmarkResolutionFailed(displayName: displayName)
        }
    }

    /// Resolves and, if the bookmark went stale (e.g. the file was moved), regenerates and persists it.
    private func resolveAndRefreshBookmark(_ ref: inout SourceRef) throws -> URL {
        let (url, isStale) = try resolveBookmark(ref.bookmark, displayName: ref.displayName)
        if isStale {
            ref.bookmark = (try? url.bookmarkData(options: [])) ?? ref.bookmark
            try? saveProject()
        }
        return url
    }
}
