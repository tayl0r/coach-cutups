import Foundation

public enum ProjectStoreError: Error {
    case missingProjectJSON
    case unsupportedFormatVersion(Int)
}

public enum ProjectStore {
    public static let projectFileName = "project.json"
    public static let recordingsDirName = "recordings"

    public static func read(from folder: URL) throws -> Project {
        let url = folder.appendingPathComponent(projectFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectStoreError.missingProjectJSON
        }
        let data = try Data(contentsOf: url)
        let migratedData = try migrateIfNeeded(data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(Project.self, from: migratedData)
        // Upper bound is `Project.currentFormatVersion` — bump it there to
        // widen this guard. See `Project.currentFormatVersion`'s doc for
        // per-version migration notes.
        if project.formatVersion < 1 || project.formatVersion > Project.currentFormatVersion {
            throw ProjectStoreError.unsupportedFormatVersion(project.formatVersion)
        }
        return project
    }

    /// Project file format migrator. Each `vN → v(N+1)` step is a small
    /// in-blob patch — keeps `Project` / `Clip` / `Preferences` on
    /// synthesized `Codable` so future field additions don't have to
    /// remember to update a hand-rolled decoder. A forgotten migrator step
    /// fails LOUD (decoder throws `.keyNotFound`); a forgotten
    /// `decodeIfPresent` would fail SILENT (new field decodes as zero
    /// without anyone noticing).
    private static func migrateIfNeeded(_ data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(
            with: data, options: []) as? [String: Any]
        else { return data }
        let version = (root["formatVersion"] as? Int) ?? 1
        // Fast path for v3+ files. `ProjectStore.read` runs on every project
        // open + Open Recent — once every project has been written as v3 the
        // re-encode below would be pure overhead.
        if version >= 3 { return data }

        if var prefs = root["preferences"] as? [String: Any] {
            if prefs["pipForNewRecordings"] == nil {
                prefs["pipForNewRecordings"] = true
                root["preferences"] = prefs
            }
        }
        if var clips = root["clips"] as? [[String: Any]] {
            for i in clips.indices where clips[i]["showPiP"] == nil {
                clips[i]["showPiP"] = true
            }
            root["clips"] = clips
        }
        root["formatVersion"] = 3

        return try JSONSerialization.data(withJSONObject: root, options: [])
    }

    public static func write(_ project: Project, to folder: URL) throws {
        var project = project
        project.formatVersion = Project.currentFormatVersion
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: folder.appendingPathComponent(recordingsDirName),
            withIntermediateDirectories: true)

        let target = folder.appendingPathComponent(projectFileName)
        let tmp = folder.appendingPathComponent("project.json.tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.moveItem(at: tmp, to: target)
    }

    public static func recordingsDir(in folder: URL) -> URL {
        folder.appendingPathComponent(recordingsDirName, isDirectory: true)
    }
}
