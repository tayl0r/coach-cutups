import XCTest
@testable import VideoCoachCore

final class ProjectStoreTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_writeThenReadRoundtripsProject() throws {
        var p = Project(name: "RoundTrip")
        p.preferences.scanVolume = 0.5
        try ProjectStore.write(p, to: tmp)
        let loaded = try ProjectStore.read(from: tmp)
        XCTAssertEqual(loaded.name, "RoundTrip")
        XCTAssertEqual(loaded.preferences.scanVolume, 0.5)
    }

    func test_writeCreatesRecordingsSubfolder() throws {
        try ProjectStore.write(Project(name: "x"), to: tmp)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmp.appendingPathComponent("recordings").path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func test_atomicWrite_doesNotCorruptOnSecondWrite() throws {
        let p1 = Project(name: "v1")
        var p2 = Project(name: "v2"); p2.formatVersion = 1
        try ProjectStore.write(p1, to: tmp)
        try ProjectStore.write(p2, to: tmp)
        XCTAssertEqual(try ProjectStore.read(from: tmp).name, "v2")
    }

    /// Regression: encoder uses .iso8601 for dates; the decoder must match or
    /// any saved Clip (which has a createdAt: Date) will fail to read back.
    func test_unsupportedFormatVersionV4_isRejected() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hide-pip-migrate-reject-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let v4 = """
        {
          "formatVersion": 4,
          "name": "Future",
          "sourceVideos": [],
          "clips": [],
          "preferences": {
            "scanVolume": 1.0,
            "previewSourceVolume": 1.0,
            "previewCommentaryVolume": 1.0,
            "lastExportResolution": "r1080",
            "lastExportQuality": "medium",
            "pipForNewRecordings": true
          }
        }
        """.data(using: .utf8)!
        try v4.write(to: dir.appendingPathComponent("project.json"))
        XCTAssertThrowsError(try ProjectStore.read(from: dir)) { error in
            guard case ProjectStoreError.unsupportedFormatVersion(let v) = error else {
                XCTFail("expected .unsupportedFormatVersion, got \(error)"); return
            }
            XCTAssertEqual(v, 4)
        }
    }

    func test_projectWithClipCreatedAtRoundtrips() throws {
        var p = Project(name: "WithClip")
        let clip = Clip(
            name: "c1",
            sourceIndex: 0,
            startSourceSeconds: 1.0,
            recordingDuration: 2.0,
            recordingFilename: "clip-x.mov",
            sortIndex: 0,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        p.clips.append(clip)
        try ProjectStore.write(p, to: tmp)
        let loaded = try ProjectStore.read(from: tmp)
        XCTAssertEqual(loaded.clips.first?.createdAt.timeIntervalSince1970 ?? .nan,
                       1_700_000_000, accuracy: 1.0)
    }
}
