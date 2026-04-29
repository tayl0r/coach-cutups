#![cfg(feature = "media")]

use std::path::PathBuf;
use std::time::Duration;
use video_coach_harness::App;

fn fixture(name: &str) -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("../../fixtures");
    p.push(name);
    p
}

#[tokio::test]
async fn record_from_fixture_via_harness() -> anyhow::Result<()> {
    let mut app = App::launch().await?;

    // Use a tempdir, not tempfile() — on Windows NamedTempFile holds an
    // exclusive open that would block GStreamer's filesink. Phase 3's
    // media-tests CI is Linux-only so this only matters for local dev.
    let tmp_dir = tempfile::tempdir()?;
    let out = tmp_dir.path().join("recording.mov");

    let reply = app
        .start_recording_from_fixture(
            fixture("webcam.mov").display().to_string(),
            out.display().to_string(),
        )
        .await?;
    assert_eq!(reply.ok, Some(true), "start_recording reply: {:?}", reply);

    app.wait_for_event("recording.started", Duration::from_secs(3))
        .await?;

    tokio::time::sleep(Duration::from_secs(3)).await;

    let reply = app.stop_recording().await?;
    assert_eq!(reply.ok, Some(true), "stop_recording reply: {:?}", reply);

    app.wait_for_event("recording.stopped", Duration::from_secs(5))
        .await?;

    let metadata = std::fs::metadata(&out)?;
    assert!(
        metadata.len() > 100_000,
        "output should be >=100KB, got {}",
        metadata.len()
    );

    let _ = app.quit().await?;
    Ok(())
}
