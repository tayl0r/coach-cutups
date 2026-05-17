# Hide the PiP video on a per-clip basis

## Goal

Let the user suppress the webcam picture-in-picture overlay on a
per-clip basis during preview and export. The webcam is still
**recorded** for every clip (file capture is unchanged); only the
playback-side composite respects the flag, so a clip can be flipped
back later without re-recording.

Two surfaces:

- A **global** "PiP?" checkbox lives in the transport bar and seeds
  the per-clip flag on every new recording.
- A **per-clip** "PiP?" checkbox lives in the clip inspector and is
  the authoritative value the compositors read.

The global checkbox is **sampled at clip-stop** (when the user presses
R to end the recording), not at start. The user can flip it freely
mid-recording; whatever it reads at stop is what the new clip gets.

## Polarity and naming

| Layer | Name | Type | Default | Semantics |
|---|---|---|---|---|
| `Preferences` | `pipForNewRecordings` | `Bool` | `true` | Project-level default for new clips |
| `Clip` | `showPiP` | `Bool` | `true` | Authoritative per-clip flag |
| `PreviewInstruction` | `pipHidden` | `Bool` | `false` | Compositor "skip the draw" guard |
| `CompilationInstruction` | `pipHidden` | `Bool` | `false` | Compositor "skip the draw" guard |

Polarity is inverted on purpose between `Clip` and the instructions:

- `showPiP` reads naturally in the UI ("PiP is on for this clip").
- `pipHidden` reads naturally in the compositor (`if !pipHidden,
  let webcam = … { draw }`), and `false` is the no-op default that
  matches the existing behavior.

Builders translate at the boundary: `pipHidden: !clip.showPiP`.

## Model layer (`VideoCoachCore`)

### `Project.swift` — `Preferences`

```swift
public struct Preferences: Codable, Hashable, Sendable {
    // … existing fields …
    public var pipForNewRecordings: Bool = true
    public init() {}
}
```

Add a custom `init(from decoder:)` so old project files (which lack
the field) decode with `pipForNewRecordings = true`. The existing
struct uses synthesized Codable; the custom init replaces it for this
struct only.

```swift
public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.scanVolume                = try c.decodeIfPresent(Double.self, forKey: .scanVolume) ?? 1.0
    self.previewSourceVolume       = try c.decodeIfPresent(Double.self, forKey: .previewSourceVolume) ?? 1.0
    self.previewCommentaryVolume   = try c.decodeIfPresent(Double.self, forKey: .previewCommentaryVolume) ?? 1.0
    self.lastExportResolution      = try c.decodeIfPresent(Resolution.self, forKey: .lastExportResolution) ?? .r1080
    self.lastExportQuality         = try c.decodeIfPresent(Quality.self, forKey: .lastExportQuality) ?? .medium
    self.preferredCameraID         = try c.decodeIfPresent(String.self, forKey: .preferredCameraID)
    self.preferredMicID            = try c.decodeIfPresent(String.self, forKey: .preferredMicID)
    self.pipForNewRecordings       = try c.decodeIfPresent(Bool.self, forKey: .pipForNewRecordings) ?? true
}
```

`CodingKeys` is synthesized — listing it explicitly isn't required.
`encode(to:)` stays synthesized.

### `Project.swift` — `Clip`

```swift
public struct Clip: Codable, Hashable, Identifiable, Sendable {
    // … existing fields …
    public var showPiP: Bool

    public init(
        // … existing parameters …
        showPiP: Bool = true,
        // … remaining parameters …
    ) {
        // … existing assignments …
        self.showPiP = showPiP
        // … remaining assignments …
    }
}
```

Same `init(from decoder:)` pattern as `Preferences`: every existing
field uses `decodeIfPresent` with the same default it already has in
the memberwise initializer, plus `showPiP` defaulting to `true`.

**No `formatVersion` bump.** The change is purely additive and
forward-compatible; old code reading a new file would simply ignore
the new key, and new code reading an old file gets `showPiP = true`,
which is exactly the historical behavior.

### `PreviewInstruction.swift`

