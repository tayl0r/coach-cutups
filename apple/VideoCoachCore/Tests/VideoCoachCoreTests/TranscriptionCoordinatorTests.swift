import XCTest
@testable import VideoCoachCore

@MainActor
final class TranscriptionCoordinatorTests: XCTestCase {

    private func makeFixture() throws -> (ws: FakeTranscriptionWorkspace,
                                          clipID: UUID,
                                          fake: FakeClipIntelligence) {
        let id = UUID()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tc-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Stub recording file so resolved URL points at a real path.
        try Data("stub".utf8).write(to: tmp.appendingPathComponent("c.mov"))

        var p = Project(name: "T")
        p.clips.append(Clip(
            id: id, name: "c",
            sourceIndex: 0, startSourceSeconds: 0,
            recordingDuration: 1, recordingFilename: "c.mov",
            sortIndex: 0
        ))
        let ws = FakeTranscriptionWorkspace(project: p, recordingsDir: tmp)
        return (ws, id, FakeClipIntelligence())
    }

    /// Spin until predicate true or timeout. Calls XCTFail on timeout
    /// (NOT a silent return) so a misbehaving coordinator surfaces a
    /// proper test failure rather than fall-through assertion errors.
    private func waitUntil(timeout: TimeInterval = 2,
                           file: StaticString = #filePath,
                           line: UInt = #line,
                           _ predicate: @autoclosure @escaping () -> Bool) async {
        let start = Date()
        while !predicate() {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("waitUntil timed out after \(timeout)s",
                        file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func test_happyPath_writesBothFields() async throws {
        let (ws, id, fake) = try makeFixture()
        fake.transcriptToReturn = "t"
        fake.summaryToReturn = "s"
        let tc = TranscriptionCoordinator(workspace: ws, intelligence: fake)

        tc.enqueue(clipID: id)
        await waitUntil(tc.state(for: id) == .idle)

        XCTAssertEqual(ws.project.clips[0].transcript, "t")
        XCTAssertEqual(ws.project.clips[0].summary, "s")
        XCTAssertEqual(fake.transcribeCalls.count, 1)
        XCTAssertEqual(fake.summarizeCalls.first, "t")
        XCTAssertEqual(tc.state(for: id), .idle)
    }

    func test_transcribeFailure_leavesBothFieldsEmpty_failedState() async throws {
        let (ws, id, fake) = try makeFixture()
        fake.transcribeError = NSError(domain: "X", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "boom"])
        let tc = TranscriptionCoordinator(workspace: ws, intelligence: fake)

        tc.enqueue(clipID: id)
        await waitUntil(tc.inFlightClipID == nil)

        XCTAssertEqual(ws.project.clips[0].transcript, "")
        XCTAssertEqual(ws.project.clips[0].summary, "")
        XCTAssertEqual(tc.state(for: id), .failed("boom"))
        XCTAssertEqual(fake.summarizeCalls.count, 0,
                       "summarize must NOT run after transcribe failed")
    }

    func test_summarizeFailure_keepsTranscript_failedState() async throws {
        let (ws, id, fake) = try makeFixture()
        fake.transcriptToReturn = "kept"
        fake.summarizeError = NSError(domain: "X", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "blammo"])
        let tc = TranscriptionCoordinator(workspace: ws, intelligence: fake)

        tc.enqueue(clipID: id)
        await waitUntil(tc.inFlightClipID == nil)

        XCTAssertEqual(ws.project.clips[0].transcript, "kept",
                       "transcript must persist even if summary fails")
        XCTAssertEqual(ws.project.clips[0].summary, "")
        XCTAssertEqual(tc.state(for: id), .failed("blammo"))
    }

    func test_doubleEnqueue_isNoop() async throws {
        let (ws, id, fake) = try makeFixture()
        fake.transcribeDelaySeconds = 0.05
        let tc = TranscriptionCoordinator(workspace: ws, intelligence: fake)

        tc.enqueue(clipID: id)
        tc.enqueue(clipID: id)
        tc.enqueue(clipID: id)
        await waitUntil(tc.state(for: id) == .idle)

        XCTAssertEqual(fake.transcribeCalls.count, 1,
                       "repeat enqueues during/after job must be no-ops")
    }

    func test_twoClips_runSeriallyInEnqueueOrder() async throws {
        let (ws, id1, fake) = try makeFixture()
        let id2 = UUID()
        ws.project.clips.append(Clip(
            id: id2, name: "c2",
            sourceIndex: 0, startSourceSeconds: 0,
            recordingDuration: 1, recordingFilename: "c2.mov",
            sortIndex: 1
        ))
        try Data("stub".utf8).write(
            to: ws.recordingsDir.appendingPathComponent("c2.mov"))
        fake.transcribeDelaySeconds = 0.02

        let tc = TranscriptionCoordinator(workspace: ws, intelligence: fake)
        tc.enqueue(clipID: id1)
        tc.enqueue(clipID: id2)

        await waitUntil(timeout: 5,
                        fake.transcribeCalls.count == 2 && tc.inFlightClipID == nil)
        // Seriality is proven by call ordering: the coordinator's single
        // `inFlightClipID` guarantees at-most-one job, so the two recorded
        // calls must be in enqueue order.
        XCTAssertEqual(fake.transcribeCalls.map(\.lastPathComponent),
                       ["c.mov", "c2.mov"])
        XCTAssertEqual(fake.summarizeCalls.count, 2)
    }

    func test_clipDeletedMidJob_drainsToIdle() async throws {
        let (ws, id, fake) = try makeFixture()
        fake.transcribeDelaySeconds = 0.05
        let tc = TranscriptionCoordinator(workspace: ws, intelligence: fake)

        tc.enqueue(clipID: id)
        try? await Task.sleep(nanoseconds: 10_000_000)
        ws.project.clips.removeAll()

        await waitUntil(tc.inFlightClipID == nil)
        XCTAssertEqual(tc.state(for: id), .idle,
                       "deleted clip must resolve to .idle, not .failed")
        XCTAssertEqual(fake.transcribeCalls.count, 1,
                       "in-flight job must run to completion even after clip removed")
        XCTAssertTrue(ws.project.clips.isEmpty)
        XCTAssertNil(tc.inFlightClipID,
                     "coordinator must drain the job even when target clip vanishes")
    }
}
