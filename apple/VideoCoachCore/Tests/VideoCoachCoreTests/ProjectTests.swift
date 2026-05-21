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
        XCTAssertEqual(decoded.formatVersion, 5)
        XCTAssertTrue(decoded.clips.isEmpty)
    }

    func test_projectWithClipRoundtrips() throws {
        var p = Project(name: "M")
        p.clips.append(Clip(
            name: "play 1", notes: "first one", tags: ["attacking-chance"],
            sourceIndex: 0, startSourceSeconds: 12.0, recordingDuration: 4.5,
            recordingFilename: "clip-A.mov",
            events: [.init(recordTime: 0, kind: .play(sourceTime: 0))],
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
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-device-ids-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
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
            "lastExportQuality": "medium",
            "pipForNewRecordings": true
          }
        }
        """.data(using: .utf8)!
        try legacyJSON.write(to: dir.appendingPathComponent("project.json"))
        let decoded = try ProjectStore.read(from: dir)
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

    func test_freshProjectHasShowPiPDefaultsAndFormatVersion() throws {
        let p = Project(name: "M")
        XCTAssertEqual(p.formatVersion, 5)
        XCTAssertTrue(p.preferences.pipForNewRecordings)
        var withClip = p
        withClip.clips.append(Clip(
            name: "c", sourceIndex: 0, startSourceSeconds: 0,
            recordingDuration: 1, recordingFilename: "c.mov", sortIndex: 0
        ))
        XCTAssertTrue(withClip.clips[0].showPiP, "Clip.showPiP must default to true")
    }

    func test_showPiPFalseRoundtripsThroughJSON() throws {
        var p = Project(name: "M")
        p.preferences.pipForNewRecordings = false
        p.clips.append(Clip(
            name: "c", sourceIndex: 0, startSourceSeconds: 0,
            recordingDuration: 1, recordingFilename: "c.mov",
            showPiP: false, sortIndex: 0
        ))
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertFalse(decoded.preferences.pipForNewRecordings)
        XCTAssertFalse(decoded.clips[0].showPiP)
    }

    func test_v2JSON_decodesWithEmptyScoreboardDefaults() throws {
        let json = """
        {
          "formatVersion": 2, "name": "x",
          "sourceVideos": [], "clips": [],
          "preferences": {
            "scanVolume": 1, "previewSourceVolume": 1, "previewCommentaryVolume": 1,
            "lastExportResolution": "r1080", "lastExportQuality": "medium",
            "pipForNewRecordings": true
          }
        }
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(Project.self, from: json)
        XCTAssertEqual(p.formatVersion, 2)
        XCTAssertNil(p.scoreboard)
        XCTAssertTrue(p.matchEvents.isEmpty)
    }

    func test_projectStore_writeBumpsFormatVersionToCurrent() throws {
        var p = Project(name: "x")
        p.formatVersion = 2  // simulate freshly loaded v2 project
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try ProjectStore.write(p, to: tmp)
        let reread = try ProjectStore.read(from: tmp)
        XCTAssertEqual(reread.formatVersion, 5, "write must bump formatVersion to current (5)")
    }

    func test_projectStore_v4RoundTripWithScoreboard() throws {
        var p = Project(name: "x")
        p.scoreboard = ScoreboardConfig(
            home: TeamConfig(name: "ARS", primaryColor: .red, secondaryColor: .red),
            away: TeamConfig(name: "BUR", primaryColor: .red, secondaryColor: .red))
        p.appendStartStop(sourceIndex: 0, sourceSeconds: 1.0)
        p.appendHomeGoal(sourceIndex: 0, sourceSeconds: 10.0)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try ProjectStore.write(p, to: tmp)
        let reread = try ProjectStore.read(from: tmp)
        XCTAssertEqual(reread.scoreboard?.home.name, "ARS")
        XCTAssertEqual(reread.matchEvents.count, 2)
    }

    func test_v4Scoreboard_roundTripsFontColor() throws {
        var home = TeamConfig(name: "ARS",
                              primaryColor: .red,
                              secondaryColor: .red)
        home.fontColor = RGBA(r: 0, g: 0, b: 1, a: 1)
        var away = TeamConfig(name: "BUR",
                              primaryColor: .red,
                              secondaryColor: .red)
        away.fontColor = RGBA(r: 1, g: 1, b: 0, a: 1)
        let cfg = ScoreboardConfig(home: home, away: away)
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(ScoreboardConfig.self, from: data)
        XCTAssertEqual(decoded.home.fontColor, RGBA(r: 0, g: 0, b: 1, a: 1))
        XCTAssertEqual(decoded.away.fontColor, RGBA(r: 1, g: 1, b: 0, a: 1))
    }

    func test_v4ClipMissingTranscriptAndSummary_decodesToEmptyStrings() throws {
        // Hand-written v4 JSON: full Clip with no `transcript` and no `summary`
        // keys. This is the canonical regression test for additive Clip-field
        // migrations going forward.
        let v4JSON = """
        {
          "formatVersion": 4,
          "name": "LegacyV4",
          "sourceVideos": [],
          "clips": [{
            "id": "11111111-2222-3333-4444-555555555555",
            "name": "old clip",
            "notes": "hand-written notes",
            "tags": ["legacy"],
            "sourceIndex": 0,
            "startSourceSeconds": 0,
            "recordingDuration": 1.5,
            "recordingFilename": "c.mov",
            "events": [],
            "showPiP": true,
            "sortIndex": 0,
            "createdAt": "2025-01-01T00:00:00Z"
          }],
          "preferences": {
            "scanVolume": 1.0,
            "previewSourceVolume": 1.0,
            "previewCommentaryVolume": 1.0,
            "lastExportResolution": "r1080",
            "lastExportQuality": "medium",
            "pipForNewRecordings": true
          },
          "matchEvents": []
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let p = try decoder.decode(Project.self, from: v4JSON)
        XCTAssertEqual(p.clips.count, 1)
        XCTAssertEqual(p.clips[0].transcript, "")
        XCTAssertEqual(p.clips[0].summary, "")
        XCTAssertEqual(p.clips[0].notes, "hand-written notes",
                       "existing user-written notes must survive untouched")
    }

    func test_transcriptAndSummaryRoundtripThroughJSON() throws {
        var p = Project(name: "M")
        p.clips.append(Clip(
            name: "c", sourceIndex: 0, startSourceSeconds: 0,
            recordingDuration: 1, recordingFilename: "c.mov",
            sortIndex: 0
        ))
        p.clips[0].transcript = "okay so right here the through-ball really opens up the line"
        p.clips[0].summary = "Coach praises the through-ball that opens the line."

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(p)
        let decoded = try decoder.decode(Project.self, from: data)
        XCTAssertEqual(decoded.clips[0].transcript,
                       "okay so right here the through-ball really opens up the line")
        XCTAssertEqual(decoded.clips[0].summary,
                       "Coach praises the through-ball that opens the line.")
    }
}
