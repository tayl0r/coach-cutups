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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(Project.self, from: data)
        // Upper bound is `Project.currentFormatVersion` — bump it there to
        // widen this guard. See `Project.currentFormatVersion`'s doc for
        // per-version migration notes.
        if project.formatVersion < 1 || project.formatVersion > Project.currentFormatVersion {
            throw ProjectStoreError.unsupportedFormatVersion(project.formatVersion)
        }
        return project
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
