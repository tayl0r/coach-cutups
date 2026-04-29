# Phase 1: Rust Workspace + Core Port — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Bootstrap a Rust Cargo workspace and port the platform-neutral logic from `VideoCoachCore` (Swift) into a new `video-coach-core` crate, with full unit-test coverage and CI green on macOS / Windows / Linux.

**Architecture:** New top-level `crates/video-coach-core/` crate with **no** dependencies on GStreamer, Slint, or wgpu. Pure data types, project IO, source-time reconstruction, stroke replay, and tag aggregation. Mirrors the structure of v1's Swift package one-to-one so review against the source is mechanical.

**Tech Stack:** Rust stable, `serde` + `serde_json` for `project.json`, `uuid` (v4), `chrono` for ISO-8601 timestamps, `thiserror` for error enums. No external test framework — Rust's built-in `#[cfg(test)]` modules.

**Reference for source code being ported:** `VideoCoachCore/Sources/VideoCoachCore/`. Each task names the exact Swift file to translate. Behavioral parity is the bar — tests should mirror the Swift tests in `VideoCoachCore/Tests/VideoCoachCoreTests/`.

**Schema change vs v1:** `SourceRef` drops `bookmark: Data` (macOS-only security-scoped bookmark) and replaces it with `relativePath: String` (relative to the project folder). This is the *only* intentional schema change in Phase 1. `Project.formatVersion` bumps to `2`.

---

## Task 1: Cargo workspace skeleton

**Files:**
- Create: `Cargo.toml` (workspace root)
- Create: `crates/video-coach-core/Cargo.toml`
- Create: `crates/video-coach-core/src/lib.rs`
- Create: `rust-toolchain.toml`
- Create: `.rustfmt.toml`

**Step 1: Create the workspace `Cargo.toml`**

```toml
# Cargo.toml
[workspace]
resolver = "2"
members = ["crates/video-coach-core"]

[workspace.package]
edition = "2021"
rust-version = "1.78"
license = "AGPL-3.0-only"
repository = "https://github.com/<owner>/video-coach"

[workspace.dependencies]
serde = { version = "1", features = ["derive"] }
serde_json = "1"
uuid = { version = "1", features = ["serde", "v4"] }
chrono = { version = "0.4", default-features = false, features = ["serde", "clock"] }
thiserror = "1"
```

**Step 2: Create the core crate manifest**

```toml
# crates/video-coach-core/Cargo.toml
[package]
name = "video-coach-core"
version = "0.1.0"
edition.workspace = true
rust-version.workspace = true
license.workspace = true

[dependencies]
serde = { workspace = true }
serde_json = { workspace = true }
uuid = { workspace = true }
chrono = { workspace = true }
thiserror = { workspace = true }
```

**Step 3: Create `crates/video-coach-core/src/lib.rs`**

```rust
// Empty for now — modules added in subsequent tasks.
```

**Step 4: Pin the toolchain**

```toml
# rust-toolchain.toml
[toolchain]
channel = "stable"
components = ["rustfmt", "clippy"]
```

**Step 5: Configure formatter**

```toml
# .rustfmt.toml
edition = "2021"
max_width = 100
```

**Step 6: Verify the workspace builds**

Run: `cargo build`
Expected: `Finished dev [unoptimized + debuginfo] target(s) in ...` — zero warnings, zero errors.

**Step 7: Commit**

```bash
git add Cargo.toml crates/video-coach-core/Cargo.toml crates/video-coach-core/src/lib.rs rust-toolchain.toml .rustfmt.toml
git commit -m "feat(rust): bootstrap Cargo workspace and video-coach-core crate"
```

---

## Task 2: Port `Stroke`, `StrokePoint`, `RGBA`

**Source:** `VideoCoachCore/Sources/VideoCoachCore/Stroke.swift` (37 lines)

**Files:**
- Create: `crates/video-coach-core/src/stroke.rs`
- Modify: `crates/video-coach-core/src/lib.rs`

**Step 1: Write the failing test**

Add to `crates/video-coach-core/src/stroke.rs`:

```rust
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Rgba {
    pub r: f64,
    pub g: f64,
    pub b: f64,
    pub a: f64,
}

impl Rgba {
    pub const RED: Rgba = Rgba { r: 1.0, g: 0.2, b: 0.2, a: 1.0 };
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct StrokePoint {
    pub x: f64,
    pub y: f64,
    pub t: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Stroke {
    pub id: Uuid,
    pub color: Rgba,
    pub line_width: f64,
    pub points: Vec<StrokePoint>,
    pub auto_clear_after_seconds: Option<f64>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn red_constant_matches_swift() {
        assert_eq!(Rgba::RED, Rgba { r: 1.0, g: 0.2, b: 0.2, a: 1.0 });
    }

    #[test]
    fn stroke_roundtrips_through_json() {
        let s = Stroke {
            id: Uuid::nil(),
            color: Rgba::RED,
            line_width: 0.012,
            points: vec![StrokePoint { x: 0.5, y: 0.5, t: 0.0 }],
            auto_clear_after_seconds: Some(5.0),
        };
        let json = serde_json::to_string(&s).unwrap();
        let back: Stroke = serde_json::from_str(&json).unwrap();
        assert_eq!(s, back);
    }
}
```

Wire into `lib.rs`:

```rust
pub mod stroke;
```

**Step 2: Run tests to verify they pass**

Run: `cargo test -p video-coach-core stroke::`
Expected: `test result: ok. 2 passed`

**Step 3: Pin JSON field naming**

