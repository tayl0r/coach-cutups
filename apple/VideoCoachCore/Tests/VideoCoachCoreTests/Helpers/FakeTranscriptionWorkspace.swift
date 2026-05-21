import Foundation
@testable import VideoCoachCore

/// Test fake for `TranscriptionWorkspace`. Holds a `Project` and a
/// recordings-dir URL; `applyAIWrite` mutates the project in place.
@MainActor
final class FakeTranscriptionWorkspace: TranscriptionWorkspace {
    var project: Project
    var recordingsDir: URL

    init(project: Project, recordingsDir: URL) {
        self.project = project
        self.recordingsDir = recordingsDir
    }

    func recordingURL(forClip clipID: Clip.ID) -> URL? {
        guard let clip = project.clips.first(where: { $0.id == clipID })
        else { return nil }
        return recordingsDir.appendingPathComponent(clip.recordingFilename)
    }

    func applyAIWrite(id: Clip.ID, _ mutate: (inout Clip) -> Void) {
        project.applyAIWrite(id: id, mutate)
    }
}
