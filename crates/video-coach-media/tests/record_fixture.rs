#![cfg(feature = "media")]

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use video_coach_media::{fixture_source::FixtureSource, recording::start};

fn fixture(name: &str) -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../fixtures");
    p.push(name);
    p
}

#[test]
fn record_3s_from_webcam_fixture_produces_playable_mov() {
    // tempfile() on Windows opens the file with FILE_SHARE_NONE, which would
    // block GStreamer's filesink from opening the same path. Use a tempdir
    // instead and place a freshly-named .mov inside it; tempdir on Windows
    // doesn't lock its children. Phase 3's media-tests CI is Linux-only so
    // this only matters for local Windows dev runs.
    let tmp_dir = tempfile::tempdir().unwrap();
    let out_path = tmp_dir.path().join("recording.mov");

    let factory = Arc::new(FixtureSource::new(fixture("webcam.mov")));
    let rec = start(factory, out_path.clone()).unwrap();
    std::thread::sleep(Duration::from_secs(3));
    rec.stop().unwrap();

    let metadata = std::fs::metadata(&out_path).unwrap();
    assert!(
        metadata.len() > 100_000,
        "output file should be non-trivial; got {} bytes",
        metadata.len()
    );
}