```swift
public final class PreviewInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    // … existing fields …
    public var pipHidden: Bool = false

    public init(
        timeRange: CMTimeRange,
        // … existing parameters …
        webcamTrackID: CMPersistentTrackID = 1000,
        pipHidden: Bool = false,
        // … remaining parameters …
    ) {
        // … existing assignments …
        self.pipHidden = pipHidden
    }

    public func encode(with coder: NSCoder) {
        // … existing encodes …
        coder.encode(pipHidden, forKey: "pipHidden")
    }

    public init?(coder: NSCoder) {
        // … existing decodes …
        // decodeBool returns false when the key is absent — exactly our default.
        self.pipHidden = coder.decodeBool(forKey: "pipHidden")
        super.init()
    }
}
```

`NSCoder.decodeBool(forKey:)` returns `false` for an absent key, which
matches the default — no version probe needed.

### `CompilationInstruction.swift`

Identical change to `PreviewInstruction`: add `pipHidden: Bool = false`,
extend `init`, encode/decode through `NSCoder`.

### `PreviewCompositor.swift`

```swift
// Current code:
if let webcam = request.sourceFrame(byTrackID: webcamTrackID) { … }

// New code:
if !pipHidden, let webcam = request.sourceFrame(byTrackID: webcamTrackID) { … }
```

`pipHidden` is read from the resolved `PreviewInstruction` at the top
of `render(_:)`, mirroring how `webcamTrackID` is already pulled.

### `CompilationCompositor.swift`

Identical change. Pull `pipHidden` from the resolved
`CompilationInstruction` and add it to the same guard. The
text-bar / strokes / zoom layers are untouched.

## Builder layer (`VideoCoachCore` + app)

### `ClipPreviewBuilder.swift`

```swift
let inst = PreviewInstruction(
    timeRange: …,
    // … existing fields …
    webcamTrackID: actualWebcamID,
    pipHidden: !clip.showPiP,
    // … remaining fields …
)
```

The webcam video track and webcam audio track are still added to the
composition unchanged. The mic audio mix is unaffected.

### `CompilationExporter.swift`

```swift
let inst = CompilationInstruction(
    timeRange: …,
    // … existing fields …
    webcamTrackID: webcamID,
    pipHidden: !clip.showPiP,
    // … remaining fields …
)
```

`clip` here is the same `Clip` already in scope per export entry.

## App layer

### `apple/App/Views/TransportBar.swift`

A small shared subview rendered in both `ScanningTransport` and
`RecordingTransport`:

```swift
private struct PiPToggle: View {
    @Bindable var workspace: Workspace
    var body: some View {
        Toggle(isOn: Binding(
            get: { workspace.project.preferences.pipForNewRecordings },
            set: { newValue in
                workspace.project.preferences.pipForNewRecordings = newValue
                try? workspace.saveProject()
            }
        )) {
            Text("PiP")
        }
        .toggleStyle(.checkbox)
        .help("Show webcam picture-in-picture on new clips")
        .disabled(workspace.folder == nil)
    }
}
```

Placed at the right end of the transport bar in both modes, next to
the existing volume control. Each transport view inserts
`PiPToggle(workspace: workspace)` at that spot. The toggle stays
enabled during recording — flipping mid-recording is supported, and
the value is sampled at stop.

### `apple/App/ContentView.swift` — `stopRecording`

Where the new `Clip` is constructed (current code at the top of the
file, ~line 979), pass the current preference through:

```swift
let clip = Clip(
    id: pending.clipID,
    name: …,
    sourceIndex: pending.sourceIndex,
    startSourceSeconds: pending.startSourceSeconds,
    recordingDuration: duration,
    recordingFilename: pending.filename,
    events: events,
    sortIndex: count,
    showPiP: workspace.project.preferences.pipForNewRecordings
)
```

Read **at the call site**, inside the `MainActor.run` block — that is
the stop-time sample point.

### `apple/App/Views/ClipInspector.swift` — `EditorView`

Add a per-clip toggle between Tags and Notes, using the same
focus-snapshot / `commitClipEdit` pattern as the other fields. Toggles
don't have focus, so the snapshot is taken at click time:

```swift
Group {
    Text("PiP").font(.caption).foregroundStyle(.secondary)
    Toggle("Show picture-in-picture", isOn: Binding(
        get: { clip.showPiP },
        set: { newValue in
            let before = clip
            clip.showPiP = newValue
            workspace.commitClipEdit(id: clip.id, before: before, after: clip)
            try? workspace.saveProject()
            workspace.invalidatePreviewCache(for: clip.id)
        }
    ))
    .toggleStyle(.checkbox)
}
```

`commitClipEdit` pushes one undo step per toggle — matches the
existing "blur/Enter on a field is one step" rule.

