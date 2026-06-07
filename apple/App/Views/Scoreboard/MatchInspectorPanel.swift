import SwiftUI
import AppKit
import VideoCoachCore

/// Two-mode inspector panel for the match scoreboard. `mode` is owned by
/// `ContentView` so the Project ▸ Match Setup… menu (`⇧⌘M`) can flip the
/// panel into settings without a modal sheet.
///
/// Events mode: shows the live score + clock, an "Add Event" button that
/// toggles `eventModeActive`, and a chronological list of recorded
/// `MatchEventRecord`s with seek/delete affordances. When event mode is
/// on, an overlay surfaces the three event picks (home goal / away goal
/// / start-stop) wired to the same actions the keyboard fires.
///
/// Settings mode: in-place form for team/format editing. Writes
/// flow directly through a `Binding<ScoreboardConfig>` proxy so changes
/// land on `workspace.project.scoreboard` as the user edits. The Done
/// button (and `onDisappear`) calls `workspace.saveProject()` to flush.
struct MatchInspectorPanel: View {
    @Bindable var workspace: Workspace
    @Binding var mode: InspectorMode
    @Binding var eventModeActive: Bool

    var body: some View {
        switch mode {
        case .events:   eventsModeView
        case .settings: settingsModeView
        }
    }

    // MARK: - Events mode

