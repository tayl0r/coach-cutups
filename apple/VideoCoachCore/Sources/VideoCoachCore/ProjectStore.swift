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
        // Accept v1 (legacy) and v2 (added .zoom event variant). Newer formats
        // are rejected so we don't silently misinterpret unknown future fields.
        // Unknown CommentaryEvent.Kind discriminators within a v2 file decode
        // as `.unknown` rather than throwing — see CommentaryEvent.swift.
        if project.formatVersion < 1 || project.formatVersion > 2 {
            throw ProjectStoreError.unsupportedFormatVersion(project.formatVersion)
        }
        return project
    }

    public static func write(_ project: Project, to folder: URL) throws {
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
