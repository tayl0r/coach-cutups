import Foundation
import VideoCoachCore
import AVFoundation
import Observation
import QuartzCore   // CACurrentMediaTime for setCurrentZoom throttle

enum WorkspaceError: Error {
    case noVideoTrack(URL)
    case bookmarkResolutionFailed(displayName: String)
    /// Refused to remove a source video because one or more clips still
    /// reference it. The UI should disable the unload affordance with a
    /// tooltip explaining; this case is the defensive fallback.
    case sourceHasClipsReferencingIt(count: Int)
    /// New source's aspect ratio doesn't match the project's existing
    /// aspect. v1 is single-aspect-per-project so the player can lock its
    /// viewport to source aspect — recording and playback then render
    /// pixel-identical without a letterbox/cover-fit toggle.
    /// TODO(multi-aspect): support a project that mixes aspects by
    /// rebuilding the player viewport per active source.
    case aspectMismatch(existing: Double, attempted: Double, displayName: String)
}

extension WorkspaceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noVideoTrack(let url):
            return "“\(url.lastPathComponent)” has no video track."
        case .bookmarkResolutionFailed(let name):
            return "Couldn't resolve “\(name)”."
        case .sourceHasClipsReferencingIt(let count):
            return "\(count) clip\(count == 1 ? "" : "s") still reference this source."
        case .aspectMismatch(let existing, let attempted, let name):
            return String(
                format: "“%@” has aspect %.3f but the project's existing source aspect is %.3f. " +
                "Multi-aspect projects aren't supported yet — remove all clips and the existing " +
                "source first to switch the project to a different aspect.",
                name, attempted, existing
            )
        }
    }
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

    /// Display aspect (width / height) of the project's first resolved
    /// source video, rotation-corrected. The player area locks to this so
    /// the mpv view (recording) and AVPlayer view (playback) always render
    /// at source aspect — no letterbox math, no `panscan` cover-fit toggle,
    /// no recording-vs-playback divergence at zoom > 1.
    /// In-memory only; never persisted. Repopulated on every
    /// `rebuildSourcePlayer` and on `relinkSource`. nil while no project is
    /// open, while loading, or when every source is missing.
    /// TODO(multi-aspect): expose per-source aspect once we let projects
    /// mix aspects.
    var sourceAspect: Double?

    /// Live zoom/pan state for the source-playback view. Ephemeral —
    /// not persisted to the project. Reset to identity on workspace switch
    /// (which happens by Workspace re-init in openProject).
    ///
    /// Backed by a private stored property; mutate via `setCurrentZoom(_:)`
    /// (or assign via the computed setter, which delegates). The setter
    /// clamps the input to the valid range, propagates to mpv, and emits a
    /// keyframe to the in-progress recording (if any).
    ///
    /// NOT @ObservationIgnored: SwiftUI views read this through
    /// `workspace.currentZoom` (e.g. ZoomIndicator) and need to re-evaluate
    /// when it changes. Per-gesture body re-evals are cheap with @Observable's
    /// targeted invalidation — only views that actually read the property
    /// re-render.
    private var _currentZoom: Zoom = .identity
    /// Host-clock time (`CACurrentMediaTime()`) of the last commit through
    /// `setCurrentZoom(_:)`. Used to throttle gesture-driven updates to
    /// ~20Hz so the live mpv view and the recorded event log see the
    /// SAME stream of zoom values — without that match, a user who pans
    /// while drawing on a moving subject sees the ball follow the smooth
    /// 60Hz mpv output during recording but stepwise-throttled keyframes
    /// during replay, which puts the recorded drawing offset from the
    /// ball by the unmatched-pan delta. Throttling at this single point
    /// (rather than only on the recording side) keeps live and replay
    /// in lockstep.
    @ObservationIgnored
    private var _lastZoomCommitHostTime: Double = -.infinity

    var currentZoom: Zoom {
        get { _currentZoom }
        set { setCurrentZoom(newValue) }
    }

    /// Throttle interval for `setCurrentZoom` commits — see
    /// `_lastZoomCommitHostTime`. 50ms = 20Hz; AppKit gesture events fire
    /// at ~60Hz so this drops about 2 of every 3 calls on a continuous
    /// gesture. Visually 20Hz is borderline noticeable but the
    /// alternative (no throttle = full 60Hz) doubles the recorded
    /// keyframe count and the alternative (recording-side-only throttle)
    /// puts live and replay out of sync.
    private static let zoomThrottleSeconds: Double = 0.05

    func setCurrentZoom(_ zoom: Zoom) {
        let clamped = zoom.clamped()
        guard clamped != _currentZoom else { return }
        let now = CACurrentMediaTime()
        if now - _lastZoomCommitHostTime < Self.zoomThrottleSeconds { return }
        _lastZoomCommitHostTime = now
        self._currentZoom = clamped
        sourcePlayer?.setZoom(clamped)
        recordingController?.appendZoom(clamped)
    }

    /// Apply a zoom from a discrete one-shot intent (hotkey, menu command,
    /// programmatic reset) — bypasses the gesture throttle. The throttle on
    /// `setCurrentZoom` exists to drop ~⅔ of the 60Hz gesture stream so live
    /// playback and recorded keyframes stay in lockstep at ~20Hz; a single
    /// keypress isn't a stream, and silently dropping it (e.g. user mashes
    /// `1` then `4` inside 50ms) would leave the user stuck on whichever
    /// level happened to land first.
    func setCurrentZoomImmediate(_ zoom: Zoom) {
        let clamped = zoom.clamped()
        guard clamped != _currentZoom else { return }
        _lastZoomCommitHostTime = CACurrentMediaTime()
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
    private var _previewCache: [Clip.ID: PreviewCacheEntry] = [:]
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
        history.clearAll()
        shredTrashDirectory()
        try await rebuildSourcePlayer()
        UserDefaults.standard.set(folder.path(percentEncoded: false), forKey: "VideoCoach.lastProjectFolder")
    }

    func saveProject() throws {
        guard let folder else { return }
        try ProjectStore.write(project, to: folder)
    }

    func addSourceVideo(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        async let durationLoad = asset.load(.duration)
        let newAspect = try await Self.displayAspect(of: asset)
        if let existing = sourceAspect, !Self.aspectsMatch(existing, newAspect) {
            throw WorkspaceError.aspectMismatch(
                existing: existing,
                attempted: newAspect,
                displayName: url.lastPathComponent
            )
        }
        let duration = try await durationLoad
        let bookmark = try url.bookmarkData(options: [])  // plain — we're unsandboxed
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
            sourceAspect = nil
            return
        }

        if sourcePlayer == nil {
            sourcePlayer = MPVSourcePlayer()
        }
        sourcePlayer?.setPlaylist(resolved.map { $0.url.path(percentEncoded: false) })
        sourcePlayer?.setVolume(project.preferences.scanVolume)

        // Resolve aspect from the first source's video track. Async, but the
        // SwiftUI player ZStack stays gated behind `playerEmptyStateOverlay`
        // until this lands so the user never sees a non-source-aspect frame.
        // Off-main: doesn't block rebuildSourcePlayer's caller.
        if let first = resolved.first {
            let url = first.url
            Task { [weak self] in
                let aspect = try? await Self.displayAspect(of: AVURLAsset(url: url))
                await MainActor.run {
                    guard let self else { return }
                    self.sourceAspect = aspect
                }
            }
        }
    }

    /// Display aspect (width / height) of `asset`'s first video track,
    /// corrected for any `preferredTransform` rotation. Throws if the asset
    /// has no video track. Used as the gate value for new-source aspect
    /// matching and as the lock value for the player viewport.
    static func displayAspect(of asset: AVAsset) async throws -> Double {
        let track = try await asset.primaryVideoTrack()
        async let naturalSize = track.load(.naturalSize)
        async let transform = track.load(.preferredTransform)
        let size = try await naturalSize
        let t = try await transform
        let displayed = size.applying(t)
        let w = abs(displayed.width)
        let h = abs(displayed.height)
        guard h > 0 else { return 0 }
        return w / h
    }

    /// Aspects compare equal if they're within 0.5%. `naturalSize` from
    /// AVFoundation is exact for most professional sources (1920/1080,
    /// 3840/2160) but phone-recorded clips occasionally land off-by-a-pixel
    /// (e.g. 1920/1078) which is the same intended aspect. 0.5% covers that
    /// without admitting genuinely different aspects.
    static func aspectsMatch(_ a: Double, _ b: Double) -> Bool {
        guard a > 0, b > 0 else { return false }
        return abs(a - b) / max(a, b) < 0.005
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
        let asset = AVURLAsset(url: url)
        async let durationLoad = asset.load(.duration)
        let newAspect = try await Self.displayAspect(of: asset)
        // If any *other* source is currently resolved, its aspect is the
        // project-level lock — the relinked file must match. (When the
        // project has only this one source, we let the relink set the new
        // aspect freely; it's the same as a fresh add.)
        if let existing = sourceAspect, !Self.aspectsMatch(existing, newAspect) {
            throw WorkspaceError.aspectMismatch(
                existing: existing,
                attempted: newAspect,
                displayName: url.lastPathComponent
            )
        }
        let duration = try await durationLoad
        let bookmark = try url.bookmarkData(options: [])
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
        if let cached = _previewCache[id] { return cached.player }
        if _previewFailed[id] != nil { return nil }
        guard !_previewInflight.contains(id) else { return nil }
        _previewInflight.insert(id)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.preparePreviewPlayer(for: id)
            } catch {
                NSLog("[Preview] build failed for clip \(id): \(error)")
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

    /// Swap the cached preview's PiP visibility without rebuilding the
    /// composition or re-loading assets. If no cache entry exists yet
    /// (preview never opened, or already invalidated), this is a no-op —
    /// the next preview build will pick up the current `clip.showPiP`.
    func setShowPiP(_ showPiP: Bool, for id: Clip.ID) {
        guard let entry = _previewCache[id] else { return }
        entry.player.currentItem?.videoComposition =
            ClipPreviewBuilder.makeVideoComposition(entry: entry, showPiP: showPiP)
    }

    /// Per-project undo/redo machinery. Pure-data; lives in
    /// `VideoCoachCore` so the package's existing test target can cover
    /// the stack semantics without dragging in MPVKit. Application of
    /// each `UndoAction` (mutating `project.clips`, invalidating the
    /// preview cache, moving recording files in / out of `.trash`) is
    /// owned by this class — the controller is a passive bookkeeper.
    private var history = UndoController()

    /// Forwarded from the controller so callers (the `undo` / `redo`
    /// menu handlers, in particular) don't need to know the controller
    /// exists.
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    /// Removes a clip from the project: drops the in-memory entry, MOVES
    /// the underlying recording into `recordings/.trash/`, invalidates the
    /// preview cache, and persists. Pushes a `.deleteClip` action onto
    /// the undo stack via `history.pushDelete(_:)`, which evicts any
    /// prior `.deleteClip` from either stack (returning the evicted
    /// `DeletedClip` so we can shred its trash file). The clip's
    /// `sortIndex` gap is left as-is — `reorderClips(from:to:)` re-numbers
    /// on next reorder, and the sidebar sorts by `sortIndex`-ascending
    /// so a gap is invisible.
    func deleteClip(id: Clip.ID) throws {
        guard let idx = project.clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = project.clips[idx]
        invalidatePreviewCache(for: id)

        guard let folder else {
            // No folder open ⇒ no trash dir ⇒ no recoverable delete.
            // Drop the clip metadata and bail. (In practice the menu
            // gates on having a project, so this is defensive.)
            project.clips.remove(at: idx)
            try saveProject()
            return
        }

        let recordingsDir = ProjectStore.recordingsDir(in: folder)
        let recordingURL = recordingsDir.appendingPathComponent(clip.recordingFilename)
        let trashDir = recordingsDir.appendingPathComponent(".trash")
        try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let trashedURL = trashDir.appendingPathComponent(clip.recordingFilename)
        if FileManager.default.fileExists(atPath: recordingURL.path) {
            try? FileManager.default.removeItem(at: trashedURL)
            try FileManager.default.moveItem(at: recordingURL, to: trashedURL)
        }
        let stash = DeletedClip(clip: clip, trashedRecordingURL: trashedURL)

        project.clips.remove(at: idx)
        try saveProject()

        // Push onto the controller; if it returns an evicted prior
        // delete, shred that trash file (the controller doesn't do IO).
        if let evicted = history.pushDelete(stash) {
            try? FileManager.default.removeItem(at: evicted.trashedRecordingURL)
        }
    }

    /// Inspector calls this on every field's focus-loss when the
    /// snapshot taken at focus-gain differs from the current clip. Skip
    /// when before == after so an unchanged focus session doesn't pollute
    /// the stack. Any redo branch is dropped.
    func commitClipEdit(id: Clip.ID, before: Clip, after: Clip) {
        guard before != after else { return }
        history.pushEdit(.editClip(id: id, before: before, after: after))
    }

    /// Snapshot-then-mutate-then-push-undo wrapper for all match-event edits.
    /// Skips the undo push when the mutation didn't actually change anything
    /// so no-op tag toggles don't pollute the stack. Persist is deferred to
    /// the undo/redo arms (and is implicit on next `saveProject` from another
    /// path) — keeping this aligned with the other `pushEdit` callers in this
    /// file which let their existing `try? saveProject()` paths cover persist.
    func mutateMatchEvents(_ mutate: (inout Project) -> Void) {
        let before = project.matchEvents
        mutate(&project)
        let after = project.matchEvents
        guard before != after else { return }
        history.pushEdit(.editMatchEvents(before: before, after: after))
        try? saveProject()
    }

    @MainActor
    func tagEvent(_ kind: MatchEventKind) {
        guard let player = sourcePlayer else { return }
        let idx = player.playlistPos
        let sec = player.timePos
        mutateMatchEvents { p in
            switch kind {
            case .homeGoal:  p.appendHomeGoal(sourceIndex: idx, sourceSeconds: sec)
            case .awayGoal:  p.appendAwayGoal(sourceIndex: idx, sourceSeconds: sec)
            case .startStop: p.appendStartStop(sourceIndex: idx, sourceSeconds: sec)
            }
        }
    }

    /// Pop one action from the undo stack and apply its inverse. Quietly
    /// no-ops when the stack is empty so menu wiring doesn't have to
    /// gate the call. Returns the action that was applied so the caller
    /// (ContentView) can adjust selection — it doesn't see the
    /// controller directly. Save errors during the inverse are
    /// swallowed (project file may be on a read-only volume mid-flight);
    /// the in-memory state is what the user sees and is what counts for
    /// undo correctness.
    @discardableResult
    func undo() -> UndoAction? {
        guard let action = history.popForUndo() else { return nil }
        applyInverse(of: action)
        return action
    }

    /// Symmetric to `undo()`. Pops one action from the redo stack and
    /// applies it forward. Returns the applied action.
    @discardableResult
    func redo() -> UndoAction? {
        guard let action = history.popForRedo() else { return nil }
        applyForward(of: action)
        return action
    }

    private func applyInverse(of action: UndoAction) {
        switch action {
        case let .editClip(id, before, _):
            if let i = project.clips.firstIndex(where: { $0.id == id }) {
                project.clips[i] = before
                // `showPiP` is the only inspector-editable field that needs an
                // imperative side-effect: AVFoundation doesn't observe @Observable,
                // so the video composition must be swapped explicitly. `name` and
                // `tags` appear in the SwiftUI preview overlay and export text bar
                // but re-render automatically when `project` is written. (`events`
                // also affects composition but has no inspector UI yet.)
                setShowPiP(before.showPiP, for: id)
                try? saveProject()
            }
        case let .reorderClips(beforeOrder, _):
            applyClipOrder(beforeOrder)
            try? saveProject()
        case let .deleteClip(stash):
            // Move .mov out of trash and re-insert the clip at its
            // original sortIndex slot. Tolerate a missing trash file
            // (someone may have cleaned it externally) — metadata still
            // restores. Re-selection of the restored clip is done by
            // the menu handler in ContentView, not here.
            if let folder, FileManager.default.fileExists(atPath: stash.trashedRecordingURL.path) {
                let recordingsDir = ProjectStore.recordingsDir(in: folder)
                let target = recordingsDir.appendingPathComponent(stash.clip.recordingFilename)
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.moveItem(at: stash.trashedRecordingURL, to: target)
            }
            let insertAt = project.clips.firstIndex(where: { $0.sortIndex > stash.clip.sortIndex })
                ?? project.clips.endIndex
            project.clips.insert(stash.clip, at: insertAt)
            try? saveProject()
        case let .editMatchEvents(before, _):
            project.matchEvents = before
            try? saveProject()
        }
    }

    private func applyForward(of action: UndoAction) {
        switch action {
        case let .editClip(id, _, after):
            if let i = project.clips.firstIndex(where: { $0.id == id }) {
                project.clips[i] = after
                // `showPiP` is the only inspector-editable field that needs an
                // imperative side-effect: AVFoundation doesn't observe @Observable,
                // so the video composition must be swapped explicitly. `name` and
                // `tags` appear in the SwiftUI preview overlay and export text bar
                // but re-render automatically when `project` is written. (`events`
                // also affects composition but has no inspector UI yet.)
                setShowPiP(after.showPiP, for: id)
                try? saveProject()
            }
        case let .reorderClips(_, afterOrder):
            applyClipOrder(afterOrder)
            try? saveProject()
        case let .deleteClip(stash):
            // Re-apply the delete: remove from project, move .mov back
            // into trash. The action's `trashedRecordingURL` points at
            // the same path we'll re-occupy.
            if let i = project.clips.firstIndex(where: { $0.id == stash.clip.id }) {
                invalidatePreviewCache(for: stash.clip.id)
                project.clips.remove(at: i)
            }
            if let folder {
                let recordingsDir = ProjectStore.recordingsDir(in: folder)
                let recordingURL = recordingsDir.appendingPathComponent(stash.clip.recordingFilename)
                let trashDir = recordingsDir.appendingPathComponent(".trash")
                try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: recordingURL.path) {
                    try? FileManager.default.removeItem(at: stash.trashedRecordingURL)
                    try? FileManager.default.moveItem(at: recordingURL, to: stash.trashedRecordingURL)
                }
            }
            try? saveProject()
        case let .editMatchEvents(_, after):
            project.matchEvents = after
            try? saveProject()
        }
    }

    /// Wipes the project's trash directory. Called on every `openProject` so
    /// undo state never survives across launches (per design — the in-memory
    /// `history` controller is also cleared in `openProject`).
    private func shredTrashDirectory() {
        guard let folder else { return }
        let trashDir = ProjectStore.recordingsDir(in: folder).appendingPathComponent(".trash")
        try? FileManager.default.removeItem(at: trashDir)
    }

    private func preparePreviewPlayer(for id: Clip.ID) async throws {
        guard let clip = project.clips.first(where: { $0.id == id }),
              let folder = self.folder else { return }
        let snapshot = project   // copy off the main actor for the nonisolated build
        let entry = try await ClipPreviewBuilder.buildPreviewEntry(
            for: clip,
            project: snapshot,
            projectFolder: folder
        )
        entry.player.currentItem?.audioMix = audioMix()
        entry.player.volume = 1.0
        _previewCache[id] = entry
        // If `showPiP` was toggled while Phase A was in flight, the cached
        // entry was built with the stale snapshot value. Re-read the live
        // value and re-run Phase B in place if it differs.
        if let currentClip = project.clips.first(where: { $0.id == id }),
           currentClip.showPiP != clip.showPiP {
            setShowPiP(currentClip.showPiP, for: id)
        }
        _previewFailed.removeValue(forKey: id)
    }

    /// Builds a fresh `AVMutableAudioMix` from the project's current
    /// preview-volume preferences. Note: mutating an existing mix on a
    /// playing item doesn't take effect — the caller must reassign the mix
    /// to `currentItem.audioMix`. See `updatePreviewVolumes(for:)`.
    func audioMix() -> AVMutableAudioMix {
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
        guard let entry = _previewCache[id] else { return }
        entry.player.currentItem?.audioMix = audioMix()
    }

    // MARK: - Clip ordering

    /// Drag-to-reorder support for the sidebar list. Resorts by current
    /// `sortIndex`, applies the SwiftUI move, then rewrites `sortIndex`
    /// to match the new ordering and persists. Undoable.
    func reorderClips(from offsets: IndexSet, to destination: Int) {
        let beforeOrder = project.clips.sorted(by: { $0.sortIndex < $1.sortIndex }).map(\.id)
        var clips = project.clips.sorted(by: { $0.sortIndex < $1.sortIndex })
        clips.move(fromOffsets: offsets, toOffset: destination)
        let afterOrder = clips.map(\.id)
        guard afterOrder != beforeOrder else { return }
        for i in clips.indices { clips[i].sortIndex = i }
        project.clips = clips
        history.pushEdit(.reorderClips(beforeOrder: beforeOrder, afterOrder: afterOrder))
        try? saveProject()
    }

    /// Rewrite every clip's `sortIndex` so the sidebar (and therefore
    /// the export) follows the order the clips appear inside the source
    /// videos: by `sourceIndex` first, then by `startSourceSeconds`. One-
    /// shot — the user clicks the button, this runs, normal drag-to-
    /// reorder still works afterward. Undoable.
    func sortClipsBySourcePosition() {
        let beforeOrder = project.clips.sorted(by: { $0.sortIndex < $1.sortIndex }).map(\.id)
        var clips = project.clips
        clips.sort {
            if $0.sourceIndex != $1.sourceIndex {
                return $0.sourceIndex < $1.sourceIndex
            }
            return $0.startSourceSeconds < $1.startSourceSeconds
        }
        let afterOrder = clips.map(\.id)
        guard afterOrder != beforeOrder else { return }
        for i in clips.indices { clips[i].sortIndex = i }
        project.clips = clips
        history.pushEdit(.reorderClips(beforeOrder: beforeOrder, afterOrder: afterOrder))
        try? saveProject()
    }

    /// Apply an ID-ordering to `project.clips`: clips appear in the
    /// listed order first, with their `sortIndex` reassigned positionally;
    /// any clips whose id isn't in the order get appended at the end
    /// preserving their current relative order (so add/delete between
    /// reorder-push and reorder-pop doesn't corrupt or wipe them).
    private func applyClipOrder(_ order: [Clip.ID]) {
        let byID = Dictionary(uniqueKeysWithValues: project.clips.map { ($0.id, $0) })
        var ordered: [Clip] = []
        ordered.reserveCapacity(project.clips.count)
        for id in order {
            if let c = byID[id] { ordered.append(c) }
        }
        let listed = Set(order)
        // Append any clips not in the snapshot, in their current order.
        let leftovers = project.clips
            .sorted(by: { $0.sortIndex < $1.sortIndex })
            .filter { !listed.contains($0.id) }
        ordered.append(contentsOf: leftovers)
        for i in ordered.indices { ordered[i].sortIndex = i }
        project.clips = ordered
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
