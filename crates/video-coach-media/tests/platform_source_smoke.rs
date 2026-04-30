//! Phase 8 Task 2. Manual smoke test for the `PlatformDefaultSource`.
//!
//! Records short clips of real webcam + microphone audio to temp .mov
//! files on the host machine, then asserts each file is non-trivial
//! (>10 KB). Gated by `cfg(target_os = "macos")` AND `#[ignore]` so CI
//! never runs it (no camera permission in CI). Run locally with:
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
//! The test loops start/stop several times because the `osxaudiosrc`
//! teardown race against CoreAudio's HAL IO thread is timing-dependent
//! — a single iteration may not surface it. A short loop is reliable
//! enough to use as a regression gate when touching `recording::stop`.

#![cfg(all(feature = "media", target_os = "macos"))]

use std::sync::Arc;
use std::time::Duration;
use video_coach_media::{platform_source::PlatformDefaultSource, recording::start};

#[test]
#[ignore]
fn platform_source_smoke_records_short_clip() {
    for iteration in 0..5 {
        let tmp_dir = tempfile::tempdir().unwrap();
        let out_path = tmp_dir.path().join(format!("platform-smoke-{iteration}.mov"));

        let factory = Arc::new(PlatformDefaultSource::new());
        let rec = start(factory, out_path.clone()).expect("start recording");
        std::thread::sleep(Duration::from_millis(500));
        rec.stop().expect("stop recording");

        let metadata = std::fs::metadata(&out_path).expect("output should exist");
        assert!(
            metadata.len() > 10_000,
            "iteration {iteration}: output should be >10 KB; got {} bytes",
            metadata.len()
        );
        eprintln!(
            "platform_source_smoke iter {iteration}: recorded {} bytes to {}",
            metadata.len(),
            out_path.display()
        );
    }
}
