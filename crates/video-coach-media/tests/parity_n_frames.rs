//! Phase 10 Task 5 — full N-frame preview-vs-export parity.
//!
//! Per fix #21 (revised): the parity test does NOT compare preview's
//! live-decoded frames against export's. Preview's `appsink.sync=true`
//! real-time decode races against the deterministic frame-by-record-time
//! path — the same clip can produce different captured frames at
//! preview-tick N depending on decoder warmup, GPU clock state, etc.
//!
//! The right contract: `compose_entry_frame` is **deterministic** given
//! the same inputs. Both preview's driver and export's driver call it.
//! This test calls it twice over N record_times and asserts the two
//! output sequences match byte-for-byte.
//!
//! N=30 (1 second at 30 fps) is sufficient for catching divergence
//! regressions; longer runs hit diminishing returns. Phase 11 may add an
//! end-to-end "render preview to file + render export to file +
//! bit-compare the two .mp4s" check, but that's a fundamentally
//! different test (it travels through H.264 encode + qtmux + filesystem)
//! and lives separately.

#![cfg(feature = "media")]

use std::collections::HashMap;
use uuid::Uuid;

use video_coach_compositor::{Compositor, Frame};
use video_coach_core::{
    compilation_plan::CompilationEntry,
    event::{CommentaryEvent, EventKind},
    project::Clip,
    stroke::{Rgba, Stroke, StrokePoint},
    timeline::playback_segments,
};
use video_coach_media::export::compose_entry_frame;

/// Build a hand-rolled clip with Pause + Play segments + a Stroke event,
/// so segment-walking + visible_strokes both exercise.
fn smoke_clip() -> Clip {
    let stroke = Stroke {
        id: Uuid::nil(),
        color: Rgba::RED,
        line_width: 0.012,
        points: vec![
            StrokePoint {
                x: 0.20,
                y: 0.50,
                t: 0.0,
            },
            StrokePoint {
                x: 0.80,
                y: 0.50,
                t: 0.10,
            },
        ],
        auto_clear_after_seconds: None,
    };
    Clip {
        id: Uuid::new_v4(),
        name: "parity-test-clip".into(),
        notes: String::new(),
        tags: vec![],
        source_index: 0,
        start_source_seconds: 5.0,
        // 1.5s recording duration: 0.0–0.4s Play, 0.4–0.6s Pause (Freeze
        // segment), 0.6–1.5s Play. Stroke at record_time 0.05 visible
        // through the rest of the clip.
        recording_duration: 1.5,
        recording_filename: "parity.mov".into(),
        events: vec![
            CommentaryEvent {
                record_time: 0.05,
                kind: EventKind::Stroke(stroke),
            },
            CommentaryEvent {
                record_time: 0.40,
                kind: EventKind::Pause,
            },
            CommentaryEvent {
                record_time: 0.60,
                kind: EventKind::Play,
            },
        ],
        sort_index: 0,
        created_at: chrono::Utc::now(),
    }
}

fn solid_source() -> Frame {
    Frame::solid(640, 360, [128, 64, 200, 255])
}

fn solid_webcam() -> Frame {
    Frame::solid(160, 90, [64, 200, 64, 255])
}

fn frozen_frame_for_freeze_seg() -> Frame {
    // Distinct colour from the live source to make divergences visible
    // if a frame is sourced incorrectly across paths.
    Frame::solid(640, 360, [200, 200, 64, 255])
}

#[test]
fn n_frames_of_compose_entry_frame_match_byte_for_byte() {
    let compositor = Compositor::new_headless().expect("headless compositor");
    let clip = smoke_clip();

    let mut source_durations = HashMap::new();
    source_durations.insert(0_usize, 60.0_f64);
    let segments = playback_segments(&clip, 60.0);
    let entry = CompilationEntry {
        clip_id: clip.id,
        index_in_output: 0,
        composition_start: 0.0,
        segments,
        recording_duration: clip.recording_duration,
    };

    // Pre-decoded freeze frames per (entry, freeze_segment_index). Per
    // fix #11 the production driver pre-decodes one frame per Freeze;
    // for the parity test we just hand-roll a solid frame for whichever
    // segments are Freeze. Walk entry.segments to populate.
    let mut frozen_frames: HashMap<usize, Frame> = HashMap::new();
    for (i, seg) in entry.segments.iter().enumerate() {
        if matches!(seg.kind, video_coach_core::timeline::SegmentKind::Freeze) {
            frozen_frames.insert(i, frozen_frame_for_freeze_seg());
        }
    }

    let source = solid_source();
    let webcam = solid_webcam();

    const N: usize = 30; // 1s at 30 fps
    const TICK_NS: u64 = 33_333_333;

    let mut path_a: Vec<Frame> = Vec::with_capacity(N);
    let mut path_b: Vec<Frame> = Vec::with_capacity(N);

    for path in [&mut path_a, &mut path_b] {
        for i in 0..N {
            let record_time = (i as u64 * TICK_NS) as f64 / 1e9;
            let f = compose_entry_frame(
                &compositor,
                &entry,
                &clip,
                record_time,
                &source,
                &webcam,
                &frozen_frames,
            )
            .expect("compose_entry_frame");
            path.push(f);
        }
    }

    assert_eq!(
        path_a.len(),
        path_b.len(),
        "path_a / path_b should have the same frame count",
    );
    for i in 0..N {
        let a = &path_a[i];
        let b = &path_b[i];
        assert_eq!(
            a.width, b.width,
            "frame {i} width mismatch: a={} b={}",
            a.width, b.width
        );
        assert_eq!(
            a.height, b.height,
            "frame {i} height mismatch: a={} b={}",
            a.height, b.height
        );
        assert_eq!(
            a.pixels.len(),
            b.pixels.len(),
            "frame {i} pixel buffer size mismatch",
        );
        // Per fix #40: Frame derives PartialEq, so we can compare the
        // whole struct directly. If byte-for-byte proves flaky on some
        // GPU stack (wgpu cache state across back-to-back composes —
        // Phase 9 closeout flagged this risk), downgrade to ±2/channel
        // tolerance per sampled pixel.
        assert_eq!(
            a,
            b,
            "frame {i} byte-mismatch between path A and path B (record_time={})",
            (i as u64 * TICK_NS) as f64 / 1e9,
        );
    }
}
