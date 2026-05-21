import XCTest
@testable import VideoCoachCore

final class ProjectAIWriteTests: XCTestCase {
    private func makeProject(withClipID id: UUID) -> Project {
        var p = Project(name: "T")
        p.clips.append(Clip(
            id: id, name: "c",
            sourceIndex: 0, startSourceSeconds: 0,
            recordingDuration: 1, recordingFilename: "c.mov",
            sortIndex: 0
        ))
        return p
    }

    func test_applyAIWrite_mutatesClipAndPreservesOtherFields() {
        let id = UUID()
        var p = makeProject(withClipID: id)
        p.clips[0].notes = "user-written"

        p.applyAIWrite(id: id) { $0.transcript = "hello world" }

        XCTAssertEqual(p.clips[0].transcript, "hello world")
        XCTAssertEqual(p.clips[0].notes, "user-written",
                       "notes must not be touched by an AI write")
    }

    func test_applyAIWrite_shortCircuitsOnMissingClipID() {
        var p = makeProject(withClipID: UUID())
        p.applyAIWrite(id: UUID()) { $0.transcript = "X" }
        XCTAssertEqual(p.clips[0].transcript, "",
                       "missing clip ID must be a no-op, not a crash")
    }
}
