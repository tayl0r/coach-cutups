# Coach Cutups

Match Video Tagger.

A native macOS app for tagging full-length sports match film and exporting per-tag MP4 cut-ups, with webcam + voice commentary and freehand drawings recorded over the play.

## Status

Pre-release. Pure-logic core (`VideoCoachCore` Swift Package) and the export pipeline are implemented and tested headlessly via `swift test`. The SwiftUI app shell, recording, clip preview, and export sheet UI are in progress on a feature branch.

## Architecture (planned)

- **Swift + SwiftUI** for the app shell, **AVFoundation** for all video work (capture, playback, composition, custom compositor, HEVC export). No FFmpeg, no third-party encoders.
- **`VideoCoachCore`** Swift Package: data model, source-time reconstruction, stroke replay algorithm, project file IO, tag aggregation, custom `AVVideoCompositing` compositor, export actor.
- Project state persists as a folder containing `project.json` + `recordings/` of `.mov` files.
- Exports one HEVC `.mp4` per checked tag, sized for direct YouTube upload.

See `docs/plans/` (on the feature branch) for the full design and implementation plan.

## Build (planned)

Requires Xcode 15+ and macOS 14+ (Apple Silicon).

```bash
brew install xcodegen
xcodegen generate
open CoachCutups.xcodeproj
```

## License

AGPL-3.0 — see [LICENSE](./LICENSE). If you ship a modified version (including as a network service), you must release the source under the same license.
