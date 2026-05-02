import Foundation
import VideoCoachCore
import AVFoundation
import Observation

enum WorkspaceError: Error {
    case noVideoTrack(URL)
    case bookmarkResolutionFailed(displayName: String)
    /// Refused to remove a source video because one or more clips still
    /// reference it. The UI should disable the unload affordance with a
    /// tooltip explaining; this case is the defensive fallback.
    case sourceHasClipsReferencingIt(count: Int)
}

@Observable
@MainActor
final class Workspace {
    var folder: URL?
    var project: Project = Project(name: "Untitled")
    /// Source-playback engine. Persistent (D2). Lazy-created on first
    /// rebuildSourcePlayer that has resolved sources. Stays alive across
    /// missing-source / Relink cycles so a successful relink does not pay
    /// init cost again.
    var sourcePlayer: MPVSourcePlayer?
    /// Indices into `project.sourceVideos` whose bookmark failed to resolve
    /// (file moved/renamed/deleted). Recomputed every `rebuildSourcePlayer`.
    /// When non-empty, `sourcePlayer`'s playlist is intentionally cleared so
    /// the UI can surface a Relink banner — playback would be confusing if
    /// we played only the surviving sources, since clip `sourceIndex`es
    /// would no longer line up with the concat.
    var missingSourceIndices: Set<Int> = []

    /// Live zoom/pan state for the source-playback view. Ephemeral —
    /// not persisted to the project. Reset to identity on workspace switch
    /// (which happens by Workspace re-init in openProject).
    ///
    /// Backed by a private stored property; mutate via `setCurrentZoom(_:)`
    /// (or assign via the computed setter, which delegates). The setter
    /// clamps the input to the valid range, propagates to mpv, and emits a
    /// keyframe to the in-progress recording (if any).
    @ObservationIgnored
    private var _currentZoom: Zoom = .identity

    var currentZoom: Zoom {
        get { _currentZoom }
        set { setCurrentZoom(newValue) }
    }

    func setCurrentZoom(_ zoom: Zoom) {
        let clamped = zoom.clamped()
        guard clamped != _currentZoom else { return }
        self._currentZoom = clamped
        sourcePlayer?.setZoom(clamped)
        recordingController?.appendZoom(clamped)
    }