Add a third test verifying camelCase serialization to match the v1 schema (Swift's default `Codable` uses property names as-is, which are already camelCase in v1):

```rust
#[test]
fn stroke_serializes_with_camelcase_keys() {
    let s = Stroke {
        id: Uuid::nil(),
        color: Rgba::RED,
        line_width: 0.012,
        points: vec![],
        auto_clear_after_seconds: None,
    };
    let json = serde_json::to_value(&s).unwrap();
    let obj = json.as_object().unwrap();
    assert!(obj.contains_key("lineWidth"), "expected camelCase `lineWidth`, got: {:?}", obj.keys().collect::<Vec<_>>());
    assert!(obj.contains_key("autoClearAfterSeconds"));
}
```

**Step 4: Run test, watch it fail**

Run: `cargo test -p video-coach-core stroke::tests::stroke_serializes_with_camelcase_keys`
Expected: FAIL — fields serialize as `line_width`, not `lineWidth`.

**Step 5: Add `#[serde(rename_all = "camelCase")]` to all three structs in `stroke.rs`**

```rust
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Rgba { /* ... */ }

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StrokePoint { /* ... */ }

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Stroke { /* ... */ }
```

**Step 6: Run tests, verify all pass**

Run: `cargo test -p video-coach-core stroke::`
Expected: `test result: ok. 3 passed`

**Step 7: Commit**

```bash
git add crates/video-coach-core/src/stroke.rs crates/video-coach-core/src/lib.rs
git commit -m "feat(core): port Stroke / StrokePoint / Rgba"
```

---

## Task 3: Port `CommentaryEvent`

**Source:** `VideoCoachCore/Sources/VideoCoachCore/CommentaryEvent.swift` (19 lines)

**Files:**
- Create: `crates/video-coach-core/src/event.rs`
- Modify: `crates/video-coach-core/src/lib.rs`

**Note on the enum encoding:** Swift `Codable` encodes associated-value enums as a tagged dictionary by default — e.g. `{"play": {}}` for `.play` and `{"skip": {"delta": 3.0}}` for `.skip(delta: 3.0)`. The corresponding `serde` attribute is `#[serde(rename_all = "camelCase")]` plus internal tagging. We'll write the failing test against the canonical Swift output first to pin the format, then adapt the attribute until it matches.

**Step 1: Write the failing test that pins the wire format**

Capture the Swift wire format by running this in a Swift REPL or test (one-time, exemplar):
```swift
let evs = [
    CommentaryEvent(recordTime: 0, kind: .play),
    CommentaryEvent(recordTime: 1.5, kind: .skip(delta: 3.0)),
]
print(String(data: try JSONEncoder().encode(evs), encoding: .utf8)!)
// → [{"recordTime":0,"kind":{"play":{}}},{"recordTime":1.5,"kind":{"skip":{"delta":3}}}]
```

Add to `crates/video-coach-core/src/event.rs`:

```rust
use serde::{Deserialize, Serialize};
use crate::stroke::Stroke;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EventKind {
    Play,
    Pause,
    Skip { delta: f64 },
    Stroke(Stroke),
    ClearAll,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommentaryEvent {
    pub record_time: f64,
    pub kind: EventKind,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn play_event_encodes_as_swift_dictionary_form() {
        let ev = CommentaryEvent { record_time: 0.0, kind: EventKind::Play };
        let json: serde_json::Value = serde_json::to_value(&ev).unwrap();
        // Expected: {"recordTime": 0.0, "kind": {"play": {}}}
        assert_eq!(
            json,
            serde_json::json!({ "recordTime": 0.0, "kind": { "play": {} } })
        );
    }

    #[test]
    fn skip_event_encodes_with_delta_payload() {
        let ev = CommentaryEvent { record_time: 1.5, kind: EventKind::Skip { delta: 3.0 } };
        let json: serde_json::Value = serde_json::to_value(&ev).unwrap();
        assert_eq!(
            json,
            serde_json::json!({ "recordTime": 1.5, "kind": { "skip": { "delta": 3.0 } } })
        );
    }
}
```

Wire into `lib.rs`:

```rust
pub mod event;
```

**Step 2: Run tests, watch them fail**

Run: `cargo test -p video-coach-core event::`
Expected: FAIL — default `serde` tagging emits `{"play": null}` or untagged form, not `{"play": {}}`.

**Step 3: Adjust the enum encoding to match Swift**

The closest serde rep is **untagged enum with explicit type for unit variants**, but the simplest fix is to use a custom `Serialize`/`Deserialize` impl that matches Swift's `Codable`-for-enums output verbatim. Add to `event.rs`:

```rust
// Replace the `#[derive(Serialize, Deserialize)]` on EventKind with custom impls
// that emit Swift's tagged-dictionary form.
use serde::ser::{SerializeMap, Serializer};
use serde::de::{self, MapAccess, Visitor, Deserializer};
use std::fmt;

#[derive(Debug, Clone, PartialEq)]
pub enum EventKind {
    Play,
    Pause,
    Skip { delta: f64 },
    Stroke(crate::stroke::Stroke),
    ClearAll,
}

impl Serialize for EventKind {
    fn serialize<S: Serializer>(&self, ser: S) -> Result<S::Ok, S::Error> {
        let mut m = ser.serialize_map(Some(1))?;
        match self {
            EventKind::Play       => m.serialize_entry("play",     &serde_json::json!({}))?,
            EventKind::Pause      => m.serialize_entry("pause",    &serde_json::json!({}))?,
            EventKind::Skip { delta } => m.serialize_entry("skip", &serde_json::json!({ "delta": delta }))?,
            EventKind::Stroke(s)  => m.serialize_entry("stroke",   s)?,
            EventKind::ClearAll   => m.serialize_entry("clearAll", &serde_json::json!({}))?,
        }
        m.end()
    }
}

impl<'de> Deserialize<'de> for EventKind {
    fn deserialize<D: Deserializer<'de>>(de: D) -> Result<Self, D::Error> {
        struct V;
        impl<'de> Visitor<'de> for V {
            type Value = EventKind;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("a single-key map describing an event kind")
            }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<EventKind, A::Error> {
                let key: String = map.next_key()?.ok_or_else(|| de::Error::custom("empty"))?;
                match key.as_str() {
                    "play"     => { let _: serde_json::Value = map.next_value()?; Ok(EventKind::Play) }
                    "pause"    => { let _: serde_json::Value = map.next_value()?; Ok(EventKind::Pause) }
                    "clearAll" => { let _: serde_json::Value = map.next_value()?; Ok(EventKind::ClearAll) }
                    "skip"     => {
                        #[derive(Deserialize)] struct P { delta: f64 }
                        let p: P = map.next_value()?;
                        Ok(EventKind::Skip { delta: p.delta })
                    }
                    "stroke"   => {
                        let s: crate::stroke::Stroke = map.next_value()?;
                        Ok(EventKind::Stroke(s))
                    }
                    other => Err(de::Error::unknown_variant(other,
                        &["play","pause","skip","stroke","clearAll"])),
                }
            }
        }
        de.deserialize_map(V)
    }
}
```

**Step 4: Re-run tests**

Run: `cargo test -p video-coach-core event::`
Expected: `test result: ok. 2 passed`

**Step 5: Add a roundtrip test for every variant**

```rust
#[test]
fn every_variant_roundtrips() {
    use crate::stroke::{Rgba, StrokePoint};
    use uuid::Uuid;
    let cases = vec![
        EventKind::Play,
        EventKind::Pause,
        EventKind::Skip { delta: -3.0 },
        EventKind::ClearAll,
        EventKind::Stroke(crate::stroke::Stroke {
            id: Uuid::nil(),
            color: Rgba::RED,
            line_width: 0.01,
            points: vec![StrokePoint { x: 0.0, y: 0.0, t: 0.0 }],
            auto_clear_after_seconds: None,
        }),
    ];
    for k in cases {
        let s = serde_json::to_string(&k).unwrap();
        let back: EventKind = serde_json::from_str(&s).unwrap();
        assert_eq!(k, back, "variant did not roundtrip via {}", s);
    }
}
```

Run: `cargo test -p video-coach-core event::`
Expected: `test result: ok. 3 passed`

**Step 6: Commit**

```bash
git add crates/video-coach-core/src/event.rs crates/video-coach-core/src/lib.rs
git commit -m "feat(core): port CommentaryEvent with Swift-compatible JSON shape"
```

---

## Task 4: Port `Project`, `Clip`, `SourceRef`, `Preferences`, `Tag::normalize`

**Source:** `VideoCoachCore/Sources/VideoCoachCore/Project.swift` (90 lines)

**Files:**
- Create: `crates/video-coach-core/src/project.rs`
- Modify: `crates/video-coach-core/src/lib.rs`

**Schema note:** This is where the v2 schema change lives — `SourceRef.bookmark: Data` becomes `SourceRef.relativePath: String`. `Project.formatVersion` bumps to `2`.

**Step 1: Write the failing tests**

```rust
// crates/video-coach-core/src/project.rs
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;
use crate::event::CommentaryEvent;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Resolution { Source, R1080, R720 }

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Quality { Low, Medium, High }

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Preferences {
    pub scan_volume: f64,
    pub preview_source_volume: f64,
    pub preview_commentary_volume: f64,
    pub last_export_resolution: Resolution,
    pub last_export_quality: Quality,
    pub preferred_camera_id: Option<String>,
    pub preferred_mic_id: Option<String>,
}

