import AVFoundation
import AppKit
import SwiftUI
import VideoCoachCore

/// SwiftUI sheet that drives one ``CompilationExporter`` run per checked tag.
///
/// Phase 9.5 of the plan. Reads ``TagAggregation.aggregate(project:)`` for
/// rows, prepends a synthetic `all-clips` row, and lets the user pick output
/// folder, resolution, and quality before kicking off sequential exports.
///
/// **Sequential execution.** The design says tags export one at a time —
/// VideoToolbox saturates on a single export and parallelism would just add
/// queue contention without speeding anything up.
///
/// **Live progress.** ``CompilationExporter.export(...)`` accepts an
/// `onProgress: (Float) -> Void` closure that fires at ~5Hz from a detached
/// task during each export. `ExportSheet` threads each tick through
/// ``handleSampleFromActiveVideo(_:)`` to update the active item's
/// fraction, feed the run-level ``RollingRate``, and re-project the run.
struct ExportSheet: View {
    @Bindable var workspace: Workspace
    /// Set by ContentView; we toggle it to dismiss.
    @Binding var isPresented: Bool

    // MARK: - Form state

    @State private var projectName: String = ""
    @State private var outputFolder: URL?
    /// Tag rows the user has checked, identified by tag string. The synthetic
    /// "all-clips" row uses the sentinel ``Self.allClipsKey``.
    @State private var selectedTags: Set<String> = []
    @State private var resolution: Resolution = .r1080
    @State private var quality: Quality = .medium

    // MARK: - Run state

    /// `nil` when the form is editable; non-nil during/after an export run.
    @State private var run: RunState?
    @State private var errorMessage: String?
    /// Once the run completes successfully, the sheet swaps to a brief summary
    /// with a "Reveal in Finder" button and a "Done" button.
    @State private var summary: Summary?

    // New per-run state for the per-video progress UI.
    @State private var items: [VideoExportItem] = []
    @State private var runRate = RollingRate(windowSeconds: 30)
    @State private var runStartedAt: Date? = nil
    @State private var currentVideoStartedAt: Date? = nil
    @State private var projection: RunProjection = .empty
    @State private var lastSnapshot: ExportProgress? = nil

    /// Frame rate of the export's video composition. Read once per run from
    /// the exporter's internal `videoComp.frameDuration` (currently 1/30).
    /// Hard-coded here because the exporter doesn't expose it, and the value
    /// is stable across today's code. If the exporter ever varies frame rate
    /// per export, surface it via the `onProgress` closure or a separate
    /// callback.
    private static let outputFrameRate: Double = 30

    /// Sentinel key for the "all-clips" row. Tag strings are lowercased on
    /// ingest (see `Tag.normalize`) and can't contain spaces, so this never
    /// collides with a real tag.
    private static let allClipsKey = "__all-clips__"

    private struct RunState: Equatable {
        var totalCount: Int
        var completedCount: Int
        var currentTag: String?
    }

