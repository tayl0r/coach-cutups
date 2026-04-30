//! Phase 8 Task 2. Manual smoke test for the `PlatformDefaultSource`.
//!
//! Records ~1s of webcam + microphone audio to a temp .mov on the host
//! machine, then asserts the file is non-trivial (>10 KB). Gated by
//! `cfg(target_os = "macos")` AND `#[ignore]` so CI never runs it (no
//! camera permission in CI). Run locally with:
//!
//! ```sh
//! cargo test --features media -p video-coach-media -- \
//!     --ignored platform_source_smoke
//! ```
//!
//! On the first run macOS will prompt for camera + microphone
//! permission; granting both is required. On Deny the test panics with
//! a state-change error.
//!
//! Limitation: this test deadlocks when run under a plain `cargo test`
//! binary because `avfvideosrc` / `osxaudiosrc` need an NSApplication +
//! Cocoa main-thread / runloop (which Slint provides in the real app)
//! to actually deliver buffers — without it the streaming threads
//! block downstream and `pipeline.send_event(EOS)` deadlocks on stream
//! locks. So it doesn't catch teardown regressions on its own; the
//! authoritative validation for `recording::stop` changes is to
//! rebuild the app and exercise start/stop interactively.

#![cfg(all(feature = "media", target_os = "macos"))]

use std::sync::Arc;
use std::time::Duration;
use video_coach_media::{platform_source::PlatformDefaultSource, recording::start};

#[test]
#[ignore]
fn platform_source_smoke_records_short_clip() {
    let tmp_dir = tempfile::tempdir().unwrap();
    let out_path = tmp_dir.path().join("platform-smoke.mov");

    let factory = Arc::new(PlatformDefaultSource::new());
    let rec = start(factory, out_path.clone()).expect("start recording");
    std::thread::sleep(Duration::from_secs(1));
    rec.stop().expect("stop recording");

    let metadata = std::fs::metadata(&out_path).expect("output should exist");
    assert!(
        metadata.len() > 10_000,
        "output should be >10 KB; got {} bytes",
        metadata.len()
    );
    eprintln!(
        "platform_source_smoke: recorded {} bytes to {}",
        metadata.len(),
        out_path.display()
    );
}