`invalidatePreviewCache` ensures the next call to
`workspace.previewPlayer(for: id)` rebuilds the `AVPlayerItem` with
the new instruction.

### Live-refresh while previewing

If the user toggles `showPiP` while the clip is currently shown in
preview mode (`appMode == .previewClip(id)`), the on-screen
`AVPlayer` is the **old** instance — invalidating the cache doesn't
swap it. ContentView handles this:

```swift
.onChange(of: clip.showPiP) { _, _ in
    if case .previewClip(let id) = appMode, id == clip.id {
        // Re-enter preview to pick up the rebuilt player.
        selectedClipID = nil
        DispatchQueue.main.async { selectedClipID = id }
    }
}
```

The clear-and-reselect pattern reuses the existing
`handleSelectionChange` machinery; no new "force rebuild" API on
`Workspace`.

## Migration

- Existing `project.json` files: `Preferences.pipForNewRecordings`
  decodes as `true`; every existing `Clip.showPiP` decodes as `true`.
  Behavior is byte-identical to before.
- No `formatVersion` bump — the change is purely additive. The custom
  `init(from:)` on `Clip` and `Preferences` is the entire compatibility
  surface.
- Old code reading a new file: the extra key is silently ignored by
  the synthesized decoder, and the in-memory `Clip` value is whatever
  the old code's default was (which was also "PiP shown").

## Testing

All tests live in `apple/VideoCoachCore/Tests/VideoCoachCoreTests/`
under the existing pixel-level / Codable test patterns. The hidden-PiP
behavior is testable end-to-end via `FiducialAsset` / `SplitColorAsset`
(red source, blue webcam): with `pipHidden = true`, the bottom-right
PiP region in the rendered output should be source-red rather than
webcam-blue.

### Codable round-trip

`ProjectTests.swift`:

- Encode a `Clip` with `showPiP = false`, decode, assert
  `decoded.showPiP == false`. (And same for `Preferences`.)
- Decode a JSON blob missing the new keys (using a fixture string),
  assert `showPiP == true` and `pipForNewRecordings == true`.
- Decode a JSON blob with `showPiP = false`, assert the field round-trips.

### Preview compositor

`PreviewCompositorTests.swift`:

- Build a `PreviewInstruction` with `pipHidden = false` against a
  two-track synthetic asset (red source, blue webcam). Render one
  frame. Sample a pixel in the PiP corner — expect blue.
- Same setup with `pipHidden = true` — sample the same corner —
  expect red.
- Sample a pixel **outside** the PiP corner — expect red in both cases
  (regression guard that the flag doesn't accidentally affect the
  base layer).

### Compilation compositor

`CompilationCompositorTests.swift`:

- Mirror of the preview tests with `CompilationInstruction`. Same
  red-source / blue-webcam fiducial setup, same three corner samples.

### End-to-end export

`CompilationExporterE2ETests.swift`:

- Export one clip with `showPiP = false`. Decode a single frame of
  the output `.mp4`. Sample the bottom-right corner — expect source
  pixels, not webcam pixels.
- The companion existing test that exports with the default
  (`showPiP = true`) already asserts the PiP draws — no need for a
  duplicate.

### Manual smoke (no automated coverage)

- Toggle global "PiP" in the scanning transport, record a clip → new
  clip's inspector shows the matching value.
- Toggle global mid-recording → the clip created at R-press picks up
  the toggle's value at stop, not start.
- Toggle the inspector "PiP" while previewing a clip → preview
  refreshes within ~1 frame to show / hide the PiP.
- Existing project file (created before this change) opens with all
  clips showing PiP and the global toggle defaulting to checked.
- Export a clip with the per-clip toggle off → output `.mp4` has no
  PiP in the bottom-right corner.

## Non-goals

- **No mid-clip toggling.** The flag is all-or-nothing per clip. The
  webcam is recorded continuously; we don't track when the toggle
  changed and replay the events.
- **No change to capture.** The recording pipeline always writes the
  `.mov` with both video and audio tracks regardless of the toggle.
  The "we may enable it later" path is purely a flag flip.
- **No UI for the global toggle inside the preview transport.**
  Preview mode is post-record; the global setting affects only future
  recordings.
- **No keyboard shortcut** for either toggle. Click-only.
- **No PiP-position / PiP-size controls** in this change — the
  toggle is binary. Future work can layer geometry on top of the
  existing `pipHidden`-style flag.