    /// Set by ContentView when recording starts; cleared when recording
    /// stops. Weak so the controller isn't kept alive past its natural end.
    /// Used by `setCurrentZoom(_:)` to emit zoom keyframes into the
    /// in-progress recording (wired in Phase 4.2).
    @ObservationIgnored
    weak var recordingController: RecordingController?

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
        try await rebuildSourcePlayer()
        UserDefaults.standard.set(folder.path(percentEncoded: false), forKey: "VideoCoach.lastProjectFolder")
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
        try await rebuildSourcePlayer()
    }

    func rebuildSourcePlayer() async throws {
        // First pass — try to resolve every bookmark. Tolerant of failures so
        // a moved file produces a Relink banner instead of a thrown error
        // that the user can't recover from.
        var resolved: [(index: Int, url: URL)] = []
        var missing: Set<Int> = []
        var anyBookmarkRefreshed = false
        for index in project.sourceVideos.indices {
            do {
                let (url, refreshed) = try resolveAndMaybeRefresh(at: index)
                if refreshed { anyBookmarkRefreshed = true }
                resolved.append((index, url))
            } catch {
                missing.insert(index)
            }
        }
        // Persist refreshed bookmarks AFTER the resolve loop. Saving inside the
        // loop while an inout write to project.sourceVideos[index] is in flight
        // produces a Swift exclusivity violation (saveProject reads `project`
        // for ProjectStore.write).
        if anyBookmarkRefreshed { try? saveProject() }
        self.missingSourceIndices = missing

        // No sources at all, or any source missing — clear the playlist. We
        // refuse to play a partial concat because clip `sourceIndex`es
        // wouldn't line up with the surviving sources' positions. We KEEP
        // the player handle alive (D2) so a Relink doesn't repay init cost.
        guard !project.sourceVideos.isEmpty, missing.isEmpty else {
            sourcePlayer?.setPlaylist([])
            return
        }

        if sourcePlayer == nil {
            sourcePlayer = MPVSourcePlayer()
        }
        sourcePlayer?.setPlaylist(resolved.map { $0.url.path(percentEncoded: false) })
        sourcePlayer?.setVolume(project.preferences.scanVolume)
    }

    /// Number of clips whose `sourceIndex` points at the given source. The
    /// sidebar's source-list X button reads this to decide whether to gate
    /// removal — we refuse to drop a source that clips still depend on
    /// because the alternative (silently retargeting their indices) would
    /// produce subtly wrong playback.
    func clipsReferencing(sourceIndex: Int) -> Int {
        project.clips.filter { $0.sourceIndex == sourceIndex }.count
    }

    /// Removes a source video and rebuilds the virtual concat. Refuses
    /// (throws) when any clip references this source — the UI gates on
    /// `clipsReferencing(sourceIndex:)` so this throw is the defensive
    /// fallback. Clips with `sourceIndex > index` get their index shifted
    /// down by 1 so they keep pointing at the same physical files.
    func removeSourceVideo(at index: Int) async throws {
        guard project.sourceVideos.indices.contains(index) else { return }
        let refCount = clipsReferencing(sourceIndex: index)
        guard refCount == 0 else {
            throw WorkspaceError.sourceHasClipsReferencingIt(count: refCount)
        }
        project.sourceVideos.remove(at: index)
        for i in project.clips.indices where project.clips[i].sourceIndex > index {
            project.clips[i].sourceIndex -= 1
        }
        try saveProject()
        try await rebuildSourcePlayer()
    }

    /// Drag-to-reorder support for the sources list. Builds an
    /// `oldIndex → newIndex` permutation from bookmark identity, applies
    /// the move to `sourceVideos`, then remaps every clip's `sourceIndex`
    /// through the permutation so clips keep pointing at the same physical
    /// files (just with a new ordinal in the concat).
    func reorderSourceVideos(from offsets: IndexSet, to destination: Int) async throws {
        let oldOrder = project.sourceVideos
        var newOrder = oldOrder
        newOrder.move(fromOffsets: offsets, toOffset: destination)
        var indexMap: [Int: Int] = [:]
        for (newI, src) in newOrder.enumerated() {
            if let oldI = oldOrder.firstIndex(where: { $0.bookmark == src.bookmark }) {
                indexMap[oldI] = newI
            }
        }
        project.sourceVideos = newOrder
        for i in project.clips.indices {
            if let mapped = indexMap[project.clips[i].sourceIndex] {
                project.clips[i].sourceIndex = mapped
            }
        }
        try saveProject()
        try await rebuildSourcePlayer()
    }

    /// Replaces the bookmark + display name + duration for a specific source
    /// with a freshly-picked file, then rebuilds the virtual concat. Used by
    /// the Relink banner that appears when a source's bookmark fails to
    /// resolve. Caller is responsible for showing an `NSOpenPanel` and
    /// passing the user-picked URL.
    func relinkSource(at index: Int, to url: URL) async throws {
        guard project.sourceVideos.indices.contains(index) else { return }
        let bookmark = try url.bookmarkData(options: [])
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        project.sourceVideos[index] = .init(
            bookmark: bookmark,
            displayName: url.lastPathComponent,
            durationSeconds: duration.seconds
        )
        try saveProject()
        try await rebuildSourcePlayer()
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

    /// Resolves the bookmark at `project.sourceVideos[index]` and refreshes it
    /// if stale. Returns the URL plus whether the bookmark was refreshed.
    /// Caller is responsible for calling `saveProject()` after the resolve
    /// loop completes — calling it from here would nest an inout write on
    /// `project.sourceVideos[index]` with a read on `project` and trip Swift's
    /// exclusivity check.
    private func resolveAndMaybeRefresh(at index: Int) throws -> (URL, refreshed: Bool) {
        let ref = project.sourceVideos[index]
        let (url, isStale) = try resolveBookmark(ref.bookmark, displayName: ref.displayName)
        guard isStale, let newBookmark = try? url.bookmarkData(options: []) else {
            return (url, false)
        }
        project.sourceVideos[index].bookmark = newBookmark
        return (url, true)
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

    /// Maps a cumulative source time (sum of prior source durations + the
    /// current local offset) back to the source video that contains it and
    /// the local offset within that source. Walks the cumulative source
    /// durations in order — the same order `rebuildSourcePlayer` uses to
    /// build the playlist. Returns `(0, 0)` if there are no sources.
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
