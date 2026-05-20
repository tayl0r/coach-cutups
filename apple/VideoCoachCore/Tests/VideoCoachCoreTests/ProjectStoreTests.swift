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

    /// Future format versions (beyond `currentFormatVersion`) must be
    /// rejected — otherwise we'd silently misinterpret unknown future fields.
    func test_unsupportedFutureFormatVersion_isRejected() throws {
        let futureVersion = Project.currentFormatVersion + 1
        let json = """
        {
          "formatVersion": \(futureVersion),
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
        try json.write(to: tmp.appendingPathComponent("project.json"))
        XCTAssertThrowsError(try ProjectStore.read(from: tmp)) { error in
            guard case ProjectStoreError.unsupportedFormatVersion(let v) = error else {
                XCTFail("expected .unsupportedFormatVersion, got \(error)"); return
            }
            XCTAssertEqual(v, futureVersion)
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
