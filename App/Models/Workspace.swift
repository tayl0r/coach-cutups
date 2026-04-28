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

    /// Cached AVPlayer per clip for Mode C preview. Populated by a background
    /// preparation Task that hands off finished `AVPlayerItem`s built by
    /// `ClipPreviewBuilder` (Phase 8.1). Phase 6.1 keeps this dict empty —
    /// `previewPlayer(for:)` always returns nil and the UI's polling loop
    /// times out after 2 seconds back to `.scanning`.
    private var _previewCache: [Clip.ID: AVPlayer] = [:]

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

    // MARK: - Preview cache (Mode C)

    /// Returns a cached preview player for the given clip, or nil if the cache
    /// hasn't been populated yet. Phase 6.1 ships the simple cache lookup only;
    /// Phase 8.1 introduces `ClipPreviewBuilder` and the inflight/failure
    /// tracking that prevents duplicate Tasks from a SwiftUI thundering herd.
    func previewPlayer(for id: Clip.ID) -> AVPlayer? {
        // TODO(Phase 8): wire ClipPreviewBuilder. When the cache is empty, kick
        // off a Task that calls `ClipPreviewBuilder.buildPreviewItem(for:project:)`
        // off the main actor, then assigns the resulting AVPlayer into
        // `_previewCache[id]`. Add `_previewInflight` / `_previewFailed` state
        // at the same time so SwiftUI re-queries don't spawn duplicate Tasks.
        return _previewCache[id]
    }

    /// Drops the cached preview player for a clip. Call when the clip's events
    /// or source mapping change so the next access rebuilds with fresh content.
    func invalidatePreviewCache(for id: Clip.ID) {
        _previewCache.removeValue(forKey: id)
    }

    // MARK: - Clip ordering

    /// Drag-to-reorder support for the sidebar list. Resorts by current
    /// `sortIndex`, applies the SwiftUI move, then rewrites `sortIndex` to
    /// match the new ordering and persists.
    func reorderClips(from offsets: IndexSet, to destination: Int) {
        var clips = project.clips.sorted(by: { $0.sortIndex < $1.sortIndex })
        clips.move(fromOffsets: offsets, toOffset: destination)
        for i in clips.indices { clips[i].sortIndex = i }
        project.clips = clips
        try? saveProject()
    }

    // MARK: - Recording (Mode B) helpers

    /// Maps a virtual-concat composition time (the value returned by
    /// `virtualPlayer.currentTime()`) back to the source video that contains
    /// it and the local offset within that source. Walks the cumulative
    /// source durations in order — the same order `rebuildVirtualPlayer`
    /// uses to build the concat. Returns `(0, 0)` if there are no sources.
    func sourceTime(at globalSeconds: Double) -> (sourceIndex: Int, sourceLocalSeconds: Double) {
        guard !project.sourceVideos.isEmpty else { return (0, 0) }
        var cumulative: Double = 0
        for (i, src) in project.sourceVideos.enumerated() {
            let next = cumulative + src.durationSeconds
            if globalSeconds < next {
                return (i, max(0, globalSeconds - cumulative))
            }
            cumulative = next
        }
        // Past the end of the concat — clamp to the end of the last source.
        let last = project.sourceVideos.count - 1
        return (last, project.sourceVideos[last].durationSeconds)
    }

    /// Absolute URL of a clip's `.mov` file. The clip stores only the
    /// basename; the full path is `<projectFolder>/recordings/<filename>`.
    func recordingURL(for filename: String) -> URL? {
        guard let folder else { return nil }
        return ProjectStore.recordingsDir(in: folder).appendingPathComponent(filename)
    }

    /// The directory under which new clip recordings are written. Returns
    /// nil if the project hasn't been opened yet (no folder).
    var recordingsDir: URL? {
        guard let folder else { return nil }
        return ProjectStore.recordingsDir(in: folder)
    }

    /// Appends a finished clip to the project and persists. Called by
    /// ContentView after `CaptureSessionController.stopRecording` resolves.
    func addClip(_ clip: Clip) {
        project.clips.append(clip)
        try? saveProject()
    }
}
