# Rust Rewrite — Phase 11 Plan #3: HEVC Encoder

Branch: `rust-rewrite`. Phase 11 is Polish + deferred items from Phase 10's
closeout. This plan adds HEVC (H.265) as a selectable output codec
alongside Phase 10's H.264 default. Per-platform hardware encoder picker
(`vtenc_h265` macOS / `mfh265enc` Windows / `vaapih265enc` Linux HW /
`x265enc` SW fallback). New Codec radio-button row in the export sheet's
Form view, persisted as `last_export_codec` mirroring
`last_export_resolution` / `_quality`. Default = H.264 (no behavior
change for users who don't touch the new control).

---

## Goal (one paragraph)

Phase 10 ships H.264-only export via `pick_h264_encoder` in
`crates/video-coach-media/src/export.rs:384`. v1 of the app supported
HEVC for ~30-40% smaller files at similar visual quality, and several
adversarial-review fixes were already designed to be codec-agnostic
(fix #28 video-output chain shape; fix #34 ExportRunOutcome shape).
Plan #3 adds a `Codec { H264, Hevc }` enum to
`video-coach-core::project`, threads it through `Command::ExportCompilations`
end-to-end, adds a `pick_h265_encoder` mirroring the existing H.264
picker with HEVC factories in priority order, switches the post-encoder
parser between `h264parse` / `h265parse` based on codec, extends
`bitrate(resolution, quality)` → `bitrate(resolution, quality, codec)`
returning ~60% of H.264 values for HEVC, persists `last_export_codec`
alongside the existing two preferences, and adds a Codec radio-button
row to the Slint Form view. Default is H.264; an absent
`last_export_codec` field in an existing v2 project.json deserializes
as H.264 via `#[serde(default)]`.

---

## What Phase 11 Plan #3 deliberately does NOT include

1. **Hardware encoder feature detection / capability probe.** We use the
   same try-elements-in-priority-order pattern as `pick_h264_encoder`.
   If `vtenc_h265` isn't available on a particular macOS box (rare;
   Apple silicon supports it back to M1), we fall through to `x265enc`.
   The picker logs `export.encoder_picked` with the chosen factory so
   regressions are visible in the structured log.
2. **`mp4mux` fallback if `qtmux` rejects HEVC.** `qtmux` accepts both
   H.264 and HEVC byte-streams from `h264parse` / `h265parse`
   (verified — `qtmux` advertises `video/x-h265` on its sink template
   in stock GStreamer 1.20+). If a CI matrix entry surfaces a real
   `qtmux` rejection, we'll add a muxer dispatch in a follow-up; not
   in scope for Plan #3.
3. **HEVC-specific bitrate-property name handling.** `try_set_encoder_bitrate`
   already looks up the `bitrate` property by name and adapts to the
   ParamSpec value type (u32/i32/u64). All four HEVC encoder candidates
   we list (`vtenc_h265`, `mfh265enc`, `vaapih265enc`, `x265enc`)
   advertise a property literally named `bitrate`; the existing helper
   handles them with one unit-conversion table extension (vtenc_h265 is
   bps like vtenc_h264; the rest are kbps).
4. **HEVC profile / 10-bit / Main10 selection.** Hardcoded to default
   (8-bit Main profile). Encoder-specific profile flags are out of
   scope; `x265enc` with no profile property set defaults to Main and
   that's what we want.
5. **Re-encoding existing exports.** Plan #3 only adds the codec choice
   for new exports. The output filename pattern is unchanged (still
   `<project>_<tag>.mp4`); a user who exports the same tag twice with
   different codecs overwrites the prior file (existing Phase 10
   behavior, no regression).
6. **Container extension change.** Output files keep the `.mp4`
   extension regardless of codec. HEVC-in-MP4 is a standard combo;
   no container-vs-codec mismatch.
7. **Default codec change.** Default stays H.264. Users who never
   touch the control export H.264 exactly like Phase 10. The new
   field's `Default` impl returns `Codec::H264`.

---

## Required reading (sub-agent does this BEFORE coding)

1. This plan top-to-bottom; especially the per-task sections below and
   the "Adversarial-review fixes baked in" section.
2. `docs/plans/2026-05-01-rust-rewrite-phase-10-export-sheet.md`'s
   "Adversarial-review fixes baked in" section (40 fixes), in
   particular fix #11 (`last_export_*` persisted-on-Export pattern,
   fail-soft if persistence write fails), fix #28 (the video-output
   chain shape — `appsrc → videoconvert → videoscale → capsfilter
   → encoder → parser → qtmux → filesink`; codec swap is encoder +
   parser only), fix #33 (typed enum vs string for tag selection — we
   mirror this pattern for `Codec`), fix #34 (ExportRunOutcome shape).