    private var eventsModeView: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(title: "MATCH") {
                Button("Edit") { mode = .settings }
                    .controlSize(.small)
            }
            if let cfg = workspace.project.scoreboard {
                liveScoreLine(cfg: cfg)
            } else {
                Button("Setup Teams…") { mode = .settings }
            }
            Divider()
            Button(action: { eventModeActive.toggle() }) {
                Text("Add Event  E").frame(maxWidth: .infinity)
            }
            .disabled(workspace.project.scoreboard == nil)
            .controlSize(.large)
            if eventModeActive { eventPickerOverlay }
            Divider()
            eventsList
        }
        .padding(8)
    }

    private func liveScoreLine(cfg: ScoreboardConfig) -> some View {
        HStack {
            if let s = currentState() {
                Text("\(s.home.name) \(s.homeScore) – \(s.awayScore) \(s.away.name)")
                Spacer()
                Text(formatClock(s.clock).main).monospacedDigit()
            } else {
                Text("\(cfg.home.name) – \(cfg.away.name)")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private var eventPickerOverlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: {
                workspace.tagEvent(.homeGoal); eventModeActive = false
            }) {
                Text("1  \(MatchEventKind.homeGoal.displayName)").frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: {
                workspace.tagEvent(.awayGoal); eventModeActive = false
            }) {
                Text("2  \(MatchEventKind.awayGoal.displayName)").frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(action: {
                workspace.tagEvent(.startStop); eventModeActive = false
            }) {
                Text("3  \(MatchEventKind.startStop.displayName)").frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(startStopAtCap)
            if startStopAtCap {
                Text("Game tagged. Delete a start/stop event to add another.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Toggle("Back-anchor P1 from end", isOn: Binding(
                get: { workspace.project.hasAutoBackAnchorP1 },
                set: { newValue in
                    workspace.mutateMatchEvents { $0.setAutoBackAnchorP1(newValue) }
                }
            ))
            .help("Auto-tags P1 start at 00:00. Clock reads correct minute once you tag end of P1.")
            .disabled(workspace.project.scoreboard == nil ||
                      (startStopAtCap && !workspace.project.hasAutoBackAnchorP1))
        }
        .controlSize(.small)
        .padding(6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private var startStopAtCap: Bool {
        guard let f = workspace.project.scoreboard?.format else { return false }
        let count = workspace.project.matchEvents.lazy.filter { $0.kind == .startStop }.count
        return count >= f.expectedStartStopEvents
    }

    private var eventsList: some View {
        // Period roles for the start/stop rows below.
        let format = workspace.project.scoreboard?.format
        let roles = startStopRoles(in: workspace.project)
        return VStack(alignment: .leading) {
            Text("Events").font(.caption).foregroundStyle(.secondary)
            ForEach(sortedEvents()) { rec in
                HStack {
                    Text(timestamp(for: rec)).monospacedDigit().font(.caption2)
                    Text(format.map { roleLabel(for: rec, roles: roles, format: $0) } ?? rec.kind.displayName)
                        .font(.caption)
                    Spacer()
                    Button { seek(to: rec) } label: { Image(systemName: "arrow.right.circle") }
                        .buttonStyle(.borderless)
                    Button {
                        workspace.mutateMatchEvents { p in
                            p.matchEvents.removeAll { $0.id == rec.id }
                        }
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: - Settings mode

    private var settingsModeView: some View {
        let cfg = Binding(
            get: {
                workspace.project.scoreboard ?? ScoreboardConfig(
                    home: TeamConfig(name: "", primaryColor: RGBA(r: 0.5, g: 0.5, b: 0.5, a: 1),
                                     secondaryColor: RGBA(r: 0.5, g: 0.5, b: 0.5, a: 1)),
                    away: TeamConfig(name: "", primaryColor: RGBA(r: 0.5, g: 0.5, b: 0.5, a: 1),
                                     secondaryColor: RGBA(r: 0.5, g: 0.5, b: 0.5, a: 1))
                )
            },
            set: { workspace.project.scoreboard = $0 }
        )
        return VStack(alignment: .leading, spacing: 8) {
            header(title: "MATCH SETTINGS") {
                Button("Done") {
                    mode = .events
                    try? workspace.saveProject()
                }
                .controlSize(.small)
            }
            Form {
                Section("Home Team") {
                    TextField("Name", text: cfg.home.name)
                    ColorPickerCell(label: "Primary", color: cfg.home.primaryColor)
                    ColorPickerCell(label: "Secondary", color: cfg.home.secondaryColor)
                    ColorPickerCell(label: "Font", color: cfg.home.fontColor)
                }
                Section("Away Team") {
                    TextField("Name", text: cfg.away.name)
                    ColorPickerCell(label: "Primary", color: cfg.away.primaryColor)
                    ColorPickerCell(label: "Secondary", color: cfg.away.secondaryColor)
                    ColorPickerCell(label: "Font", color: cfg.away.fontColor)
                }
                Section("Format") {
                    Stepper("Regulation periods: \(cfg.wrappedValue.format.regulationPeriods)",
                            value: cfg.format.regulationPeriods, in: 1...10)
                    Stepper("Period length: \(cfg.wrappedValue.format.regulationPeriodMinutes) min",
                            value: cfg.format.regulationPeriodMinutes, in: 1...180)
                    Stepper("Overtime periods: \(cfg.wrappedValue.format.overtimePeriods)",
                            value: cfg.format.overtimePeriods, in: 0...10)
                    Stepper("OT period length: \(cfg.wrappedValue.format.overtimePeriodMinutes) min",
                            value: cfg.format.overtimePeriodMinutes, in: 1...60)
                        .disabled(cfg.wrappedValue.format.overtimePeriods == 0)
                }
                if overcapacityCount > 0 {
                    Section {
                        Text("\(overcapacityCount) start/stop events exceed format capacity; delete or expand the format.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .padding(8)
        .onDisappear { try? workspace.saveProject() }
    }

    private var overcapacityCount: Int {
        guard let f = workspace.project.scoreboard?.format else { return 0 }
        let count = workspace.project.matchEvents.lazy.filter { $0.kind == .startStop }.count
        return max(0, count - f.expectedStartStopEvents)
    }

    // MARK: - Helpers

    private func header<Trailing: View>(
        title: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            Spacer()
            trailing()
        }
    }

    private func currentState() -> ScoreboardState? {
        guard let player = workspace.sourcePlayer else { return nil }
        return scoreboardState(
            atSourceIndex: player.playlistPos,
            sourceSeconds: player.timePos,
            project: workspace.project)
    }

    private func seek(to rec: MatchEventRecord) {
        workspace.sourcePlayer?.seek(
            playlistPos: rec.sourceIndex,
            timeSeconds: rec.sourceSeconds,
            exact: true,
            completion: {})
    }

    private func sortedEvents() -> [MatchEventRecord] {
        workspace.project.matchEvents.sorted { lhs, rhs in
            let l = workspace.project.absSeconds(sourceIndex: lhs.sourceIndex, sourceSeconds: lhs.sourceSeconds)
            let r = workspace.project.absSeconds(sourceIndex: rhs.sourceIndex, sourceSeconds: rhs.sourceSeconds)
            return l < r
        }
    }

    private func timestamp(for rec: MatchEventRecord) -> String {
        let abs = workspace.project.absSeconds(sourceIndex: rec.sourceIndex, sourceSeconds: rec.sourceSeconds)
        let total = Int(abs)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// A missing `roles` entry means the record is past the format's cap;
    /// fall back to the bare "Start/Stop" label.
    private func roleLabel(for rec: MatchEventRecord, roles: [UUID: PeriodRole], format: MatchFormat) -> String {
        switch rec.kind {
        case .homeGoal, .awayGoal:
            return rec.kind.displayName
        case .startStop:
            guard let role = roles[rec.id] else { return "Start/Stop" }
            switch role {
            case .start(let i):
                let suffix = rec.isAutoBackAnchor ? " (auto)" : ""
                return "\(format.periodName(i)) Start\(suffix)"
            case .end(let i):   return "\(format.periodName(i)) End"
            }
        }
    }
}

private struct ColorPickerCell: View {
    let label: String
    @Binding var color: RGBA
    var body: some View {
        HStack {
            Text(label).font(.caption)
            Spacer()
            ColorPicker("", selection: Binding(
                get: { Color(red: color.r, green: color.g, blue: color.b, opacity: color.a) },
                set: { newColor in
                    let ns = NSColor(newColor).usingColorSpace(.deviceRGB) ?? .gray
                    color = RGBA(r: Double(ns.redComponent),
                                 g: Double(ns.greenComponent),
                                 b: Double(ns.blueComponent),
                                 a: Double(ns.alphaComponent))
                }
            ), supportsOpacity: false)
        }
    }
}
