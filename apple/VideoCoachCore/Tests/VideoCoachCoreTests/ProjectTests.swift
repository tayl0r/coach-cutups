import XCTest
@testable import VideoCoachCore

final class ProjectTests: XCTestCase {
    func test_normalizeTags_splitsOnCommaTrimsLowercasesAndDedupes() {
        XCTAssertEqual(
            Tag.normalize(input: " Attacking-Chance, transitions , set,piece, transitions "),
            ["attacking-chance", "transitions", "set", "piece"]
        )
    }

    func test_emptyProjectRoundtripsThroughJSON() throws {
        let p = Project(name: "MyMatch")
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(decoded.name, "MyMatch")
        XCTAssertEqual(decoded.formatVersion, 2)
        XCTAssertTrue(decoded.clips.isEmpty)
    }

    func test_projectWithClipRoundtrips() throws {
        var p = Project(name: "M")
        p.clips.append(Clip(
            name: "play 1", notes: "first one", tags: ["attacking-chance"],
            sourceIndex: 0, startSourceSeconds: 12.0, recordingDuration: 4.5,
            recordingFilename: "clip-A.mov",
            events: [.init(recordTime: 0, kind: .play)],
            sortIndex: 0
        ))
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(decoded.clips.first?.tags, ["attacking-chance"])
    }

    func test_normalizeTags_handlesEmptyFragmentsAndMultilineWhitespace() {
        XCTAssertEqual(Tag.normalize(input: ",,,"), [])
        XCTAssertEqual(Tag.normalize(input: "a,,b"), ["a", "b"])
        XCTAssertEqual(Tag.normalize(input: "  ,foo,  "), ["foo"])
        XCTAssertEqual(
            Tag.normalize(input: "foo,\n  bar  ,baz\t"),
            ["foo", "bar", "baz"]
        )
    }

    func test_preferencesDeviceIDs_roundtripWhenSet() throws {
        var p = Project(name: "DevicePrefs")
        p.preferences.preferredCameraID = "cam-uniqueID-123"
        p.preferences.preferredMicID = "mic-uniqueID-456"
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(decoded.preferences.preferredCameraID, "cam-uniqueID-123")
        XCTAssertEqual(decoded.preferences.preferredMicID, "mic-uniqueID-456")
    }

    func test_preferencesDeviceIDs_decodeFromLegacyJSONMissingKeys() throws {
        // Legacy project.json from before the Devices menu shipped: no
        // preferredCameraID / preferredMicID keys present. Must decode
        // cleanly with both fields nil — this is the back-compat contract.
        let legacyJSON = """
        {
          "formatVersion": 1,
          "name": "Legacy",
          "sourceVideos": [],
          "clips": [],
          "preferences": {
            "scanVolume": 1.0,
            "previewSourceVolume": 1.0,
            "previewCommentaryVolume": 1.0,
            "lastExportResolution": "r1080",
            "lastExportQuality": "medium"
          }
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Project.self, from: legacyJSON)
        XCTAssertNil(decoded.preferences.preferredCameraID)
        XCTAssertNil(decoded.preferences.preferredMicID)
        XCTAssertEqual(decoded.name, "Legacy")
    }

    func test_projectWithNestedStrokeEventRoundtrips() throws {
        let strokeID = UUID()
        let stroke = Stroke(
            id: strokeID,
            color: .red,
            lineWidth: 0.0125,
            points: [
                .init(x: 0.1, y: 0.2, t: 0.0),
                .init(x: 0.3, y: 0.4, t: 0.05),
            ],
            autoClearAfterSeconds: nil
        )
        var p = Project(name: "Nested")
        p.clips.append(Clip(
            name: "with stroke",
            sourceIndex: 0,
            startSourceSeconds: 0,
            recordingDuration: 1.0,
            recordingFilename: "c.mov",
            events: [.init(recordTime: 0.5, kind: .stroke(stroke))],
            sortIndex: 0
        ))
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        guard let event = decoded.clips.first?.events.first else {
            XCTFail("expected nested event"); return
        }
        guard case .stroke(let decodedStroke) = event.kind else {
            XCTFail("expected .stroke kind"); return
        }
        XCTAssertEqual(decodedStroke.id, strokeID)
        XCTAssertEqual(decodedStroke.points.count, 2)
        XCTAssertEqual(decodedStroke.lineWidth, 0.0125)
    }
}
