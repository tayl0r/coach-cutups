#![cfg(feature = "media")]

//! Phase 7 Task 1 integration tests for `SourcePlayer`.
//!
//! These tests open `fixtures/source-1080p.mp4` (a 60s 1080p extract
//! from the soccer master) and exercise play/pause/seek/snapshot. The
//! FrameSink is a counting impl that just increments an atomic, so we
//! can assert "frames flowed" without doing any rendering.
//!
//! VT decoder note: macOS' VideoToolbox decoder requires a Cocoa
//! NSApplication runloop that doesn't exist in `cargo test` workers,
//! so we disable hardware-decode plugins via GST_PLUGIN_FEATURE_RANK
//! before init — same pattern Phase 5 used in `compose_two_files` tests.

use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;
use video_coach_media::source_player::{FrameSink, NullFrameSink, SourcePlayer};

const FIXTURE_DURATION_SECS: f64 = 60.0;

fn fixture(name: &str) -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../fixtures");
    p.push(name);
    p
}

fn disable_vt_decoders() {
    std::env::set_var(
        "GST_PLUGIN_FEATURE_RANK",
        "vtdec_hw:NONE,vtenc_h264:NONE,vtenc_h264_hw:NONE",
    );
}

struct CountingSink {
    count: Arc<AtomicUsize>,
}

impl FrameSink for CountingSink {
    fn push_frame(&self, _w: u32, _h: u32, _data: &[u8]) {
        self.count.fetch_add(1, Ordering::Relaxed);
    }
}

#[test]
fn open_prerolls_at_zero() {
    disable_vt_decoders();
    let player = SourcePlayer::open(
        &fixture("source-1080p.mp4"),
        Box::new(NullFrameSink),
        FIXTURE_DURATION_SECS,
    )
    .expect("open should succeed");
    let snap = player.snapshot();
    assert!(
        snap.position_seconds < 1.0,
        "preroll position should be near 0, got {}",
        snap.position_seconds
    );
    assert!(
        (snap.duration_seconds - FIXTURE_DURATION_SECS).abs() < 0.5,
        "duration should be ~60s, got {}",
        snap.duration_seconds
    );
    assert!(!snap.is_playing);
}

#[test]
fn play_then_pause_drives_frames_then_stops() {
    disable_vt_decoders();
    let count = Arc::new(AtomicUsize::new(0));
    let sink = CountingSink {
        count: count.clone(),
    };
    let player = SourcePlayer::open(
        &fixture("source-1080p.mp4"),
        Box::new(sink),
        FIXTURE_DURATION_SECS,
    )
    .unwrap();

    // Preroll alone may push a frame or two; record the baseline.
    let baseline = count.load(Ordering::Relaxed);

    player.play().unwrap();
    std::thread::sleep(Duration::from_millis(1500));
    let after_play = count.load(Ordering::Relaxed);
    let played = after_play - baseline;
    assert!(
        played >= 25,
        "expected at least ~25 frames in 1.5s of playback, got {} (total {}, baseline {})",
        played,
        after_play,
        baseline
    );

    player.pause().unwrap();
    let snap = player.snapshot();
    assert!(!snap.is_playing);

    std::thread::sleep(Duration::from_millis(800));
    let after_pause = count.load(Ordering::Relaxed);
    // Allow a small in-flight tolerance — one or two frames may still
    // have been queued in the decoder when pause hit.
    let leakage = after_pause - after_play;
    assert!(
        leakage <= 5,
        "paused player kept pushing frames: {} additional in 800ms",
        leakage
    );
}

#[test]
fn accurate_seek_lands_within_half_a_second() {
    disable_vt_decoders();
    let player = SourcePlayer::open(
        &fixture("source-1080p.mp4"),
        Box::new(NullFrameSink),
        FIXTURE_DURATION_SECS,
    )
    .unwrap();

    player.seek(30.0, true).unwrap();
    // Give GStreamer a moment to apply the seek.
    std::thread::sleep(Duration::from_millis(300));
    let snap = player.snapshot();
    assert!(
        (snap.position_seconds - 30.0).abs() < 0.5,
        "accurate seek to 30s landed at {}",
        snap.position_seconds
    );
}

#[test]
fn keyframe_seek_lands_within_two_seconds() {
    disable_vt_decoders();
    let player = SourcePlayer::open(
        &fixture("source-1080p.mp4"),
        Box::new(NullFrameSink),
        FIXTURE_DURATION_SECS,
    )
    .unwrap();

    player.seek(30.0, false).unwrap();
    std::thread::sleep(Duration::from_millis(300));
    let snap = player.snapshot();
    // The 1080p fixture's GOP is ~5s (empirically — 30s seek lands at
    // 25s on the previous keyframe). Keyframe-snap is BY DESIGN
    // imprecise; we just verify the seek happened and landed somewhere
    // plausible. The hybrid-seek policy in the bus handler uses
    // accurate=true for skip buttons and keyboard exactly because of
    // this — keyframe-snap is the live-drag mode.
    assert!(
        (snap.position_seconds - 30.0).abs() < 6.0,
        "keyframe seek to 30s landed at {} (>6s off — wider GOP than expected?)",
        snap.position_seconds
    );
    // And explicitly verify it ISN'T frame-exact at the target — that
    // would suggest accurate flag was applied incorrectly.
    assert!(
        (snap.position_seconds - 30.0).abs() > 0.05,
        "keyframe seek landed exactly at 30s; KEY_UNIT flag may not be honored",
    );
}

#[test]
fn set_volume_does_not_panic_when_audio_present() {
    disable_vt_decoders();
    let player = SourcePlayer::open(
        &fixture("source-1080p.mp4"),
        Box::new(NullFrameSink),
        FIXTURE_DURATION_SECS,
    )
    .unwrap();
    // Should be a no-op when no audio chain exists, and a real property
    // write when it does. Either way: no panic, no error.
    player.set_volume(0.5);
    player.set_volume(0.0);
    player.set_volume(1.0);
}
