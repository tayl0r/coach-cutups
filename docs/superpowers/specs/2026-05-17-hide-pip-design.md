# Hide the PiP video on a per-clip basis

## Goal

Let the user suppress the webcam picture-in-picture overlay on a
per-clip basis during preview and export. The webcam is still
**recorded** for every clip (file capture is unchanged); only the
playback- and export-side composite respects the flag, so a clip
can be flipped back later without re-recording.

Two surfaces:

- A **global** "PiP?" checkbox lives in the transport bar and seeds
  the per-clip flag on every new recording.
- A **per-clip** "PiP?" checkbox lives in the clip inspector and is
  the authoritative value the renderers read.

The global checkbox is **sampled at clip-stop** (when the user presses
R to end the recording), not at start. The user can flip it freely
mid-recording; whatever it reads at stop is what the new clip gets.

## Field map

| Layer | Name | Type | Default |
|---|---|---|---|
| `Preferences` | `pipForNewRecordings` | `Bool` | `true` |
| `Clip` | `showPiP` | `Bool` | `true` |
| `CompilationInstruction` | `showPiP` | `Bool` | `true` |

`PreviewInstruction` does **not** gain a field — see "Preview path"
below for why. No polarity inversion anywhere; every layer says
`showPiP` and `true` means "draw the PiP."

## Preview path (`ClipPreviewBuilder.swift`)

**Important:** the live preview path no longer uses
`PreviewCompositor`. As of the macOS 26 fix
(`ClipPreviewBuilder.swift:256-260`), `ClipPreviewBuilder` uses
AVFoundation's built-in compositor with explicit
`AVMutableVideoCompositionLayerInstruction`s — AVPlayer strips
`AVMutableVideoCompositionInstruction` subclasses on the playback
path, so a custom compositor would render black. The PiP is drawn
via the `webcamLayer` instruction on line 322-323.

The fix for hiding the PiP in preview is at the **builder**, not
the compositor. When `clip.showPiP == false`:

1. Omit `webcamLayer` from `inst.layerInstructions` (drop the
   `AVMutableVideoCompositionLayerInstruction` for the webcam track).
2. Pass only `actualSourceID` to `PreviewInstruction.make(...)`'s
   `webcamTrackID` parameter as `kCMPersistentTrackID_Invalid` (or
   drop the required-track from `_requiredSourceTrackIDs` by
   threading a new optional through `make`). Either way, AVPlayer
   doesn't need to vend webcam video frames.
3. Keep the webcam **video** track and webcam **audio** track in the
   `AVMutableComposition`. The video track being present but unused
   is a negligible cost; keeping the composition shape uniform
   simplifies the builder and the audio-mix path stays unchanged.

Concretely:

```swift
let inst: PreviewInstruction
if clip.showPiP {
    inst = PreviewInstruction.make(
        sourceTrackID: actualSourceID,
        webcamTrackID: actualWebcamID,
        compositionStart: .zero,
        clipDuration: clipDuration,
        segments: [],
        frozenFrames: [:],
        events: []
    )
    inst.layerInstructions = [webcamLayer, sourceLayer]
} else {
    inst = PreviewInstruction.make(
        sourceTrackID: actualSourceID,
        webcamTrackID: kCMPersistentTrackID_Invalid,
        compositionStart: .zero,
        clipDuration: clipDuration,
        segments: [],
        frozenFrames: [:],
        events: []
    )
    inst.layerInstructions = [sourceLayer]
}
```

`PreviewInstruction.make` is updated to accept
`kCMPersistentTrackID_Invalid` for `webcamTrackID` and produce a
`_requiredSourceTrackIDs` array that omits it when invalid:

```swift
let requiredIDs: [NSValue]
if webcamTrackID == kCMPersistentTrackID_Invalid {
    requiredIDs = [NSNumber(value: sourceTrackID)]
} else {
    requiredIDs = [
        NSNumber(value: sourceTrackID),
        NSNumber(value: webcamTrackID),
    ]
}
i._requiredSourceTrackIDs = requiredIDs
```