impl Default for Preferences {
    fn default() -> Self {
        Self {
            scan_volume: 1.0,
            preview_source_volume: 1.0,
            preview_commentary_volume: 1.0,
            last_export_resolution: Resolution::R1080,
            last_export_quality: Quality::Medium,
            preferred_camera_id: None,
            preferred_mic_id: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceRef {
    /// v2 SCHEMA CHANGE: was `bookmark: Data` in v1 (macOS security-scoped
    /// bookmark). Now a path relative to the project folder, so the project
    /// folder is a self-contained, cross-platform unit.
    pub relative_path: String,
    pub display_name: String,
    pub duration_seconds: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Clip {
    pub id: Uuid,
    pub name: String,
    pub notes: String,
    pub tags: Vec<String>,
    pub source_index: usize,
    pub start_source_seconds: f64,
    pub recording_duration: f64,
    pub recording_filename: String,
    pub events: Vec<CommentaryEvent>,
    pub sort_index: i64,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Project {
    pub format_version: i32,
    pub name: String,
    pub source_videos: Vec<SourceRef>,
    pub clips: Vec<Clip>,
    pub preferences: Preferences,
}

impl Project {
    pub const FORMAT_VERSION: i32 = 2;
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            format_version: Self::FORMAT_VERSION,
            name: name.into(),
            source_videos: vec![],
            clips: vec![],
            preferences: Preferences::default(),
        }
    }
}

pub fn normalize_tag_input(input: &str) -> Vec<String> {
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut out = Vec::new();
    for fragment in input.split(',') {
        let trimmed = fragment.trim().to_lowercase();
        if trimmed.is_empty() || seen.contains(&trimmed) { continue; }
        seen.insert(trimmed.clone());
        out.push(trimmed);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_project_uses_format_version_2() {
        let p = Project::new("My Project");
        assert_eq!(p.format_version, 2);
        assert_eq!(p.name, "My Project");
        assert!(p.clips.is_empty());
        assert_eq!(p.preferences, Preferences::default());
    }

    #[test]
    fn tag_normalize_dedupes_lowercases_trims() {
        assert_eq!(
            normalize_tag_input("  Attack ,  ATTACK,defense ,, , offense"),
            vec!["attack", "defense", "offense"]
        );
    }

    #[test]
    fn tag_normalize_empty_string_yields_empty() {
        assert_eq!(normalize_tag_input(""), Vec::<String>::new());
    }

    #[test]
    fn project_roundtrips_through_json() {
        let p = Project::new("Test");
        let s = serde_json::to_string(&p).unwrap();
        let back: Project = serde_json::from_str(&s).unwrap();
        assert_eq!(p, back);
    }
}
```

Wire into `lib.rs`:

```rust
pub mod project;
```

**Step 2: Run tests**

Run: `cargo test -p video-coach-core project::`
Expected: `test result: ok. 4 passed`

**Step 3: Verify camelCase output for nested types**

```rust
#[test]
fn source_ref_serializes_with_relative_path_key() {
    let s = SourceRef {
        relative_path: "sources/match1.mp4".into(),
        display_name: "Match 1".into(),
        duration_seconds: 5400.0,
    };
    let json = serde_json::to_value(&s).unwrap();
    let obj = json.as_object().unwrap();
    assert!(obj.contains_key("relativePath"));
    assert!(obj.contains_key("displayName"));
    assert!(obj.contains_key("durationSeconds"));
    assert!(!obj.contains_key("bookmark"), "v2 must not emit bookmark field");
}
```

Run: `cargo test -p video-coach-core project::`
Expected: `test result: ok. 5 passed`

**Step 4: Commit**

```bash
git add crates/video-coach-core/src/project.rs crates/video-coach-core/src/lib.rs
git commit -m "feat(core): port Project / Clip / SourceRef / Preferences (v2 schema)"
```

---

## Task 5: Port `PlaybackTimeline` (source-time reconstruction + playback segments)

**Source:** `VideoCoachCore/Sources/VideoCoachCore/PlaybackTimeline.swift` (65 lines).
**Reference tests:** `VideoCoachCore/Tests/VideoCoachCoreTests/PlaybackTimelineTests.swift` — port these test cases directly so behavioral parity is provable.

**Files:**
- Create: `crates/video-coach-core/src/timeline.rs`
- Modify: `crates/video-coach-core/src/lib.rs`

**Step 1: Read the existing Swift tests**

Run: `cat VideoCoachCore/Tests/VideoCoachCoreTests/PlaybackTimelineTests.swift`
Take note of every assertion — those are the spec.

**Step 2: Write failing tests in Rust mirroring the Swift suite**

```rust
// crates/video-coach-core/src/timeline.rs
use crate::event::{CommentaryEvent, EventKind};
use crate::project::Clip;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SegmentKind { Play, Freeze }

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PlaybackSegment {
    pub kind: SegmentKind,
    pub source_start: f64,
    pub out_duration: f64,
}

pub fn source_time_at(clip: &Clip, t: f64) -> f64 {
    let mut source_time = clip.start_source_seconds;
    let mut record_cursor = 0.0_f64;
    let mut rate = 1.0_f64;
    for ev in clip.events.iter().filter(|e| e.record_time <= t) {
        source_time += (ev.record_time - record_cursor) * rate;
        record_cursor = ev.record_time;
        match ev.kind {
            EventKind::Play     => rate = 1.0,
            EventKind::Pause    => rate = 0.0,
            EventKind::Skip { delta } => source_time += delta,
            EventKind::Stroke(_) | EventKind::ClearAll => {}
        }
    }
    source_time + (t - record_cursor) * rate
}

pub fn playback_segments(clip: &Clip, source_duration: f64) -> Vec<PlaybackSegment> {
    let mut segments: Vec<PlaybackSegment> = Vec::new();
    let mut source_cursor = clip.start_source_seconds;
    let mut record_cursor = 0.0_f64;
    let mut rate = 1.0_f64;

    let mut emit = |record_end: f64, segments: &mut Vec<PlaybackSegment>,
                    source_cursor: &mut f64, record_cursor: &mut f64, rate: f64| {
        let dur = record_end - *record_cursor;
        if dur <= 0.0 { return; }
        let kind = if rate == 0.0 { SegmentKind::Freeze } else { SegmentKind::Play };
        segments.push(PlaybackSegment {
            kind,
            source_start: *source_cursor,
            out_duration: dur,
        });
        if rate == 1.0 { *source_cursor += dur; }
        *record_cursor = record_end;
    };

    for ev in &clip.events {
        emit(ev.record_time, &mut segments, &mut source_cursor, &mut record_cursor, rate);
        match ev.kind {
            EventKind::Play     => rate = 1.0,
            EventKind::Pause    => rate = 0.0,
            EventKind::Skip { delta } => {
                source_cursor = (source_cursor + delta).clamp(0.0, source_duration);
            }
            EventKind::Stroke(_) | EventKind::ClearAll => {}
        }
    }
    emit(clip.recording_duration, &mut segments, &mut source_cursor, &mut record_cursor, rate);
    segments
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::Clip;
    use chrono::Utc;
    use uuid::Uuid;

    fn clip_with(events: Vec<CommentaryEvent>, recording_duration: f64, start_source: f64) -> Clip {
        Clip {
            id: Uuid::nil(),
            name: "t".into(), notes: "".into(), tags: vec![],
            source_index: 0,
            start_source_seconds: start_source,
            recording_duration,
            recording_filename: "r.mov".into(),
            events,
            sort_index: 0,
            created_at: Utc::now(),
        }
    }

    #[test]
    fn empty_event_log_implies_constant_rate_one() {
        // Per Swift PlaybackTimelineTests: with no events, sourceTime advances 1:1.
        let c = clip_with(vec![], 10.0, 100.0);
        assert!((source_time_at(&c, 0.0) - 100.0).abs() < 1e-9);
        assert!((source_time_at(&c, 5.0) - 105.0).abs() < 1e-9);
        let segs = playback_segments(&c, 1000.0);
        assert_eq!(segs.len(), 1);
        assert_eq!(segs[0].kind, SegmentKind::Play);
        assert!((segs[0].out_duration - 10.0).abs() < 1e-9);
    }

    #[test]
    fn pause_event_creates_freeze_segment() {
        let evs = vec![
            CommentaryEvent { record_time: 2.0, kind: EventKind::Pause },
            CommentaryEvent { record_time: 4.0, kind: EventKind::Play  },
        ];
        let c = clip_with(evs, 6.0, 0.0);
        let segs = playback_segments(&c, 1000.0);
        assert_eq!(segs.len(), 3);
        assert_eq!(segs[0].kind, SegmentKind::Play);
        assert_eq!(segs[1].kind, SegmentKind::Freeze);
        assert_eq!(segs[2].kind, SegmentKind::Play);
        assert!((segs[1].out_duration - 2.0).abs() < 1e-9);
    }

    // ADD: one test per scenario from the Swift PlaybackTimelineTests file —
    // skip behavior, skip clamping at source_duration, multiple pauses, etc.
}
```

Wire into `lib.rs`:

```rust
pub mod timeline;
```

**Step 3: Run tests**

Run: `cargo test -p video-coach-core timeline::`
Expected: starts failing on the first scenario where the closure-borrowing pattern misbehaves (the `emit` closure capturing mutable references is fiddly — may need refactor).

**Step 4: If `emit` closure won't typecheck, refactor to a free function**

Replace the closure with:

```rust
fn emit_segment(
    record_end: f64,
    segments: &mut Vec<PlaybackSegment>,
    source_cursor: &mut f64,
    record_cursor: &mut f64,
    rate: f64,
) {
    let dur = record_end - *record_cursor;
    if dur <= 0.0 { return; }
    let kind = if rate == 0.0 { SegmentKind::Freeze } else { SegmentKind::Play };
    segments.push(PlaybackSegment { kind, source_start: *source_cursor, out_duration: dur });
    if rate == 1.0 { *source_cursor += dur; }
    *record_cursor = record_end;
}
```

Update `playback_segments` to call `emit_segment(...)` directly.

**Step 5: Add EVERY test case from the Swift `PlaybackTimelineTests.swift`**

Read the Swift file and translate each `func test_*` into a `#[test] fn ...`. Use the exact same numeric inputs and expected outputs.

**Step 6: Run all timeline tests**

Run: `cargo test -p video-coach-core timeline::`
Expected: ALL pass. If any fail, the divergence is a porting bug — fix before moving on. This module is the most behaviorally critical in the entire core.

**Step 7: Commit**

```bash
git add crates/video-coach-core/src/timeline.rs crates/video-coach-core/src/lib.rs
git commit -m "feat(core): port PlaybackTimeline source-time reconstruction"
```

---

## Task 6: Port `StrokeReplay` (visible-strokes computation)

**Source:** `VideoCoachCore/Sources/VideoCoachCore/StrokeReplay.swift` (34 lines).
**Reference tests:** `VideoCoachCore/Tests/VideoCoachCoreTests/StrokeReplayTests.swift`.

**Files:**
- Create: `crates/video-coach-core/src/stroke_replay.rs`
- Modify: `crates/video-coach-core/src/lib.rs`

**Step 1: Read the existing Swift tests**

Run: `cat VideoCoachCore/Tests/VideoCoachCoreTests/StrokeReplayTests.swift`

**Step 2: Write the Rust implementation + ported tests**

```rust
// crates/video-coach-core/src/stroke_replay.rs
use crate::event::{CommentaryEvent, EventKind};
use crate::project::Clip;
use crate::stroke::Stroke;

#[derive(Debug, Clone, PartialEq)]
pub struct VisibleStroke {
    pub stroke: Stroke,
    pub first_point_record_time: f64,
    pub drawn_point_count: usize,
}

pub fn visible_strokes(clip: &Clip, t: f64) -> Vec<VisibleStroke> {
    let clear_all_times: Vec<f64> = clip.events.iter()
        .filter_map(|e| match e.kind {
            EventKind::ClearAll if e.record_time <= t => Some(e.record_time),
            _ => None,
        })
        .collect();

    let mut out = Vec::new();
    for ev in &clip.events {
        let s = match &ev.kind {
            EventKind::Stroke(s) => s,
            _ => continue,
        };
        let first_t = ev.record_time - s.points.last().map(|p| p.t).unwrap_or(0.0);
        if t < first_t { continue; }
        if let Some(auto) = s.auto_clear_after_seconds {
            if t >= first_t + auto { continue; }
        }
        if clear_all_times.iter().any(|c| *c > first_t && *c <= t) { continue; }

        let elapsed = t - first_t;
        let k = s.points.iter().position(|p| p.t > elapsed).unwrap_or(s.points.len());
        out.push(VisibleStroke {
            stroke: s.clone(),
            first_point_record_time: first_t,
            drawn_point_count: k,
        });
    }
    out
}

#[cfg(test)]
mod tests {
    // PORT every test case from StrokeReplayTests.swift here.
    // Use identical numeric inputs and expected counts/indices.
}
```

Wire into `lib.rs`:

```rust
pub mod stroke_replay;
```

**Step 3: Run tests**

Run: `cargo test -p video-coach-core stroke_replay::`
Expected: all pass.

**Step 4: Commit**

```bash
git add crates/video-coach-core/src/stroke_replay.rs crates/video-coach-core/src/lib.rs
git commit -m "feat(core): port StrokeReplay visible-strokes algorithm"
```

---

## Task 7: Port `TagAggregation`

**Source:** `VideoCoachCore/Sources/VideoCoachCore/TagAggregation.swift` (28 lines).
**Reference tests:** `VideoCoachCore/Tests/VideoCoachCoreTests/TagAggregationTests.swift`.

**Files:**
- Create: `crates/video-coach-core/src/tag_aggregation.rs`
- Modify: `crates/video-coach-core/src/lib.rs`

**Step 1: Implementation + ported tests**

```rust
// crates/video-coach-core/src/tag_aggregation.rs
use crate::project::Project;
use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq)]
pub struct TagSummary {
    pub tag: String,
    pub clip_count: usize,
    pub total_duration_seconds: f64,
}

pub fn aggregate(project: &Project) -> Vec<TagSummary> {
    let mut by_tag: BTreeMap<String, (usize, f64)> = BTreeMap::new();
    for clip in &project.clips {
        for tag in &clip.tags {
            let entry = by_tag.entry(tag.clone()).or_insert((0, 0.0));
            entry.0 += 1;
            entry.1 += clip.recording_duration;
        }
    }
    by_tag.into_iter()
        .map(|(tag, (count, dur))| TagSummary { tag, clip_count: count, total_duration_seconds: dur })
        .collect() // BTreeMap iteration is already sorted by key
}

#[cfg(test)]
mod tests {
    // PORT all cases from TagAggregationTests.swift.
}
```

Wire into `lib.rs`:

```rust
pub mod tag_aggregation;
```

**Step 2: Run tests**

Run: `cargo test -p video-coach-core tag_aggregation::`
Expected: all pass.

**Step 3: Commit**

```bash
git add crates/video-coach-core/src/tag_aggregation.rs crates/video-coach-core/src/lib.rs
git commit -m "feat(core): port TagAggregation"
```

---

## Task 8: Port `ExportSettings`

**Source:** `VideoCoachCore/Sources/VideoCoachCore/ExportSettings.swift` (25 lines).
**Reference tests:** `VideoCoachCore/Tests/VideoCoachCoreTests/ExportSettingsTests.swift`.

**Files:**
- Create: `crates/video-coach-core/src/export_settings.rs`
- Modify: `crates/video-coach-core/src/lib.rs`

**Step 1: Implementation + tests**

```rust
// crates/video-coach-core/src/export_settings.rs
use crate::project::{Quality, Resolution};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PixelSize { pub width: u32, pub height: u32 }

pub fn bitrate(resolution: Resolution, quality: Quality) -> u32 {
    let base_1080 = match quality {
        Quality::Low    => 6_000_000,
        Quality::Medium => 12_000_000,
        Quality::High   => 24_000_000,
    };
    match resolution {
        Resolution::Source | Resolution::R1080 => base_1080,
        Resolution::R720                       => base_1080 / 2,
    }
}

pub fn pixel_size(resolution: Resolution) -> PixelSize {
    match resolution {
        Resolution::Source | Resolution::R1080 => PixelSize { width: 1920, height: 1080 },
        Resolution::R720                       => PixelSize { width: 1280, height: 720 },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::{Quality, Resolution};

    #[test]
    fn medium_1080_bitrate_matches_swift() {
        assert_eq!(bitrate(Resolution::R1080, Quality::Medium), 12_000_000);
    }

    #[test]
    fn r720_halves_bitrate() {
        assert_eq!(bitrate(Resolution::R720, Quality::High), 12_000_000);
    }

    // PORT remaining cases from ExportSettingsTests.swift.
}
```

Wire into `lib.rs`:

```rust
pub mod export_settings;
```

**Step 2: Run tests**

Run: `cargo test -p video-coach-core export_settings::`
Expected: all pass.

**Step 3: Commit**

```bash
git add crates/video-coach-core/src/export_settings.rs crates/video-coach-core/src/lib.rs
git commit -m "feat(core): port ExportSettings (HEVC bitrate table)"
```

---

## Task 9: Port `Denormalize` (no CoreGraphics)

**Source:** `VideoCoachCore/Sources/VideoCoachCore/Denormalize.swift` (24 lines).

**Files:**
- Create: `crates/video-coach-core/src/denormalize.rs`
- Modify: `crates/video-coach-core/src/lib.rs`

**Note:** Drop `CGSize`/`CGPoint` — use plain `f64` tuples. The `flipY` knob stays exactly as in v1; it's a load-bearing footgun that the export compositor depends on.

**Step 1: Implementation + tests**

```rust
// crates/video-coach-core/src/denormalize.rs

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PixelPoint { pub x: f64, pub y: f64 }

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PixelSize { pub width: f64, pub height: f64 }

/// Map a normalized (top-left origin, x and y in 0..1) stroke point into pixels.
///
/// `flip_y = true` for live overlays in a bottom-left-origin coordinate space.
/// `flip_y = false` for the export compositor, which already applies its own flip.
/// See `docs/plans/2026-04-27-video-coach-design.md` § "Drawing capture".
pub fn point(x: f64, y: f64, into: PixelSize, flip_y: bool) -> PixelPoint {
    let px = x * into.width;
    let py = y * into.height;
    if flip_y { PixelPoint { x: px, y: into.height - py } }
    else      { PixelPoint { x: px, y: py } }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_flip_passes_through() {
        let p = point(0.5, 0.5, PixelSize { width: 1920.0, height: 1080.0 }, false);
        assert_eq!(p, PixelPoint { x: 960.0, y: 540.0 });
    }

    #[test]
    fn flip_inverts_y() {
        let p = point(0.0, 0.0, PixelSize { width: 1920.0, height: 1080.0 }, true);
        assert_eq!(p, PixelPoint { x: 0.0, y: 1080.0 });
    }
}
```

Wire into `lib.rs`:

```rust
pub mod denormalize;
```

**Step 2: Run tests**

Run: `cargo test -p video-coach-core denormalize::`
Expected: 2 passed.

**Step 3: Commit**

```bash
git add crates/video-coach-core/src/denormalize.rs crates/video-coach-core/src/lib.rs
git commit -m "feat(core): port Denormalize (stroke point → pixel coords)"
```

---

## Task 10: Port `CompilationPlan`

**Source:** `VideoCoachCore/Sources/VideoCoachCore/CompilationPlan.swift` (82 lines).
**Reference tests:** `VideoCoachCore/Tests/VideoCoachCoreTests/CompilationPlanTests.swift`.

**Files:**
- Create: `crates/video-coach-core/src/compilation_plan.rs`
- Modify: `crates/video-coach-core/src/lib.rs`

**Step 1: Read the Swift tests**

Run: `cat VideoCoachCore/Tests/VideoCoachCoreTests/CompilationPlanTests.swift`

**Step 2: Implementation**

```rust
// crates/video-coach-core/src/compilation_plan.rs
use std::collections::HashMap;
use uuid::Uuid;
use crate::project::{Clip, Project};
use crate::timeline::{playback_segments, PlaybackSegment};

#[derive(Debug, Clone, PartialEq)]
pub struct CompilationEntry {
    pub clip_id: Uuid,
    pub index_in_output: usize,
    pub composition_start: f64,
    pub segments: Vec<PlaybackSegment>,
    pub recording_duration: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct CompilationPlan {
    pub total_duration_seconds: f64,
    pub entries: Vec<CompilationEntry>,
}

impl Project {
    pub fn compilation_plan_for(&self, tag: &str, source_durations: &HashMap<usize, f64>) -> CompilationPlan {
        let filtered: Vec<&Clip> = self.clips.iter()
            .filter(|c| c.tags.iter().any(|t| t == tag))
            .collect();
        build_plan(&filtered, source_durations)
    }

    pub fn all_clips_compilation_plan(&self, source_durations: &HashMap<usize, f64>) -> CompilationPlan {
        let all: Vec<&Clip> = self.clips.iter().collect();
        build_plan(&all, source_durations)
    }
}

fn build_plan(clips: &[&Clip], source_durations: &HashMap<usize, f64>) -> CompilationPlan {
    let mut ordered: Vec<&Clip> = clips.iter().copied().collect();
    ordered.sort_by_key(|c| c.sort_index);
    let mut entries = Vec::with_capacity(ordered.len());
    let mut cursor = 0.0_f64;
    for (i, clip) in ordered.iter().enumerate() {
        let source_duration = source_durations.get(&clip.source_index)
            .copied()
            .unwrap_or(clip.start_source_seconds + clip.recording_duration);
        let segments = playback_segments(clip, source_duration);
        entries.push(CompilationEntry {
            clip_id: clip.id,
            index_in_output: i,
            composition_start: cursor,
            segments,
            recording_duration: clip.recording_duration,
        });
        cursor += clip.recording_duration;
    }
    CompilationPlan { total_duration_seconds: cursor, entries }
}

#[cfg(test)]
mod tests {
    // PORT every CompilationPlanTests.swift case verbatim.
}
```

Wire into `lib.rs`:

```rust
pub mod compilation_plan;
```

**Step 3: Run tests**

Run: `cargo test -p video-coach-core compilation_plan::`
Expected: all pass.

**Step 4: Commit**

```bash
git add crates/video-coach-core/src/compilation_plan.rs crates/video-coach-core/src/lib.rs
git commit -m "feat(core): port CompilationPlan builder"
```

---

## Task 11: Port `ProjectStore` (atomic `project.json` IO)

**Source:** `VideoCoachCore/Sources/VideoCoachCore/ProjectStore.swift` (50 lines).
**Reference tests:** `VideoCoachCore/Tests/VideoCoachCoreTests/ProjectStoreTests.swift`.

**Files:**
- Create: `crates/video-coach-core/src/project_store.rs`
- Modify: `crates/video-coach-core/src/lib.rs`

**Schema enforcement:** v2 only opens `formatVersion == 2`. v1 projects raise `UnsupportedFormatVersion`.

**Step 1: Implementation**

```rust
// crates/video-coach-core/src/project_store.rs
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use thiserror::Error;
use crate::project::Project;

pub const PROJECT_FILE_NAME: &str = "project.json";
pub const RECORDINGS_DIR_NAME: &str = "recordings";

#[derive(Debug, Error)]
pub enum ProjectStoreError {
    #[error("project.json not found in {0}")]
    MissingProjectJson(PathBuf),
    #[error("unsupported formatVersion {0} (this build only opens v{})", Project::FORMAT_VERSION)]
    UnsupportedFormatVersion(i32),
    #[error("io error: {0}")]
    Io(#[from] io::Error),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
}

pub fn read(folder: &Path) -> Result<Project, ProjectStoreError> {
    let url = folder.join(PROJECT_FILE_NAME);
    if !url.exists() {
        return Err(ProjectStoreError::MissingProjectJson(folder.to_path_buf()));
    }
    let data = fs::read(&url)?;
    let project: Project = serde_json::from_slice(&data)?;
    if project.format_version != Project::FORMAT_VERSION {
        return Err(ProjectStoreError::UnsupportedFormatVersion(project.format_version));
    }
    Ok(project)
}

pub fn write(project: &Project, folder: &Path) -> Result<(), ProjectStoreError> {
    fs::create_dir_all(folder)?;
    fs::create_dir_all(folder.join(RECORDINGS_DIR_NAME))?;

    let target = folder.join(PROJECT_FILE_NAME);
    let tmp = folder.join("project.json.tmp");

    // Pretty-printed, sorted keys — matches v1 Swift `JSONEncoder` settings.
    let data = serde_json::to_vec_pretty(project)?;
    fs::write(&tmp, &data)?;
    if target.exists() { fs::remove_file(&target)?; }
    fs::rename(&tmp, &target)?;
    Ok(())
}

pub fn recordings_dir(folder: &Path) -> PathBuf {
    folder.join(RECORDINGS_DIR_NAME)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn write_then_read_roundtrips() {
        let dir = TempDir::new().unwrap();
        let p = Project::new("Roundtrip");
        write(&p, dir.path()).unwrap();
        let back = read(dir.path()).unwrap();
        assert_eq!(p, back);
    }

    #[test]
    fn read_missing_returns_typed_error() {
        let dir = TempDir::new().unwrap();
        match read(dir.path()) {
            Err(ProjectStoreError::MissingProjectJson(_)) => {}
            other => panic!("expected MissingProjectJson, got {:?}", other),
        }
    }

    #[test]
    fn read_v1_project_returns_unsupported_format_error() {
        let dir = TempDir::new().unwrap();
        let v1 = serde_json::json!({
            "formatVersion": 1,
            "name": "old",
            "sourceVideos": [],
            "clips": [],
            "preferences": {
                "scanVolume": 1.0, "previewSourceVolume": 1.0, "previewCommentaryVolume": 1.0,
                "lastExportResolution": "r1080", "lastExportQuality": "medium",
                "preferredCameraId": null, "preferredMicId": null
            }
        });
        std::fs::write(dir.path().join("project.json"), serde_json::to_vec(&v1).unwrap()).unwrap();
        match read(dir.path()) {
            Err(ProjectStoreError::UnsupportedFormatVersion(1)) => {}
            other => panic!("expected UnsupportedFormatVersion(1), got {:?}", other),
        }
    }

    #[test]
    fn write_creates_recordings_subdir() {
        let dir = TempDir::new().unwrap();
        let p = Project::new("WithRecordings");
        write(&p, dir.path()).unwrap();
        assert!(dir.path().join(RECORDINGS_DIR_NAME).is_dir());
    }
}
```

**Step 2: Add `tempfile` as dev-dependency**

Modify `crates/video-coach-core/Cargo.toml`:

```toml
[dev-dependencies]
tempfile = "3"
```

Wire into `lib.rs`:

```rust
pub mod project_store;
```

**Step 3: Run tests**

Run: `cargo test -p video-coach-core project_store::`
Expected: 4 passed.

**Step 4: Commit**

```bash
git add crates/video-coach-core/src/project_store.rs crates/video-coach-core/src/lib.rs crates/video-coach-core/Cargo.toml
git commit -m "feat(core): port ProjectStore (atomic project.json IO, v2-only)"
```

---

## Task 12: CI matrix — macOS, Windows, Linux

**Files:**
- Create: `.github/workflows/rust.yml`

**Step 1: Write the workflow**

```yaml
# .github/workflows/rust.yml
name: rust
on:
  push:
    branches: [main, rust-rewrite]
  pull_request:
jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        os: [macos-latest, windows-latest, ubuntu-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with:
          components: rustfmt, clippy
      - uses: Swatinem/rust-cache@v2
      - run: cargo fmt --check
      - run: cargo clippy --workspace --all-targets -- -D warnings
      - run: cargo test --workspace
```

**Step 2: Push and verify**

```bash
git add .github/workflows/rust.yml
git commit -m "ci: cargo fmt + clippy + test on macOS / Windows / Linux"
git push -u origin rust-rewrite
```

Then check GitHub Actions:
Expected: all three OS jobs green. If any fail, fix before declaring Phase 1 complete.

---

## Phase 1 exit criteria

- All tasks committed.
- `cargo test --workspace` green on all three platforms in CI.
- `cargo clippy --workspace --all-targets -- -D warnings` green.
- `cargo fmt --check` green.
- `crates/video-coach-core/` is a faithful port of v1's `VideoCoachCore` excluding the AVFoundation-bound files (`AssetTracks.swift`, `CompilationCompositor.swift`, `CompilationExporter.swift`, `CompilationInstruction.swift`).
- `Project::FORMAT_VERSION = 2` and `SourceRef.relative_path` replace v1 fields cleanly.

When this is green, Phase 2 (GStreamer capture pipeline) gets its own plan.
