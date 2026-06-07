# Coach Cuts

Native macOS app for breaking down sports match film. Watch the game, tag the moments you care about, narrate over them with webcam + voice and freehand drawings, and export per-tag YouTube-ready clips.

Built on Swift + SwiftUI + AVFoundation. No FFmpeg, no third-party encoders, no network calls — transcription and summaries run on-device via Apple's `SpeechAnalyzer` and `FoundationModels`.

## Features

**Tagging & navigation**
- Scrub any source video, tag a moment with a name and free-form tags, mark a duration around it.
- Tag overview and filter — pivot a session by tag to find every "transition" or "set piece" across all sources.
- Jump-to-clip shortcuts. Per-clip key commands for fast navigation.
- Per-clip transcript and 1–2 sentence summary, auto-generated from your commentary (editable).

**Commentary recording**
- Webcam + microphone capture overlaid onto each clip as a picture-in-picture.
- Freehand drawing layer recorded in sync with playback for telestration-style analysis.
- Picture-in-picture visibility togglable per clip.
- Drawings replay over the source video on export — no flattened raster.

**Scoreboard + match clock**
- Configurable two-team scoreboard with team colors, primary/secondary, and font color.
- Match formats: any number of regulation periods of any length, plus optional overtime.
- Tag start/stop, home goal, away goal during a match. The clock derives period transitions, halftime breaks, stoppage, and fulltime automatically.
- **Back-anchor P1 clock from end-of-period-1**: if your recording missed the actual kickoff, tick a checkbox and tag end of P1 — the clock back-computes the displayed minute so it reads correctly across the recording.
- Scoreboard overlay rendered onto exports.

**Export**
- One HEVC `.mp4` per checked tag, sized for direct YouTube upload (1080p or 720p, low/medium/high quality).
- Custom AVFoundation compositor handles webcam PiP, drawings, scoreboard, and zoom in a single render pass.
- Headless export pipeline — no hidden window required.

**Project format**
- Each project is a folder: `project.json` + `recordings/` of `.mov` files (your commentary tracks).
- Format-versioned schema with at-decode migration. v6 (current).

## Requirements

- macOS 26 (Tahoe) or later
- Apple Silicon
- Xcode with the macOS 26 SDK installed (only needed if building from source)

## Run from source

```bash
# One-shot build + launch (Debug)
apple/scripts/run.sh

# Release build
apple/scripts/run.sh Release
```

The script regenerates the Xcode project from `apple/project.yml` if needed, stamps the current git SHA into the build, kills any running instance, and launches the freshly built `CoachCuts.app` from DerivedData.

If you'd rather drive Xcode yourself:

```bash
brew install xcodegen
cd apple && xcodegen generate
open VideoCoach.xcodeproj
```

## Install into /Applications

```bash
# Build Release, install to /Applications, sign, strip quarantine
apple/scripts/install.sh

# Same, but also launch after install
apple/scripts/install.sh --launch
```

Override the code-signing identity with `VIDEO_COACH_IDENTITY=...` (defaults to `Apple Development`).

## Pre-built downloads

See the [Releases page](../../releases) for signed `CoachCuts.app` builds.

## Repo layout

```
apple/
├── App/                       # SwiftUI + AppKit interop, ContentView, capture, recording
├── VideoCoachCore/            # Swift Package — pure logic, headless-testable
│   ├── Sources/VideoCoachCore # data model, clock, compositor, export pipeline
│   └── Tests/VideoCoachCoreTests
├── scripts/
│   ├── run.sh                 # build + launch
│   ├── install.sh             # build Release + install to /Applications
│   └── sign.sh                # codesign helper
└── project.yml                # XcodeGen source for VideoCoach.xcodeproj
docs/superpowers/
├── specs/                     # Design specs per feature
└── plans/                     # Implementation plans per feature
CLAUDE.md                      # Project conventions for AI-assisted development
```

The `.xcodeproj` is gitignored — regenerate it from `apple/project.yml` with `xcodegen generate` (or let `run.sh`/`install.sh` do it for you).

## Tests

```bash
# Pure-logic core (fast, headless)
swift test --package-path apple/VideoCoachCore

# App build
cd apple && xcodegen generate && cd ..
xcodebuild -project apple/VideoCoach.xcodeproj -scheme VideoCoach -destination 'platform=macOS' build
```

## License

AGPL-3.0 — see [LICENSE](./LICENSE). If you ship a modified version (including as a network service), you must release the source under the same license.