This change to `make` is small and the only callsite outside tests
is `ClipPreviewBuilder` itself.

## Export path (`CompilationExporter.swift`, `CompilationCompositor.swift`)

Unlike preview, **export still uses the custom compositor**
(`CompilationCompositor`). The flag rides on `CompilationInstruction`
as a plain stored property — same pattern as every other field on
that class. No `NSCoding` additions; the existing classes do not
implement `encode(with:)/init?(coder:)` because they are constructed
fresh by the builder on every use.

### `CompilationInstruction.swift`

Add one stored property and one parameter to `make`:

```swift
public final class CompilationInstruction: AVMutableVideoCompositionInstruction, @unchecked Sendable {
    // … existing fields …
    public var showPiP: Bool = true

    public static func make(
        // … existing parameters …
        webcamTrackID: CMPersistentTrackID,
        showPiP: Bool = true,
        // … remaining parameters …
    ) -> CompilationInstruction {
        // … existing setup …
        i.showPiP = showPiP
        return i
    }
}
```

### `CompilationCompositor.swift`

Resolve `showPiP` at the top of `startRequest(_:)` alongside the
existing `webcamTrackID` resolve, and add it to the PiP-draw guard:

```swift
let showPiP: Bool
if let inst = request.videoCompositionInstruction as? CompilationInstruction {
    showPiP = inst.showPiP
    // … existing webcamTrackID resolution …
} else {
    showPiP = true  // legacy/sentinel path — preserve existing behavior
}

// … later, where the PiP is drawn:
if showPiP, let webcam {
    // … existing PiP draw block, unchanged …
}
```

The text bar, strokes, base-layer zoom, and audio paths are untouched.

### `CompilationExporter.swift`

Where each `CompilationInstruction.make(...)` is called, pass
`showPiP: clip.showPiP`:

```swift
let inst = CompilationInstruction.make(
    // … existing arguments …
    webcamTrackID: webcamID,
    showPiP: clip.showPiP,
    // … remaining arguments …
)
```

Webcam tracks and the mic audio mix are inserted unconditionally —
no change to the asset graph.

## Model layer (`VideoCoachCore/Project.swift`)

Two additive fields. Both keep synthesized `Codable`. Compatibility
is handled at the JSON-blob level by `ProjectStore.read`'s migrator —
see "Migration" below.

### `Preferences`

```swift
public struct Preferences: Codable, Hashable, Sendable {
    // … existing fields …
    public var pipForNewRecordings: Bool = true
    public init() {}
}
```

### `Clip`

```swift
public struct Clip: Codable, Hashable, Identifiable, Sendable {
    // … existing fields …
    public var showPiP: Bool

    public init(
        // … existing parameters …
        showPiP: Bool = true,
        sortIndex: Int,
        createdAt: Date = .init()
    ) {
        // … existing assignments …
        self.showPiP = showPiP
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }
}
```

No custom `init(from:)` on either struct. Synthesized Codable
remains the long-term path for `Clip` so future field additions
don't have to remember to update a hand-rolled decoder — the failure
mode of a forgotten `decodeIfPresent` is **silent** (the new field
decodes as zero/false), whereas a forgotten migrator throws **loud**
(`.keyNotFound`) the moment someone opens a pre-migration project.

## Migration (`VideoCoachCore/ProjectStore.swift`)

Bump `Project.formatVersion = 3`. Add a JSON-blob migrator that runs
before `JSONDecoder.decode(Project.self)`: for any file with
`formatVersion < 3`, inject the two new keys with their default
values, then bump the in-data `formatVersion` to 3. The decoder
then sees a well-formed v3 document and synthesized Codable does the
rest.

