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
}