3. `crates/video-coach-media/src/export.rs:384-409` —
   `pick_h264_encoder` is the exact template `pick_h265_encoder` will
   mirror.
4. `crates/video-coach-media/src/export.rs:411-430` —
   `try_set_encoder_bitrate` is shared across both codec families;
   only the bps-vs-kbps table needs an HEVC entry.
5. `crates/video-coach-media/src/export.rs:831-907` —
   `build_video_output_chain`. The change is: take a `codec: Codec`
   param, dispatch encoder via `pick_h264_encoder` /
   `pick_h265_encoder`, swap `h264parse` / `h265parse`. Everything
   else (videoscale, capsfilter NV12, qtmux, filesink) stays.
6. `crates/video-coach-media/src/export.rs:113-150` — `ExportInputs`
   + `export_compilation`'s top-level signature. Plan #3 adds a
   `codec: Codec` parameter (positional, between `quality` and the
   first `_volume` param).
7. `crates/video-coach-media/src/export.rs:239-247` —
   `build_video_output_chain` call site. The bitrate call gains a
   `codec` arg.
8. `crates/video-coach-core/src/export_settings.rs:9-19` — `bitrate`
   table. Plan #3 changes the signature to
   `bitrate(resolution: Resolution, quality: Quality, codec: Codec)`
   and folds in HEVC entries.
9. `crates/video-coach-core/src/project.rs:6-46` — `Resolution`,
   `Quality`, `Preferences`. Plan #3 adds `Codec` enum next to them
   and `last_export_codec` field on `Preferences`.
10. `crates/video-coach-app/src/bus.rs:115-131` —
    `Command::ExportCompilations` shape. Plan #3 adds a
    `codec: Codec` field.
11. `crates/video-coach-app/src/bus.rs:2057-2080` — dispatch arm.
    Codec gets unpacked + threaded into `handle_export_compilations`.
12. `crates/video-coach-app/src/bus.rs:2144-2270` —
    `handle_export_compilations`. Plan #3 adds a `codec: Codec`
    parameter, persists it alongside resolution/quality at fix #11's
    persistence step (line ~2256).
13. `crates/video-coach-app/ui/main.slint:108-167` — root window's
    in-out properties + callbacks for the export sheet.
    `export-resolution` / `export-quality` are the patterns to
    mirror for `export-codec`.
14. `crates/video-coach-app/ui/main.slint:1132-1213` — Quality picker
    row block (label `Text` at y:366px, three radio
    `Rectangle`-with-`TouchArea` buttons at y:388px). The Codec row
    will sit BELOW Quality at y:430-470px range, two buttons (H.264
    / HEVC) instead of three.
15. `crates/video-coach-app/src/ui.rs:791-882` — Slint callback
    bindings for Resolution / Quality / Start. Plan #3 adds a third
    callback binding for `on_export_codec_changed` and a
    `Codec` parser at the start of `on_export_start_clicked` (parses
    "h264" / "hevc" → `Codec::H264` / `Codec::Hevc`).

---

## Adversarial-review fixes baked in

NET-NEW for Plan #3 (HEVC-specific GStreamer/Slint pitfalls). Phase 10's
40 fixes are NOT re-raised. 8 actionable fixes from the 9-finding pass
on `/tmp/phase11-plans/plan-3/adv-review.md`.

### 1. `pick_h265_encoder` candidate-list `make_or` warnings are intentional (F1, doc-clarification)

On lavapipe Linux CI, `vaapih265enc` and `nvh265enc` will both fail
`make_or` (no `/dev/dri`, no NVENC lib) before falling through to
`x265enc`. Each failure logs a `gst-plugin-loader` warning identical
to the H.264 path's tolerated warnings. **Bake in**: `pick_h265_encoder`
gets a docstring noting "`make_or` failures for unavailable factories
are non-fatal and intentional; lavapipe/CI Linux runners will see
warnings for `vaapih265enc` + `nvh265enc` before falling through to
`x265enc`, mirroring `pick_h264_encoder`'s behavior." (Task 1.)

### 2. macOS HEVC factory candidate list must include `vtenc_h265_hw` first (F2, real high)

Stock `brew install gstreamer` (1.22+) registers VideoToolbox HEVC
under `vtenc_h265_hw` for the hardware variant and `vtenc_h265` for
the software fallback. The plan's prior candidate list of
`"vtenc_h265"` first would silently pick the SW path on Apple Silicon
(M1+), defeating the HW picker; the smoke test still passes (output
is valid HEVC, just CPU-encoded). **Bake in**: `pick_h265_encoder`
candidate list becomes
`["vtenc_h265_hw", "vtenc_h265", "mfh265enc", "vaapih265enc", "nvh265enc", "x265enc"]`.
`make_or("vtenc_h265_hw")` failure on a non-HW box is non-fatal —
the loop continues. (Task 1.)