```swift
public static func read(from folder: URL) throws -> Project {
    let url = folder.appendingPathComponent(projectFileName)
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw ProjectStoreError.missingProjectJSON
    }
    let data = try Data(contentsOf: url)
    let migratedData = try migrateIfNeeded(data)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let project = try decoder.decode(Project.self, from: migratedData)
    if project.formatVersion < 1 || project.formatVersion > 3 {
        throw ProjectStoreError.unsupportedFormatVersion(project.formatVersion)
    }
    return project
}

/// Project file format migrator. Each `vN → v(N+1)` step is a small
/// in-blob patch — keeps `Project` / `Clip` / `Preferences` on
/// synthesized Codable.
private static func migrateIfNeeded(_ data: Data) throws -> Data {
    guard var root = try JSONSerialization.jsonObject(
        with: data, options: []) as? [String: Any]
    else { return data }
    let version = (root["formatVersion"] as? Int) ?? 1

    if version < 3 {
        // v1 / v2 → v3: add Clip.showPiP and
        // Preferences.pipForNewRecordings (both default true).
        if var prefs = root["preferences"] as? [String: Any] {
            if prefs["pipForNewRecordings"] == nil {
                prefs["pipForNewRecordings"] = true
                root["preferences"] = prefs
            }
        }
        if var clips = root["clips"] as? [[String: Any]] {
            for i in clips.indices where clips[i]["showPiP"] == nil {
                clips[i]["showPiP"] = true
            }
            root["clips"] = clips
        }
        root["formatVersion"] = 3
    }

    return try JSONSerialization.data(withJSONObject: root, options: [])
}
```

The migrator is the single point future schema changes must touch.
The existing `formatVersion` guard then accepts the migrated blob.

## App layer

### `apple/App/Views/TransportBar.swift`

A small private subview rendered in both `ScanningTransport` and
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

Each transport view inserts `PiPToggle(workspace: workspace)` at its
right end. One struct, two instantiation sites — no duplication.
The toggle stays enabled during recording; the value is sampled at
stop.

### `apple/App/ContentView.swift` — `stopRecording`

Where the new `Clip` is constructed (current code at ~line 979),
read the preference and pass it through. The read happens inside the
`MainActor.run` block — that block IS the stop-time sample point
(both the toggle write and the read are main-actor-isolated, so the
last write before this read is the value used):

```swift
let clip = Clip(
    id: pending.clipID,
    name: …,
    sourceIndex: pending.sourceIndex,
    startSourceSeconds: pending.startSourceSeconds,
    recordingDuration: duration,
    recordingFilename: pending.filename,
    events: events,
    showPiP: workspace.project.preferences.pipForNewRecordings,
    sortIndex: count
)
```

### `apple/App/Views/ClipInspector.swift` — `EditorView`

