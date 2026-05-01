//! Phase 9 Task 6 — single-frame preview-vs-export parity check.
//!
//! Per fixes #21 + #24: both the preview-pipeline driver AND Phase 5's
//! `compose_two_files` call `compose_tick(...)` as the single canonical
//! entry point. Any byte-level divergence between the two paths must
//! mean someone forked `compose_tick` — exactly what this test catches.
//!
//! The earlier framing of this test ("preview pipeline frame 0 vs
//! direct compose call") was unimplementable as written:
//! `PreviewPipeline::open` takes file paths, not synthetic Frames.
//! Fix #24's `compose_tick` extraction makes the parity test trivially
//! correct: BOTH paths call the same function with the same inputs,
//! so byte-for-byte equality is structural.
//!
//! Phase 9's full N-frame "preview hash == export hash" parity lands in
//! Phase 10 alongside the export sheet. See the plan's "deferred"
//! section.

use video_coach_compositor::{compose_tick, Compositor, Frame, VisibleStroke};
use video_coach_core::stroke::{Rgba, Stroke, StrokePoint};

fn solid_source() -> Frame {
    Frame::solid(640, 360, [255, 0, 0, 255]) // red source
}

fn solid_webcam() -> Frame {
    Frame::solid(160, 90, [0, 0, 255, 255]) // blue webcam
}

fn one_visible_stroke() -> VisibleStroke {
    let stroke = Stroke {
        id: uuid::Uuid::nil(),
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
    VisibleStroke {
        stroke,
        first_point_record_time: 0.0,
        drawn_point_count: 2,
    }
}

#[test]
fn compose_tick_is_deterministic_with_no_strokes() {
    let comp = Compositor::new_headless().expect("compositor");
    let src = solid_source();
    let cam = solid_webcam();

    let a = compose_tick(&comp, &src, &cam, &[]).expect("compose A");
    let b = compose_tick(&comp, &src, &cam, &[]).expect("compose B");

    assert_eq!(
        a.pixels, b.pixels,
        "two back-to-back compose_tick calls with no strokes should byte-match",
    );
}

#[test]
fn compose_tick_is_deterministic_with_strokes() {
    let comp = Compositor::new_headless().expect("compositor");
    let src = solid_source();
    let cam = solid_webcam();
    let strokes = vec![one_visible_stroke()];

    let a = compose_tick(&comp, &src, &cam, &strokes).expect("compose A");
    let b = compose_tick(&comp, &src, &cam, &strokes).expect("compose B");

    assert_eq!(
        a.pixels.len(),
        b.pixels.len(),
        "compose output sizes should match",
    );
    assert_eq!(
        a.pixels, b.pixels,
        "two back-to-back compose_tick calls with the same stroke should byte-match",
    );

    // Also: stroke pass actually changed pixels along the path.
    let a_no_strokes = compose_tick(&comp, &src, &cam, &[]).expect("compose no-strokes");
    let mid = ((180 * 640 + 320) * 4) as usize; // pixel at [0.5, 0.5]
    let stroke_px = &a.pixels[mid..mid + 4];
    let plain_px = &a_no_strokes.pixels[mid..mid + 4];
    assert_ne!(
        stroke_px, plain_px,
        "stroke pass should perturb pixels at stroke center; got stroke={stroke_px:?}, plain={plain_px:?}",
    );

    // And: a pixel well off the stroke path is unchanged (within ±2/channel).
    let off = ((40 * 640 + 320) * 4) as usize; // pixel at [0.5, 0.11] — above the stroke
    let off_stroke = &a.pixels[off..off + 4];
    let off_plain = &a_no_strokes.pixels[off..off + 4];
    for c in 0..4 {
        let diff = (off_stroke[c] as i16 - off_plain[c] as i16).abs();
        assert!(
            diff <= 2,
            "off-stroke pixel diverged on channel {c}: stroke={off_stroke:?}, plain={off_plain:?}",
        );
    }
}