    private struct Summary: Equatable {
        var folder: URL
        var fileCount: Int
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let summary {
                        summarySection(summary)
                    } else if run != nil {
                        progressSection
                    } else {
                        formSection
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 580, minHeight: 540, idealHeight: 640)
        .onAppear {
            // Initialize fields that depend on the project. Runs once per
            // sheet presentation — re-presenting after dismissal will reset.
            if projectName.isEmpty { projectName = workspace.project.name }
            if outputFolder == nil, let folder = workspace.folder {
                outputFolder = folder.appendingPathComponent("exports")
            }
            resolution = workspace.project.preferences.lastExportResolution
            quality = workspace.project.preferences.lastExportQuality
            // Default to "select all" — the all-clips synthetic row plus
            // every real tag in the project. Per-row checkboxes still let
            // the user narrow it down. Only seed once: if the user already
            // unchecked things in this sheet presentation we don't want to
            // re-tick them on re-render.
            if selectedTags.isEmpty {
                selectedTags = Set([Self.allClipsKey] + workspace.project.clips.flatMap(\.tags))
            }
        }
        .alert(
            "Export Failed",
            isPresented: .constant(errorMessage != nil),
            presenting: errorMessage
        ) { _ in
            Button("OK") { errorMessage = nil }
        } message: { Text($0) }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text(summary != nil ? "Export Complete" : "Export Compilations")
                .font(.title3.weight(.semibold))
            Spacer()
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            // Don't allow closing while a run is in flight — the export Task
            // would keep going, but the user would lose visibility into it.
            .disabled(run != nil && summary == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Project name — used as the export filename suffix. Independent
            // of `workspace.project.name`; we don't mutate the project here.
            VStack(alignment: .leading, spacing: 4) {
                Text("Project name").font(.subheadline).foregroundStyle(.secondary)
                TextField("Project name", text: $projectName)
                    .textFieldStyle(.roundedBorder)
            }

            // Output folder — defaults to <project>/exports.
            VStack(alignment: .leading, spacing: 4) {
                Text("Output folder").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(outputFolder?.path ?? "(none)")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(outputFolder == nil ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") { pickOutputFolder() }
                }
            }

            // Tag list with the synthetic all-clips row at top.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Tags").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("Select All") { selectAll() }
                        .buttonStyle(.borderless)
                    Button("Select None") { selectNone() }
                        .buttonStyle(.borderless)
                }
                tagListBox
            }

