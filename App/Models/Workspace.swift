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
    /// `ClipPreviewBuilder`. Lookup-only via `previewPlayer(for:)`; that
    /// method also kicks off the build Task on a cache miss.
    private var _previewCache: [Clip.ID: AVPlayer] = [:]
    /// Clip IDs whose preview is currently being built. Prevents a SwiftUI
    /// thundering herd (several view re-renders during the load window) from
    /// spawning duplicate Tasks per clip.
    private var _previewInflight: Set<Clip.ID> = []
    /// Errors from the most recent failed build, surfaced via
    /// `previewBuildError(for:)` so ContentView can show an alert and revert
    /// to scanning. Cleared on the next successful build.
    private var _previewFailed: [Clip.ID: Error] = [:]

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
        // Undo state is in-memory only — never carries across app launches
        // or project switches. Shred any leftover trash from a prior session.
        lastDeletedClip = nil
        shredTrashDirectory()
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

    /// Returns a cached preview player for the given clip. On a cache miss,
    /// schedules a background Task that runs `ClipPreviewBuilder` off the
    /// main actor and returns nil immediately — callers (ContentView's
    /// `handleSelectionChange`) flip the UI to `.previewLoading` and poll
    /// for the cache or an error to land.
    ///
    /// `_previewInflight` deduplicates the build so SwiftUI re-renders during
    /// the load window don't spawn duplicate Tasks. `_previewFailed` records
    /// the error so the UI can show it without re-attempting on every
    /// subsequent re-render.
    func previewPlayer(for id: Clip.ID) -> AVPlayer? {
        if let cached = _previewCache[id] { return cached }
        if _previewFailed[id] != nil { return nil }
        guard !_previewInflight.contains(id) else { return nil }
        _previewInflight.insert(id)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.preparePreviewPlayer(for: id)
            } catch {
                await MainActor.run { self._previewFailed[id] = error }
            }
            await MainActor.run { _ = self._previewInflight.remove(id) }
        }
        return nil
    }

    /// Returns the most recent build error for `id`, if any. Cleared on the
    /// next successful build.
    func previewBuildError(for id: Clip.ID) -> Error? { _previewFailed[id] }

    /// Drops the cached preview player for a clip. Call when the clip's events
    /// or source mapping change so the next access rebuilds with fresh content.
    func invalidatePreviewCache(for id: Clip.ID) {
        _previewCache.removeValue(forKey: id)
        _previewFailed.removeValue(forKey: id)
    }

    /// In-memory record of the most-recently-deleted clip, available for
    /// `undoLastDelete()`. Cleared by another delete (which trashes the new
    /// clip and shreds the previous trash file) or by a successful undo.
    /// Not persisted — quitting the app loses the undo. Each new project
    /// open also clears this and shreds the trash directory.
    private(set) var lastDeletedClip: DeletedClip?

    /// Snapshot of a deleted clip plus the on-disk path of its recording in
    /// the project's trash directory. The recording file itself was *moved*,
    /// not copied, so undelete restores it without round-tripping data
    /// through RAM (safer for the 30-70MB .mov files we deal with).
    struct DeletedClip: Sendable {
        let clip: Clip
        let trashedRecordingURL: URL
    }

    /// Removes a clip from the project: drops the in-memory entry, MOVES the
    /// underlying `clip-<uuid>.mov` recording to `recordings/.trash/`,
    /// invalidates the preview cache, and persists. The trashed recording
    /// stays on disk until either (a) another clip is deleted (the older
    /// trash entry gets shredded then), or (b) the project is reopened (all
    /// trash gets shredded). The clip's `sortIndex` gap is left as-is —
    /// `reorderClips(from:to:)` re-numbers on next reorder, and the sidebar
    /// sorts by `sortIndex`-ascending so a gap is invisible.
    func deleteClip(id: Clip.ID) throws {
        guard let idx = project.clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = project.clips[idx]
        invalidatePreviewCache(for: id)

        // Shred the previous trash entry — the user already moved past it
        // when they invoked another delete.
        if let prior = lastDeletedClip {
            try? FileManager.default.removeItem(at: prior.trashedRecordingURL)
            lastDeletedClip = nil
        }

        if let folder {
            let recordingsDir = ProjectStore.recordingsDir(in: folder)
            let recordingURL = recordingsDir.appendingPathComponent(clip.recordingFilename)
            let trashDir = recordingsDir.appendingPathComponent(".trash")
            try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
            let trashedURL = trashDir.appendingPathComponent(clip.recordingFilename)
            // Move the .mov into trash so undelete can put it back without
            // double-buffering it through RAM. If the source recording is
            // already gone (e.g., partial cleanup from a past session), we
            // still record the deletion — the metadata is undoable even if
            // the recording isn't.
            if FileManager.default.fileExists(atPath: recordingURL.path) {
                try? FileManager.default.removeItem(at: trashedURL)   // any stale leftover
                try FileManager.default.moveItem(at: recordingURL, to: trashedURL)
                lastDeletedClip = DeletedClip(clip: clip, trashedRecordingURL: trashedURL)
            } else {
                // No file to trash — record the metadata so undelete can at
                // least restore the project entry. The file URL points at
                // a non-existent path; undelete tolerates that.
                lastDeletedClip = DeletedClip(clip: clip, trashedRecordingURL: trashedURL)
            }
        }

        project.clips.remove(at: idx)
        try saveProject()
    }

    /// Restores the most-recently-deleted clip: re-inserts the metadata into
    /// `project.clips` (preserving its original `sortIndex`) and moves the
    /// recording back from `recordings/.trash/`. Returns the restored clip's
    /// id so callers can re-select it; returns nil if there's nothing to
    /// undo.
    @discardableResult
    func undoLastDelete() throws -> Clip.ID? {
        guard let stash = lastDeletedClip else { return nil }
        // If a clip with the same id has somehow re-appeared (shouldn't
        // happen, but be defensive), bail rather than create a duplicate.
        if project.clips.contains(where: { $0.id == stash.clip.id }) {
            lastDeletedClip = nil
            return nil
        }

        // Restore the recording first so the clip's referenced file exists
        // before we re-add the metadata. If the trash file is missing
        // (someone deleted it externally), we still restore the metadata —
        // user gets back the clip entry minus playable media.
        if let folder, FileManager.default.fileExists(atPath: stash.trashedRecordingURL.path) {
            let recordingsDir = ProjectStore.recordingsDir(in: folder)
            let target = recordingsDir.appendingPathComponent(stash.clip.recordingFilename)
            try? FileManager.default.removeItem(at: target)   // shouldn't exist, defensive
            try FileManager.default.moveItem(at: stash.trashedRecordingURL, to: target)
        }

        // Insert at the position that puts the clip back in its original
        // sortIndex slot. Other clips' sortIndexes were never re-numbered,
        // so the gap is still there.
        let insertAt = project.clips.firstIndex(where: { $0.sortIndex > stash.clip.sortIndex })
            ?? project.clips.endIndex
        project.clips.insert(stash.clip, at: insertAt)
        lastDeletedClip = nil
        try saveProject()
        return stash.clip.id
    }

    /// Wipes the project's trash directory. Called on every `openProject` so
    /// undo state never survives across launches (per design — the in-memory
    /// `lastDeletedClip` is also reset by re-instantiating the Workspace).
    private func shredTrashDirectory() {
        guard let folder else { return }
        let trashDir = ProjectStore.recordingsDir(in: folder).appendingPathComponent(".trash")
        try? FileManager.default.removeItem(at: trashDir)
    }

    private func preparePreviewPlayer(for id: Clip.ID) async throws {
        guard let clip = project.clips.first(where: { $0.id == id }),
              let folder = self.folder else { return }
        let snapshot = project   // copy off the main actor for the nonisolated build
        let item = try await ClipPreviewBuilder.buildPreviewItem(
            for: clip,
            project: snapshot,
            projectFolder: folder
        )
        item.audioMix = audioMix(for: clip)
        let player = AVPlayer(playerItem: item)
        player.volume = 1.0
        _previewCache[id] = player
        _previewFailed.removeValue(forKey: id)
    }

    /// Builds a fresh `AVMutableAudioMix` from the project's current
    /// preview-volume preferences. Note: mutating an existing mix on a
    /// playing item doesn't take effect — the caller must reassign the mix
    /// to `currentItem.audioMix`. See `updatePreviewVolumes(for:)`.
    func audioMix(for clip: Clip) -> AVMutableAudioMix {
        let mix = AVMutableAudioMix()
        let sourceParams = AVMutableAudioMixInputParameters()
        sourceParams.trackID = 2
        sourceParams.setVolume(Float(project.preferences.previewSourceVolume), at: .zero)
        let micParams = AVMutableAudioMixInputParameters()
        micParams.trackID = 2000
        micParams.setVolume(Float(project.preferences.previewCommentaryVolume), at: .zero)
        mix.inputParameters = [sourceParams, micParams]
        return mix
    }

    /// Rebuilds and reassigns the preview player's audio mix from current
    /// preferences. Called by the volume sliders so source/commentary level
    /// changes take effect during playback.
    func updatePreviewVolumes(for id: Clip.ID) {
        guard let clip = project.clips.first(where: { $0.id == id }),
              let player = _previewCache[id] else { return }
        player.currentItem?.audioMix = audioMix(for: clip)
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
