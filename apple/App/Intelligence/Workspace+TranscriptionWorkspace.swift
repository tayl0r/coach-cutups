import Foundation
import VideoCoachCore

extension Workspace: TranscriptionWorkspace {
    func recordingURL(forClip clipID: Clip.ID) -> URL? {
        guard let filename = project.clips
            .first(where: { $0.id == clipID })?.recordingFilename
        else { return nil }
        return recordingURL(for: filename)
    }
}