Add a per-clip toggle between Tags and Notes, going through the
existing `commitClipEdit` undo machinery. Toggles have no focus
session, so the before-snapshot is taken at click time:

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
existing "one step per discrete edit" rule (e.g. one step per
focus-session for text fields; a toggle's session is one click).

`invalidatePreviewCache` drops the cached `AVPlayer` so the next
`previewPlayer(for:)` call rebuilds with the new layer-instructions
set.

### Live-refresh while previewing

If the user toggles `showPiP` while `appMode == .previewClip(id)`,
the on-screen `AVPlayer` is the old instance — invalidating the
cache doesn't swap it. `ContentView` handles this by re-entering
preview (clear-and-reselect), which routes through the existing
`handleSelectionChange` path:

```swift
.onChange(of: clip.showPiP) { _, _ in
    if case .previewClip(let id) = appMode, id == clip.id {
        selectedClipID = nil
        DispatchQueue.main.async { selectedClipID = id }
    }
}
```

This is localized to the one site where the behavior matters. The
existing undo-while-previewing asymmetry (an undo of a clip edit
invalidates the cache without refreshing the on-screen player) is
pre-existing and out of scope.

## Testing

### Codable + migration

`ProjectTests.swift`:

- `test_newProjectWritesV3`: a fresh `Project()` encoded then decoded
  comes back with `formatVersion == 3`, every `Clip.showPiP == true`,
  and `preferences.pipForNewRecordings == true`.
- `test_v3RoundtripWithShowPiPFalse`: a `Clip` with `showPiP = false`
  and `Preferences.pipForNewRecordings = false` round-trips through
  JSON.

`ProjectStoreTests.swift`:

- `test_migrateV1ToV3`: write a hand-rolled v1 JSON blob to disk
  (no `showPiP`, no `pipForNewRecordings`, no `.zoom` events).
  `ProjectStore.read` returns a `Project` with `formatVersion == 3`,
  all clips' `showPiP == true`, and `preferences.pipForNewRecordings
  == true`. (Re-uses the legacy-JSON fixture pattern from
  `test_preferencesDeviceIDs_decodeFromLegacyJSONMissingKeys`.)
- `test_migrateV2ToV3`: same, starting from v2.
- `test_rejectsV4`: a JSON blob with `formatVersion = 4` still
  throws `unsupportedFormatVersion`.

### Compilation compositor

`CompilationCompositorTests.swift` (mirror of the existing
`test_compositesSourceAndWebcamPiP` pattern):

- `test_compositesSourceAndWebcamPiP_withShowPiP` (rename / keep
  existing): solid-color two-track asset (green source, red
  webcam), `showPiP: true`. Sample bottom-right corner — expect red.
- `test_omitsWebcamWhenShowPiPFalse`: same setup with
  `showPiP: false`. Sample bottom-right corner — expect green.
  Sample center — expect green (regression guard: the flag doesn't
  affect the base layer).

### End-to-end export

`CompilationExporterE2ETests.swift`:

- `test_exportsWithoutPiPWhenShowPiPFalse`: export a clip with
  `showPiP = false`. Decode a single frame of the output `.mp4`.
  Sample the bottom-right corner — expect source pixels, not
  webcam pixels.

### Preview builder (new file)

`ClipPreviewBuilderTests.swift` doesn't exist yet; this is the right
moment to add it. (The existing `Preview*` tests live in the
core-package test target and use `AVAssetExportSession` for
deterministic frame sampling; a tiny builder-output test fits there
without bringing the app target's playback path into core tests.)

- `test_buildsTwoLayerInstructionsWhenShowPiP`: build a preview item
  for a clip with `showPiP = true`. Assert the
  `videoComposition.instructions[0].layerInstructions.count == 2`.
- `test_buildsOneLayerInstructionWhenShowPiPFalse`: build for a clip
  with `showPiP = false`. Assert `layerInstructions.count == 1`.
  Assert `requiredSourceTrackIDs` doesn't include the webcam track.

(These tests need a real .mov for both source and webcam — reuse
the existing `SyntheticAsset` writer pattern.)

### Manual smoke (no automated coverage)

- Toggle global "PiP" in the scanning transport, record a clip → new
  clip's inspector shows the matching value.
- Toggle global mid-recording → the clip created at R-press picks up
  the toggle's value at stop, not start.
- Toggle the inspector "PiP" while previewing a clip → preview
  refreshes within ~1 frame to show / hide the PiP.
- Existing project file (v1 or v2, created before this change) opens
  with all clips showing PiP, the global toggle checked, and after
  any subsequent save the file's `formatVersion` is `3`.
- Export a clip with the per-clip toggle off → output `.mp4` has no
  PiP in the bottom-right corner.

## Non-goals

- **No mid-clip toggling.** The flag is all-or-nothing per clip.
  The webcam is recorded continuously; we don't track when the
  toggle changed and replay the events.
- **No change to capture.** The recording pipeline always writes
  the `.mov` with both video and audio tracks regardless of the
  toggle. Future "re-enable PiP on an old clip" is purely a flag
  flip.
- **No UI for the global toggle inside the preview transport.**
  Preview mode is post-record; the global setting affects only
  future recordings.
- **No keyboard shortcut** for either toggle. Click-only.
- **No PiP-position / PiP-size controls** in this change.
- **No fix for the pre-existing undo-while-previewing asymmetry.**
  Undoing a clip edit invalidates the preview cache without
  refreshing the on-screen player; the new `showPiP` toggle gets a
  localized `.onChange` refresh but the broader fix is out of scope.
- **No revival of `PreviewCompositor` for live playback.** The
  custom compositor is currently dead in the production preview
  path (kept alive for export-session-based tests). The hide-PiP
  feature does not depend on it and does not change that status.
