import Foundation
import VideoCoachCore

extension Workspace: TranscriptionWorkspace {
    func recordingURL(forClip clipID: Clip.ID) -> URL? {
        guard let folder,
              let filename = project.clips
                 .first(where: { $0.id == clipID })?.recordingFilename
        else { return nil }
        return ProjectStore.recordingsDir(in: folder).appendingPathComponent(filename)
    }
}