            // Resolution + Quality side-by-side.
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Resolution").font(.subheadline).foregroundStyle(.secondary)
                    Picker("Resolution", selection: $resolution) {
                        ForEach(Resolution.allCases, id: \.self) { res in
                            Text(displayName(for: res)).tag(res)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quality").font(.subheadline).foregroundStyle(.secondary)
                    Picker("Quality", selection: $quality) {
                        ForEach(Quality.allCases, id: \.self) { q in
                            Text(displayName(for: q)).tag(q)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                Spacer()
            }
        }
    }

    private var tagListBox: some View {
        let tagSummaries = TagAggregation.aggregate(project: workspace.project)
        let allClipsCount = workspace.project.clips.count
        let allClipsDuration = workspace.project.clips.reduce(0.0) { $0 + $1.recordingDuration }

        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                tagRow(
                    key: Self.allClipsKey,
                    label: "all-clips",
                    clipCount: allClipsCount,
                    durationSeconds: allClipsDuration
                )
                if !tagSummaries.isEmpty {
                    Divider().padding(.vertical, 2)
                }
                ForEach(tagSummaries, id: \.tag) { summary in
                    tagRow(
                        key: summary.tag,
                        label: summary.tag,
                        clipCount: summary.clipCount,
                        durationSeconds: summary.totalDurationSeconds
                    )
                }
            }
            .padding(8)
        }
        .frame(minHeight: 160, maxHeight: 220)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }

    private func tagRow(
        key: String,
        label: String,
        clipCount: Int,
        durationSeconds: Double
    ) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { selectedTags.contains(key) },
                set: { isOn in
                    if isOn { selectedTags.insert(key) } else { selectedTags.remove(key) }
                }
            )) {
                HStack(spacing: 4) {
                    Text(label)
                    Text("— \(clipCount) clip\(clipCount == 1 ? "" : "s"), \(formatDuration(durationSeconds))")
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            runSummary
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    videoRow(item)
                }
            }
        }
    }

    @ViewBuilder
    private var runSummary: some View {
        let doneCount = items.reduce(0) { acc, item in
            if case .done = item.status { return acc + 1 }
            return acc
        }
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Exporting (\(doneCount) of \(items.count) videos done)")
                    .font(.headline)
                Spacer()
                if let fps = lastSnapshot?.currentRenderingFps {
                    Text("\(Int(fps.rounded())) fps")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(runSummaryLine)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// The "1:08 video left · ETA 1:25 (3:42 PM)" line under the headline.
    /// Falls back gracefully when the rate hasn't stabilized yet — just the
    /// total video remaining, no ETA, no clock.
    private var runSummaryLine: String {
        let totalLeft = lastSnapshot?.totalVideoSecondsRemaining ?? items.reduce(0.0) { acc, item in
            switch item.status {
            case .done: return acc
            case .active, .pending: return acc + item.videoDurationSeconds
            }
        }
        var parts: [String] = ["\(formatDuration(totalLeft)) video left"]
        if let etaSecs = lastSnapshot?.totalEtaSeconds,
           let doneDate = lastSnapshot?.projectedCompletionDate {
            parts.append("ETA \(formatDuration(etaSecs)) (\(Self.clockFormatter.string(from: doneDate)))")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func videoRow(_ item: VideoExportItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            // Status pill — small, fixed-width label so rows align.
            Text(statusPill(item.status))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(item.displayName)
                .font(.callout.weight(.medium))
                .frame(width: 160, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            VStack(alignment: .leading, spacing: 2) {
                switch item.status {
                case .pending:
                    pendingDetail(item)
                case .active(let frac):
                    ProgressView(value: Double(frac))
                        .progressViewStyle(.linear)
                    activeDetail(item, fraction: frac)
                case .done(let wall, let avgFps):
                    doneDetail(item, encodeWall: wall, avgFps: avgFps)
                }
            }
        }
    }

    private func statusPill(_ status: VideoExportItem.Status) -> String {
        switch status {
        case .pending: return "Pending"
        case .active:  return "Active"
        case .done:    return "Done"
        }
    }

    @ViewBuilder
    private func pendingDetail(_ item: VideoExportItem) -> some View {
        // `perItemRemaining[id]` is this video's encode time alone (per-item,
        // not cumulative — see Task 3 spec). Use it directly.
        let encodeOnly = projection.perItemRemaining[item.id] ?? item.videoDurationSeconds
        let doneDateString: String = {
            guard let date = projection.perItemDoneDate[item.id],
                  lastSnapshot?.currentRenderingFps != nil else { return "" }
            return " · done \(Self.clockFormatter.string(from: date))"
        }()
        Text("\(formatDuration(item.videoDurationSeconds)) video · ~\(formatDuration(encodeOnly)) to encode\(doneDateString)")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func activeDetail(_ item: VideoExportItem, fraction: Float) -> some View {
        let videoLeft = max(0, (1.0 - Double(fraction)) * item.videoDurationSeconds)
        let wallLeft = projection.perItemRemaining[item.id] ?? 0
        let fpsText: String = lastSnapshot.flatMap { snap in
            snap.currentRenderingFps.map { "\(Int($0.rounded())) fps · " }
        } ?? ""
        let etaText: String = {
            guard let date = projection.perItemDoneDate[item.id],
                  lastSnapshot?.currentRenderingFps != nil else { return "" }
            return " · ETA \(formatDuration(wallLeft)) (\(Self.clockFormatter.string(from: date)))"
        }()
        Text("\(fpsText)\(formatDuration(videoLeft)) video left\(etaText)")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func doneDetail(_ item: VideoExportItem, encodeWall: Double, avgFps: Double) -> some View {
        Text("✓ \(formatDuration(item.videoDurationSeconds)) video · \(formatDuration(encodeWall)) encode · avg \(Int(avgFps.rounded())) fps")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    /// Short, locale-sensitive clock-time formatter (e.g., "3:42 PM" in
    /// en_US, "15:42" in fr_FR). One per type — recreating a DateFormatter
    /// per row would be wasteful.
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private func summarySection(_ summary: Summary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wrote \(summary.fileCount) file\(summary.fileCount == 1 ? "" : "s") to:")
                .font(.headline)
            Text(summary.folder.path)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([summary.folder])
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            if summary != nil {
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            } else if run != nil {
                // No cancel for now — the exporter doesn't expose a cancel
                // hook. The Done/X is also disabled while running. The user
                // can quit the app to abort.
                ProgressView().controlSize(.small)
            } else {
                Button("Export") { startExport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canExport)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Derived state

    private var canExport: Bool {
        outputFolder != nil && !selectedTags.isEmpty
    }

    private func displayName(for resolution: Resolution) -> String {
        switch resolution {
        case .source: return "Source"
        case .r1080:  return "1080p"
        case .r720:   return "720p"
        }
    }

    private func displayName(for quality: Quality) -> String {
        switch quality {
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        }
    }

    /// User-facing label for a tag key (translates the all-clips sentinel).
    private func displayLabel(forKey key: String) -> String {
        key == Self.allClipsKey ? "all-clips" : key
    }

    // MARK: - Actions

    private func selectAll() {
        var next: Set<String> = [Self.allClipsKey]
        for summary in TagAggregation.aggregate(project: workspace.project) {
            next.insert(summary.tag)
        }
        selectedTags = next
    }

    private func selectNone() {
        selectedTags.removeAll()
    }

    private func pickOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if let outputFolder { panel.directoryURL = outputFolder.deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url
        }
    }

    private func startExport() {
        guard canExport, let outputFolder else { return }

        // Snapshot the user's choices so the Task doesn't observe state
        // changes mid-run.
        let chosenTags: [String] = orderedSelectedTags()
        let outFolder = outputFolder
        let resolutionChoice = resolution
        let qualityChoice = quality
        let projectNameChoice = projectName.isEmpty ? workspace.project.name : projectName

        // Persist the resolution+quality choice as the new defaults, even
        // before the run starts — if the export fails, the user almost
        // certainly wants the same settings on retry.
        workspace.project.preferences.lastExportResolution = resolutionChoice
        workspace.project.preferences.lastExportQuality = qualityChoice
        try? workspace.saveProject()

        // Build the per-video item list now so the UI has rows from the
        // very first frame. Each entry's `videoDurationSeconds` comes from
        // the plan that will be built inside the Task. We pre-compute it
        // here from the project state — it's a sum we already know how to
        // compute, and it's cheap.
        let sourceDurations: [Int: Double] = Dictionary(
            uniqueKeysWithValues: workspace.project.sourceVideos.enumerated().map { i, ref in
                (i, ref.durationSeconds)
            }
        )
        let plans: [(key: String, plan: CompilationPlan)] = chosenTags.compactMap { tagKey -> (String, CompilationPlan)? in
            // Empty plans get skipped in the loop; mirror that here so they
            // don't appear as zero-second items.
            let plan: CompilationPlan
            if tagKey == Self.allClipsKey {
                plan = workspace.project.allClipsCompilationPlan(
                    sourceDurations: sourceDurations
                )
            } else {
                plan = workspace.project.compilationPlan(
                    for: tagKey,
                    sourceDurations: sourceDurations
                )
            }
            return plan.entries.isEmpty ? nil : (tagKey, plan)
        }

        items = plans.map { tagKey, plan in
            VideoExportItem(
                id: tagKey,
                displayName: "\(sanitizeFilename(displayLabel(forKey: tagKey)))",
                videoDurationSeconds: plan.totalDurationSeconds
            )
        }
        runRate = RollingRate(windowSeconds: 30)
        runStartedAt = Date()
        currentVideoStartedAt = nil
        projection = .empty
        lastSnapshot = nil

        run = RunState(totalCount: chosenTags.count, completedCount: 0, currentTag: chosenTags.first)

        Task {
            do {
                try FileManager.default.createDirectory(
                    at: outFolder,
                    withIntermediateDirectories: true
                )

                // Build the immutable export inputs once, outside the loop —
                // they don't change per tag. Asset construction is cheap.
                let context = try await buildExportContext(folder: workspace.folder)

                let exporter = CompilationExporter()
                for (i, tagKey) in chosenTags.enumerated() {
                    await MainActor.run {
                        run = RunState(
                            totalCount: chosenTags.count,
                            completedCount: i,
                            currentTag: tagKey
                        )
                    }

                    let plan: CompilationPlan
                    if tagKey == Self.allClipsKey {
                        plan = workspace.project.allClipsCompilationPlan(
                            sourceDurations: context.sourceDurations
                        )
                    } else {
                        plan = workspace.project.compilationPlan(
                            for: tagKey,
                            sourceDurations: context.sourceDurations
                        )
                    }

                    guard !plan.entries.isEmpty else { continue }

                    let label = displayLabel(forKey: tagKey)
                    let filename = "\(sanitizeFilename(label)) - \(sanitizeFilename(projectNameChoice)).mp4"
                    let outputURL = outFolder.appendingPathComponent(filename)
                    try? FileManager.default.removeItem(at: outputURL)

                    // Transition the matching item to .active and record
                    // its start time. The item index in `items` may differ
                    // from `i` because empty-plan tags don't appear in
                    // `items`; find it by id.
                    await MainActor.run {
                        if let idx = items.firstIndex(where: { $0.id == tagKey }) {
                            items[idx].status = .active(fractionCompleted: 0)
                        }
                        currentVideoStartedAt = Date()
                        rebuildSnapshot()
                    }

                    try await exporter.export(
                        plan: plan,
                        clipsByID: context.clipsByID,
                        sourceAssets: context.sourceAssets,
                        clipWebcamAssets: context.clipWebcamAssets,
                        outputURL: outputURL,
                        resolution: resolutionChoice,
                        quality: qualityChoice,
                        sourceVolume: workspace.project.preferences.previewSourceVolume,
                        commentaryVolume: workspace.project.preferences.previewCommentaryVolume,
                        onProgress: { fraction in
                            Task { @MainActor in
                                handleSampleFromActiveVideo(fraction)
                            }
                        }
                    )

                    // Transition .active → .done with the measured wall
                    // time and the (post-hoc) average FPS for this video.
                    await MainActor.run {
                        if let idx = items.firstIndex(where: { $0.id == tagKey }),
                           let startedAt = currentVideoStartedAt {
                            let wall = Date().timeIntervalSince(startedAt)
                            let dur = items[idx].videoDurationSeconds
                            // avgFps = (composition seconds / wall seconds) * frame rate
                            let avgFps = wall > 0 ? (dur / wall) * Self.outputFrameRate : 0
                            items[idx].status = .done(encodeWallSeconds: wall, averageFps: avgFps)
                        }
                        currentVideoStartedAt = nil
                        rebuildSnapshot()
                    }
                }

                await MainActor.run {
                    summary = Summary(folder: outFolder, fileCount: chosenTags.count)
                    run = nil
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    run = nil
                }
            }
        }
    }

    /// Selected tags in a stable order — all-clips first (if checked), then
    /// the rest alphabetically. Matches the row order in the form so the
    /// progress text reads naturally.
    private func orderedSelectedTags() -> [String] {
        var out: [String] = []
        if selectedTags.contains(Self.allClipsKey) { out.append(Self.allClipsKey) }
        let others = selectedTags.filter { $0 != Self.allClipsKey }.sorted()
        out.append(contentsOf: others)
        return out
    }

    // MARK: - Per-sample state updaters

    /// Updates the active item's fraction, records a rate sample, recomputes
    /// the projection, and rebuilds `lastSnapshot`. Called from the
    /// `onProgress` callback on MainActor.
    private func handleSampleFromActiveVideo(_ fraction: Float) {
        guard let activeIdx = items.firstIndex(where: { isActive($0.status) }) else {
            return
        }
        let clamped = max(0, min(1, fraction))
        items[activeIdx].status = .active(fractionCompleted: clamped)

        let activeDur = items[activeIdx].videoDurationSeconds
        let doneEncoded = items.reduce(0.0) { acc, item in
            if case .done = item.status {
                return acc + item.videoDurationSeconds
            }
            return acc
        }
        let activeEncoded = Double(clamped) * activeDur
        let encodedSoFar = doneEncoded + activeEncoded
        let wallNow = Date().timeIntervalSince1970
        runRate.record(wallTime: wallNow, encodedCompSeconds: encodedSoFar)

        rebuildSnapshot()
    }

    private func isActive(_ status: VideoExportItem.Status) -> Bool {
        if case .active = status { return true } else { return false }
    }

    /// Recompute `projection` and `lastSnapshot` from current `items` +
    /// `runRate`. Separate from `handleSampleFromActiveVideo` so transition
    /// points (start of a video, end of a video) can refresh the UI without
    /// inventing a fake sample.
    private func rebuildSnapshot() {
        let measured = runRate.compositionSecondsPerWallSecond()
        let rate = measured ?? 1.0
        let now = Date()
        let proj = projectRun(items: items, rate: rate, now: now)
        let fps = measured.map { $0 * Self.outputFrameRate }
        // Composition-seconds remaining is rate-INDEPENDENT — it's the
        // remaining video content the encoder still has to chew through.
        // Use it for the "X video left" reading.
        let compSecondsRemaining: Double = items.reduce(0.0) { acc, item in
            switch item.status {
            case .done:                       return acc
            case .pending:                    return acc + item.videoDurationSeconds
            case .active(let frac):           return acc + (1.0 - Double(frac)) * item.videoDurationSeconds
            }
        }
        let etaSecs = measured == nil ? nil : proj.totalSecondsRemaining
        let doneDate = measured == nil ? nil : now.addingTimeInterval(proj.totalSecondsRemaining)
        projection = proj
        lastSnapshot = ExportProgress(
            items: items,
            currentRenderingFps: fps,
            totalVideoSecondsRemaining: compSecondsRemaining,
            totalEtaSeconds: etaSecs,
            projectedCompletionDate: doneDate
        )
    }

    // MARK: - Asset wiring

    /// Resolved AVURLAssets + duration map + clip lookup. Built once per run.
    private struct ExportContext {
        var sourceAssets: [Int: AVURLAsset]
        var clipWebcamAssets: [UUID: AVURLAsset]
        var sourceDurations: [Int: Double]
        var clipsByID: [UUID: Clip]
    }

    private func buildExportContext(folder: URL?) async throws -> ExportContext {
        guard let folder else {
            throw NSError(
                domain: "ExportSheet",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No project folder is open."]
            )
        }
        let recordingsDir = ProjectStore.recordingsDir(in: folder)

        // Resolve source video bookmarks into AVURLAssets keyed by sourceIndex.
        var sourceAssets: [Int: AVURLAsset] = [:]
        var sourceDurations: [Int: Double] = [:]
        for (index, ref) in workspace.project.sourceVideos.enumerated() {
            let url = try resolveBookmark(ref.bookmark, displayName: ref.displayName)
            sourceAssets[index] = AVURLAsset(url: url)
            sourceDurations[index] = ref.durationSeconds
        }

        // Webcam assets per clip — the recording filename is just the basename.
        var clipWebcamAssets: [UUID: AVURLAsset] = [:]
        for clip in workspace.project.clips {
            let url = recordingsDir.appendingPathComponent(clip.recordingFilename)
            clipWebcamAssets[clip.id] = AVURLAsset(url: url)
        }

        let clipsByID = Dictionary(uniqueKeysWithValues: workspace.project.clips.map { ($0.id, $0) })

        return ExportContext(
            sourceAssets: sourceAssets,
            clipWebcamAssets: clipWebcamAssets,
            sourceDurations: sourceDurations,
            clipsByID: clipsByID
        )
    }

    /// Resolves a non-security-scoped bookmark to a URL. We're unsandboxed,
    /// so plain bookmarks suffice. Mirrors the helper in `Workspace`; we
    /// don't refresh on staleness here — the next project open does that.
    private func resolveBookmark(_ data: Data, displayName: String) throws -> URL {
        var stale = false
        do {
            return try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            throw NSError(
                domain: "ExportSheet",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't resolve source video '\(displayName)' — was it moved or deleted?"]
            )
        }
    }
}

// MARK: - Helpers

/// Replace filesystem-hostile characters with `-`. macOS APFS forbids `/` and
/// `:` in filenames; the user's tag/project text could realistically contain
/// either (e.g. "12:30" as a timestamp tag). Keep everything else verbatim.
private func sanitizeFilename(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
        if ch == "/" || ch == ":" {
            out.append("-")
        } else {
            out.append(ch)
        }
    }
    return out
}

// Note: a module-internal `formatDuration(_:)` already lives in
// `App/Views/ClipSidebar.swift` and renders the same `M:SS` format. We
// reuse that function here rather than re-defining it.