### 3. `try_set_encoder_bitrate` bps-vs-kbps match must use `starts_with("vtenc_")` (F3, real high)

The existing helper at `export.rs:418-421` matches encoder name
against literal `"vtenc_h264"`. Adding a `"vtenc_h264" | "vtenc_h265"`
arm still fails to catch `vtenc_h265_hw` (per fix #2 above) — the
fallback `target_bps / 1000` would set 3,600 bps when we wanted
3.6 Mbps, producing a corrupt sub-1 KB output. The smoke test as
drafted only asserts "non-empty," which a 1 KB file passes. **Bake in**:
replace the match with prefix-based dispatch:

```rust
let primary = if encoder_name.starts_with("vtenc_") {
    target_bps                 // VideoToolbox: bps
} else {
    target_bps / 1000          // everything else: kbps
};
```

And tighten the smoke-test size assertion from "non-empty" to
`> 50_000` bytes (a 1.2 s clip at 3.6 Mbps is ~540 KB; even at lowest
quality it's >> 50 KB; a kbps-vs-bps mis-encode is < 1 KB). (Task 1.)

### 4. `qtmux` HEVC requires explicit `stream-format=hvc1,alignment=au` capsfilter between `h265parse` and `qtmux` (F4, real high)

`qtmux` requires AVCC/HVCC stream-format for MP4 (not byte-stream).
`h264parse` auto-converts because qtmux's H.264 sink-pad caps
include `stream-format=avc` and h264parse honors the request.
**`h265parse` is the same shape**, but on some GStreamer 1.20 builds
the default emit is `stream-format=byte-stream, alignment=nal` which
qtmux rejects with `could not link h265parse to qtmux`. The plan's
prior claim that this "works" was optimistic. **Bake in**: Task 1's
chain build inserts an explicit caps filter for the HEVC path only:

```rust
let parser_caps_str = match codec {
    Codec::H264 => None,
    Codec::Hevc => Some("video/x-h265,stream-format=hvc1,alignment=au"),
};
// linked as: encoder → parser → (capsfilter when Hevc) → qtmux
```

H.264 path keeps the existing chain unchanged (5 LOC delta). Note:
"Done criteria" already asserts `video/x-h265` Discoverer caps —
this filter ensures the muxer-link step succeeds first. The "Known
unknowns #4" deferred-to-fixup note is removed. (Task 1.)

### 5. Workspace-wide `bitrate(...)` call-site grep gate before merging Task 0 (F5, defensive)

The plan instructs Task 0 to update `export.rs:246` only and asserts
`compose.rs` doesn't call `bitrate(...)`. Defensive gate: if a
parallel Phase 11 plan lands a new `bitrate(...)` caller before
Plan #3, Task 0 silently breaks compile. **Bake in**: Task 0
acceptance step 1 becomes:

```
rg 'bitrate\(' crates/ | grep -v 'fn bitrate'
```

The output must contain ONLY `crates/video-coach-media/src/export.rs:246`
plus the Task 0 unit-test call sites in `export_settings.rs`. Any
unexpected hit blocks the task; the plan grows a per-call-site
codec passthrough. (Task 0.)

### 6. `ui.rs` codec-string parser must warn-and-fall-back-to-prefs on unknown values (F6, real UX)

The drafted parser silently downgrades any non-`"hevc"` string to
`Codec::H264`. A typo, a future codec rename, or a callback-vs-click
race lets a user export H.264 while expecting HEVC, with no log
trace. **Bake in** in Task 2's `on_export_start_clicked`:

```rust
let codec = match w.get_export_codec().as_str() {
    "h264" => Codec::H264,
    "hevc" => Codec::Hevc,
    other => {
        tracing::warn!(
            target: "export.lifecycle",
            event = "export.codec_string_unknown",
            value = other,
            "falling back to last_export_codec"
        );
        prefs.last_export_codec
    }
};
```

`prefs` is read from the project's existing preferences accessor
(same path the resolution/quality hydration uses). (Task 2.)
Phase 10's resolution/quality parsers may want the same treatment;
out of scope for Plan #3, flagged in deviations.

### 7. HEVC smoke-test caps assertion tightens to `starts_with("video/x-h265")` (F7, test tightening)

Discoverer's caps string for HEVC over MP4 starts with
`"video/x-h265, stream-format=(string)hvc1, ..., profile=(string)main, ..."`.
Substring match on `"hevc"` passes none of the standard caps strings
(GStreamer uses `x-h265` exclusively); `"h265"` substring would
match `"video/x-h265"` but also a malformed `"video/x-h265-fragment"`.
**Bake in**: smoke-test assertion is exact-prefix:

```rust
let caps_str = video_stream.caps().expect("caps").to_string();
assert!(
    caps_str.starts_with("video/x-h265"),
    "expected HEVC output, got caps: {caps_str}"
);
```

This also catches a regression where the picker silently falls back
to an H.264 encoder (caps would be `"video/x-h264, ..."`). (Task 1.)

### 8. Sheet-open hydration of `export-codec` from `Preferences::last_export_codec` is mandatory, not conditional (F8, real UX)

Slint properties reset to their declared default
(`export-codec: "h264"`) on each component instantiation. Whether
the export-sheet modal is destroyed-and-rebuilt or merely shown/hidden
depends on Slint's internal model — assume destroyed. The Phase 10
"persisted on Export click" pattern (fix #11) is necessary but
**not sufficient** without an on-open hydration: a user exports HEVC,
closes the sheet, reopens, and the property is back to `"h264"`. The
plan's prior "if any such hydration exists for resolution/quality"
hedge is removed. **Bake in** in Task 2:

- Find the sheet-open trigger (the bus arm or ui.rs handler that
  shows the export sheet modal).
- Set ALL THREE properties from `Preferences` before showing:
  `export-resolution`, `export-quality`, `export-codec`. If
  resolution/quality hydration was missing, ADD IT in Task 2 (small
  scope expansion, ~6 LOC).
- New bus integration test:
  `opening_export_sheet_hydrates_codec_from_preferences` constructs
  a project with `last_export_codec: Hevc`, fires the sheet-open
  command, asserts the Slint property reads `"hevc"`. (Task 2.)

### Rejected findings

- **F9 (HEVC bitrate table integer-kbps division for R720, SPECULATIVE→non-issue)**: Adversarial reviewer worked through `base_1080 / 2` for all three HEVC qualities (Low → 1,800 kbps; Medium → 3,600 kbps; High → 7,200 kbps). All clean integer kbps. No bug; logged here as evidence the integer-division path was checked.

---

## Tasks

### Task 0: `Codec` enum + bitrate table extension + `Preferences` field

Crate: `video-coach-core` only. ~80 LOC. Pure-data refactor.

**Add to `crates/video-coach-core/src/project.rs`** next to `Quality`:

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum Codec {
    #[default]
    H264,
    Hevc,
}
```

Why `#[derive(Default)]` with `#[default]` on `H264`: an existing v2
project.json (post-Phase 10, pre-Plan #3) will not contain a
`lastExportCodec` field. Combined with `#[serde(default)]` on the
`Preferences::last_export_codec` field below, this makes Plan #3
backwards-compatible — old projects load and behave exactly as
before, defaulting to H.264 on the next export.

**Extend `Preferences`**:

```rust
pub struct Preferences {
    pub scan_volume: f64,
    pub preview_source_volume: f64,
    pub preview_commentary_volume: f64,
    pub last_export_resolution: Resolution,
    pub last_export_quality: Quality,
    #[serde(default)]
    pub last_export_codec: Codec,
    pub preferred_camera_id: Option<String>,
    pub preferred_mic_id: Option<String>,
}
```

And add `last_export_codec: Codec::H264` to the `Default` impl.

**Extend `crates/video-coach-core/src/export_settings.rs::bitrate`**
to take `codec: Codec`:

```rust
pub fn bitrate(resolution: Resolution, quality: Quality, codec: Codec) -> u32 {
    let base_1080 = match (codec, quality) {
        (Codec::H264, Quality::Low)    =>  6_000_000,
        (Codec::H264, Quality::Medium) => 12_000_000,
        (Codec::H264, Quality::High)   => 24_000_000,
        // HEVC ≈ 60% of H.264 for similar perceptual quality.
        (Codec::Hevc, Quality::Low)    =>  3_600_000,
        (Codec::Hevc, Quality::Medium) =>  7_200_000,
        (Codec::Hevc, Quality::High)   => 14_400_000,
    };
    match resolution {
        Resolution::Source | Resolution::R1080 => base_1080,
        Resolution::R720 => base_1080 / 2,
    }
}
```

`Codec` is imported in `export_settings.rs` from
`crate::project::Codec`.

**Update existing call sites** of `bitrate(...)` in
`crates/video-coach-media/src/export.rs:246` to pass
`Codec::H264` (Task 0 only — Task 1 will route the real codec
through). `crates/video-coach-media/src/compose.rs` does NOT call
`bitrate(...)` (Phase 5 compose hardcodes the encoder picker without
the bitrate helper); leave it alone.

**Verification gate (per fix #5)**: before committing Task 0, run

```
rg 'bitrate\(' crates/ | grep -v 'fn bitrate'
```

Expected hits ONLY: `crates/video-coach-media/src/export.rs:246` and
the Task 0 test call sites in
`crates/video-coach-core/src/export_settings.rs`. Any unexpected hit
blocks the task and the plan grows an additional codec-passthrough
patch for that caller.

**Tests**:

- Extend `bitrate_for_resolution_and_quality` in
  `crates/video-coach-core/src/export_settings.rs::tests` to assert
  HEVC values: `bitrate(R1080, Medium, Hevc) == 7_200_000`,
  `bitrate(R720, High, Hevc) == 7_200_000` (half of 14.4 Mbps),
  etc.
- Add a `preferences_default_codec_is_h264` unit test in
  `crates/video-coach-core/src/project.rs::tests` (or similar) that
  asserts `Preferences::default().last_export_codec == Codec::H264`.
- Add a `preferences_deserializes_without_codec_field` unit test
  that round-trips a legacy JSON `{"...","lastExportResolution":
  "r1080","lastExportQuality":"medium",...}` (no
  `lastExportCodec`) and confirms the deserialized struct has
  `last_export_codec == Codec::H264`.

**Commit**: `phase11(hevc-encoder, task 0): Codec enum + bitrate(…, codec) + last_export_codec`

**Why Task 0 first / why no UI yet**: Task 1's `pick_h265_encoder`
needs `Codec` to dispatch on, and Task 2's bus shape needs `Codec`
in scope. Task 0 lands the data shape with no behavior change
(every existing `bitrate` caller passes `Codec::H264` and gets the
exact same value back as before).

---

### Task 1: `pick_h265_encoder` + `build_video_output_chain` codec dispatch

Crate: `video-coach-media` only. ~120 LOC. Adds the encoder factory
and threads `codec` through one chain-builder + the public
`export_compilation` entry point.

**Add to `crates/video-coach-media/src/export.rs`** below
`pick_h264_encoder`:

```rust
/// Pick the best-available HEVC encoder element.
///
/// Order: HW per platform first, SW (`x265enc`) last. `make_or` failures
/// for unavailable factories are non-fatal and intentional; on
/// lavapipe/CI Linux runners we expect `vaapih265enc` + `nvh265enc` to
/// fail-load and warn under `gst-plugin-loader` before the loop falls
/// through to `x265enc` (this mirrors `pick_h264_encoder`'s tolerated
/// behavior — fix #1).
///
/// macOS note (fix #2): stock GStreamer 1.22+ registers VideoToolbox
/// HEVC under `vtenc_h265_hw` (HW) and `vtenc_h265` (SW fallback). We
/// list `_hw` first; if `_hw` isn't registered on the runner, the SW
/// `vtenc_h265` is still better than `x265enc`.
fn pick_h265_encoder(target_bitrate: u32) -> Result<gstreamer::Element, ExportError> {
    let candidates: &[&str] = &[
        "vtenc_h265_hw",  // Apple Silicon HW path (preferred)
        "vtenc_h265",     // VideoToolbox SW fallback
        "mfh265enc",      // Windows Media Foundation
        "vaapih265enc",   // Linux VA-API
        "nvh265enc",      // NVIDIA NVENC
        "x265enc",        // CPU fallback (always present via gst-plugins-bad)
    ];
    for name in candidates {
        if let Ok(elem) = make_or(name) {
            try_set_encoder_bitrate(&elem, name, target_bitrate);
            tracing::info!(target: "export.lifecycle", event = "export.encoder_picked", encoder = name);
            return Ok(elem);
        }
    }
    Err(ExportError::MissingElement("h265 encoder (any)".into()))
}
```

(Same shape as `pick_h264_encoder` — order is HW first, SW last.)

**Extend `try_set_encoder_bitrate`**'s bps-vs-kbps dispatch (per
fix #3) to use a `starts_with("vtenc_")` prefix so all VideoToolbox
variants — including `vtenc_h264_hw`, `vtenc_h265`, `vtenc_h265_hw`
— get bps treatment. The previous literal-match arm would silently
miss `vtenc_h265_hw` and divide-by-1000, producing a corrupt sub-1KB
file:

```rust
let primary = if encoder_name.starts_with("vtenc_") {
    target_bps                 // VideoToolbox family: bps
} else {
    target_bps / 1000          // everything else: kbps
};
```

**Change `build_video_output_chain` signature** to take a
`codec: Codec`:

```rust
fn build_video_output_chain(
    pipeline: &gstreamer::Pipeline,
    output_path: &Path,
    source_w: u32,
    source_h: u32,
    target_w: u32,
    target_h: u32,
    target_bitrate: u32,
    codec: Codec,
) -> Result<AppSrc, ExportError> {
```

Inside, dispatch on `codec`:

```rust
let (video_enc, parser) = match codec {
    Codec::H264 => (pick_h264_encoder(target_bitrate)?, make_or("h264parse")?),
    Codec::Hevc => (pick_h265_encoder(target_bitrate)?, make_or("h265parse")?),
};
```

Replace existing references to `h264parse` (variable name) with
`parser` for both `add_many` and `link_many` calls.

**HEVC-only capsfilter between parser and qtmux (per fix #4)**:
qtmux requires AVCC/HVCC stream-format for MP4 (not byte-stream). On
some GStreamer 1.20 builds, `h265parse`'s default emit is
`stream-format=byte-stream, alignment=nal` which qtmux rejects with
`could not link h265parse to qtmux`. Add a codec-conditional caps
filter only on the HEVC path:

```rust
let parser_caps_str: Option<&'static str> = match codec {
    Codec::H264 => None,  // existing chain; qtmux negotiates fine
    Codec::Hevc => Some("video/x-h265,stream-format=hvc1,alignment=au"),
};
let parser_caps_filter = parser_caps_str
    .map(make_capsfilter)
    .transpose()?; // Option<Element>
```

Build the link chain inserting `parser_caps_filter` between `parser`
and `qtmux` only when `Some`. For H.264, the chain is
`encoder → parser → qtmux` (unchanged). For HEVC,
`encoder → parser → caps-filter → qtmux`. Add the new element to
`add_many` only when present.

(`make_capsfilter` is a small helper — if one doesn't exist already
in `export.rs`, add a 5-line helper that constructs a `capsfilter`
element with the parsed `Caps`.)

**Change `export_compilation`'s public signature** to add
`codec: Codec` after `quality`:

```rust
pub fn export_compilation(
    inputs: ExportInputs,
    output_path: &Path,
    resolution: Resolution,
    quality: Quality,
    codec: Codec,
    _source_volume: f64,
    _commentary_volume: f64,
    compositor: Arc<Compositor>,
    cancel: Arc<AtomicBool>,
    on_progress: Box<dyn Fn(ExportProgress) + Send + Sync>,
) -> Result<ExportSummary, ExportError> {
```

Thread `codec` into the `bitrate(resolution, quality, codec)` call
at line 246 and pass it to `build_video_output_chain` at line 247.

**Update internal call sites in `video-coach-media`**: any internal
unit/integration test that calls `export_compilation` directly needs
to be updated to pass `Codec::H264`. Check
`crates/video-coach-media/tests/export_*.rs` (if any) and
`crates/video-coach-media/src/export.rs`'s `#[cfg(test)] mod tests`.

**Tests**:

- New unit test (gated behind `#[cfg(feature = "media")]`)
  `pick_h265_encoder_returns_some_factory` that calls
  `pick_h265_encoder(7_200_000)` and asserts `Ok(_)` (CI runners
  ship `x265enc` via `gst-plugins-bad`/`gst-plugins-good`; lavapipe
  Linux runner included).
- New smoke test
  `export_compilation_with_hevc_writes_non_empty_mp4` (gated behind
  `#[cfg(feature = "media")]`, marked `#[ignore]` IF Windows or
  macOS-CI runtime exceeds the existing harness's 60 s budget —
  see "Known unknowns" #2 below). Builds a single-entry plan,
  exports with `Codec::Hevc`, asserts:
    1. The output `.mp4` exists and **size > 50_000 bytes** (per
       fix #3; a kbps-vs-bps mis-encode would be < 1 KB).
    2. GStreamer Discoverer's video-stream caps string starts with
       `"video/x-h265"` (per fix #7 — exact prefix; rejects both
       a malformed `video/x-h265-fragment` and the H.264 silent-
       fallback regression mode).

  ```rust
  let caps_str = video_stream.caps().expect("caps").to_string();
  assert!(
      caps_str.starts_with("video/x-h265"),
      "expected HEVC output, got caps: {caps_str}"
  );
  let size = std::fs::metadata(&out_path).expect("metadata").len();
  assert!(size > 50_000, "expected >50 KB output, got {size} bytes");
  ```

**Commit**: `phase11(hevc-encoder, task 1): pick_h265_encoder + Codec dispatch in build_video_output_chain`

---

### Task 2: Slint Codec radio + bus wiring + ui.rs

Crate: `video-coach-app` only. ~110 LOC. Surface the picker in the
UI, persist on Export click.

**`crates/video-coach-app/ui/main.slint`** changes:

1. Add `in-out property <string> export-codec: "h264";` next to
   `export-resolution` / `export-quality` (~line 116).
2. Add `callback export-codec-changed(string);` next to
   `export-resolution-changed` / `export-quality-changed`
   (~line 163).
3. Add a Codec picker row in the Form view at y:430-460px (below
   the Quality row that ends at y:416px). Two radio-button
   `Rectangle`s with TouchAreas, mirroring the Quality row's shape
   exactly. Layout:

   ```
   y:430  "Codec" label  (24px x, 120px wide)
   y:452  H.264 button   (24px x, 88px wide)
   y:452  HEVC button    (116px x, 88px wide)
   ```

   `clicked => { root.export-codec-changed("h264"); }` /
   `("hevc")` respectively. Background color logic identical to the
   resolution/quality buttons (selected = #4a90e2; hovered = #2e2e2e;
   default = #262626).

4. **Adjust the Cancel + Export buttons' positioning** if they were
   anchored to a fixed y-offset relative to the form view's height
   that assumed only Resolution + Quality rows. Reading the source:
   the Cancel button is at `parent.height - 52px` (line 1218), so
   it's bottom-anchored — adding a Codec row above it doesn't push
   it. Verify: the Form view's parent Rectangle (the export sheet
   modal) needs to be tall enough that the Codec row at y:452-480px
   doesn't collide with the Cancel/Export buttons. If the modal's
   height is hardcoded, increase it by 60px. (Search for the
   parent Rectangle's `height:` literal and patch it.)

**`crates/video-coach-app/src/bus.rs`** changes:

1. Extend `Command::ExportCompilations` (~line 125):

   ```rust
   ExportCompilations {
       selections: Vec<TagSelection>,
       output_folder: String,
       resolution: video_coach_core::project::Resolution,
       quality: video_coach_core::project::Quality,
       codec: video_coach_core::project::Codec,
       project_name: String,
   },
   ```

2. Extend the dispatch arm (~line 2057):

   ```rust
   Command::ExportCompilations {
       selections, output_folder, resolution, quality, codec, project_name,
   } => {
       handle_export_compilations(
           selections, output_folder, resolution, quality, codec,
           project_name, …
       ).await
   }
   ```

3. Extend `handle_export_compilations`'s signature with `codec:
   video_coach_core::project::Codec` after `quality`. Persist
   `project.preferences.last_export_codec = codec;` at the
   fix #11 persistence step (~line 2258).

4. Pass `codec` into the inner `tokio::task::spawn_blocking` call
   that invokes `export_compilation` (search for that call; it'll
   be ~line 2380-2440 in the per-tag for-loop).

**`crates/video-coach-app/src/ui.rs`** changes:

1. Add `on_export_codec_changed` binding at ~line 803 (after the
   quality binding) — same shape:

   ```rust
   let weak_for_codec = window.as_weak();
   window.on_export_codec_changed(move |s: slint::SharedString| {
       if let Some(w) = weak_for_codec.upgrade() {
           w.set_export_codec(s);
       }
   });
   ```

2. In `on_export_start_clicked` (~line 836), parse codec with
   warn-and-fall-back-to-prefs on unknown values (per fix #6 — the
   wildcard-to-H.264 fallback is wrong as a UX contract):

   ```rust
   let codec = match w.get_export_codec().as_str() {
       "h264" => video_coach_core::project::Codec::H264,
       "hevc" => video_coach_core::project::Codec::Hevc,
       other => {
           tracing::warn!(
               target: "export.lifecycle",
               event = "export.codec_string_unknown",
               value = other,
               "falling back to last_export_codec"
           );
           prefs.last_export_codec
       }
   };
   ```

   `prefs` is read via the same project-preferences accessor used for
   resolution/quality.

3. Add `codec,` to the `Command::ExportCompilations { … }` literal
   sent through the bus.

4. **Mandatory sheet-open hydration of all three properties (per
   fix #8)**. Slint properties reset to their declared defaults on
   each component re-instantiation; the Phase-10 "persisted on Export
   click" pattern is necessary but not sufficient on its own. Find
   the sheet-open trigger (the bus arm or ui.rs handler that shows
   the export-sheet modal). Set ALL THREE properties from
   `Preferences` BEFORE showing:

   - `export-resolution` ← `prefs.last_export_resolution` (as
     "source"/"r1080"/"r720")
   - `export-quality` ← `prefs.last_export_quality` (as
     "low"/"medium"/"high")
   - `export-codec` ← `prefs.last_export_codec` (as "h264"/"hevc")

   If hydration was already in place for resolution/quality, just
   add the codec line. If neither was hydrated before, ADD ALL
   THREE in Task 2 (small scope expansion, ~6 LOC). The fix-#11
   "persisted on Export click" pattern ensures the prefs are written;
   this hydration ensures the prefs are read on next open.

   **New bus integration test**:
   `opening_export_sheet_hydrates_codec_from_preferences` — construct
   a project with `last_export_codec: Codec::Hevc`, fire the
   sheet-open command, assert the Slint `export-codec` property
   reads `"hevc"`. (Mirror existing resolution/quality test if
   present; otherwise add all three.)

**Tests**:

- Bus integration test (gated `#[cfg(feature = "media")]`,
  `crates/video-coach-app/tests/` or in-line in `bus.rs`):
  `export_command_with_hevc_codec_round_trips` — serializes a
  `Command::ExportCompilations { codec: Codec::Hevc, … }` to JSON
  via the same path the control socket uses, deserializes, asserts
  codec field is preserved. (Phase 10 has a similar test for
  resolution / quality — find and mirror.)
- A smoke unit test (no media feature needed; pure data) that
  constructs `ExportCompilations` with `Codec::Hevc` and
  pattern-matches the codec field round-trips. This is the
  cheapest gate against an enum-variant typo.

**Commit**: `phase11(hevc-encoder, task 2): Slint Codec radio + bus + ui.rs wiring`

---

## Done criteria

- `cargo build --workspace --features media` clean.
- `cargo test --workspace --features media` green; new tests pass.
- `cargo build --workspace --no-default-features` clean (Codec is
  no-feature-flag — pure data type).
- `cargo clippy --workspace --all-targets --features media -- -D warnings` clean.
- `cargo clippy --workspace --exclude video-coach-media --all-targets -- -D warnings` clean.
- `cargo fmt --check` clean.
- A manual macOS H.264 export still produces an `.mp4` Discoverer
  reports as `video/x-h264` (no regression).
- A manual macOS HEVC export produces an `.mp4` Discoverer reports
  as `video/x-h265`.
- Loading a Phase 10-era project.json (no `lastExportCodec` field)
  succeeds and reports `Preferences::default().last_export_codec ==
  Codec::H264` after deserialize.
- The export sheet's Form view shows three rows
  (Resolution / Quality / Codec); Codec defaults to H.264 selected;
  toggling persists across project save+reopen.

---

## Known unknowns

1. **`vtenc_h265` availability**: macOS-only and listed as M1+ on
   Apple's hardware-acceleration matrix. Phase 11 CI's
   `macos-latest` runner is Apple Silicon, so `vtenc_h265` should
   be present; we'll confirm via the smoke test's `encoder_picked`
   log line. If it's missing, the picker falls through to
   `x265enc` (CPU; slower but correct).
2. **`mfh265enc` Windows cold-start**: Windows Media Foundation
   encoders cold-start in 5-15 s. The Phase 10 harness E2E timeout
   was set with H.264 in mind. If `cargo test --features media` on
   Windows blows the timeout for HEVC, mark the HEVC smoke test
   `#[ignore]` on Windows OR widen the timeout from N seconds to
   N+30. Decision deferred to Task 1 review.
3. **Lavapipe Linux x265enc**: Linux CI uses lavapipe (software
   wgpu); it has no GPU encoder, so HEVC falls all the way to
   `x265enc`. A 1.2 s clip × x265enc on the GitHub Linux runner
   could run 30+ s. The smoke test's frame count is small (single
   clip, recording_duration ~1.2 s = 36 frames at 30 fps); should
   fit in a generous timeout. Mitigation: budget 90 s for the HEVC
   smoke test specifically.
4. **`qtmux` HEVC compatibility (resolved upfront via fix #4)**: an
   explicit `video/x-h265,stream-format=hvc1,alignment=au` capsfilter
   between `h265parse` and `qtmux` is now baked into Task 1. If
   `qtmux` still rejects HEVC despite the capsfilter on some matrix
   entry (very unlikely on 1.20+), the fallback is `mp4mux` in a
   Task 1 fix-up. The smoke test catches a muxer-link failure
   immediately by failing to reach PLAYING.
5. **Code-review will likely raise the HEVC-vs-H.264 file-size
   parity claim** (the 60% bitrate ratio). The 60% number is a
   common rule-of-thumb for HEVC at the same perceptual quality
   level (PSNR/VMAF) but varies by content; sports footage (our
   target) compresses HEVC slightly better than that. We're not
   going to instrument visual-quality scoring; the bitrate values
   are calibrated heuristics and adjustable later.

---

## Closeout

(Filled in at the `READY_FOR_CLOSEOUT` stage with the final SHA, CI
run id, and any deviation notes from the orchestrator's pass
through. PROGRESS.txt's "Plan #1: HEVC encoder" line gets flipped to
`[x] … SHIPPED <date>. CI run <id> green on all 4 jobs.` at the
same time.)
