use std::time::Duration;
use tempfile::TempDir;
use video_coach_harness::App;

/// End-to-end coverage of the `open_project` bus command:
/// build a minimal valid `project.json`, dispatch the command, and verify
/// the bus emits a `project.opened` event with the project's name.
///
/// This is the headless E2E test introduced in Phase 6 Task 4. It does
/// NOT exercise the UI menu item — that wiring lands in Task 5 and must
/// be smoke-tested manually until a virtual-display strategy ships
/// (Phase 11).
#[tokio::test]
async fn open_project_emits_event_with_name() -> anyhow::Result<()> {
    // Match Project's serde shape (camelCase). FORMAT_VERSION = 2.
    // Preferences mirrors Preferences::default(): scanVolume etc. = 1.0,
    // lastExportResolution = "r1080", lastExportQuality = "medium".
    let project_json = r#"{
        "formatVersion": 2,
        "name": "Phase 6 Smoke",
        "sourceVideos": [],
        "clips": [],
        "preferences": {
            "scanVolume": 1.0,
            "previewSourceVolume": 1.0,
            "previewCommentaryVolume": 1.0,
            "lastExportResolution": "r1080",
            "lastExportQuality": "medium",
            "preferredCameraId": null,
            "preferredMicId": null
        }
    }"#;

    let dir = TempDir::new()?;
    std::fs::write(dir.path().join("project.json"), project_json)?;

    let mut app = App::launch().await?;
    let reply = app
        .send(serde_json::json!({
            "cmd": "open_project",
            "path": dir.path().to_string_lossy(),
        }))
        .await?;
    assert_eq!(
        reply.ok,
        Some(true),
        "open_project should succeed; got error: {:?}",
        reply.error
    );

    let evt = app
        .wait_for_event("project.opened", Duration::from_secs(2))
        .await?;
    assert_eq!(
        evt.other.get("name").and_then(|v| v.as_str()),
        Some("Phase 6 Smoke"),
    );

    let status = app.quit().await?;
    assert!(
        status.success(),
        "app should exit cleanly, got {:?}",
        status
    );
    Ok(())
}

#[tokio::test]
async fn new_project_creates_and_opens() -> anyhow::Result<()> {
    let parent = TempDir::new()?;
    let project_path = parent.path().join("Phase 6 New");
    std::fs::create_dir(&project_path)?;

    let mut app = App::launch().await?;
    let reply = app
        .send(serde_json::json!({
            "cmd": "new_project",
            "path": project_path.to_string_lossy(),
        }))
        .await?;
    assert_eq!(
        reply.ok,
        Some(true),
        "new_project failed: {:?}",
        reply.error
    );

    let evt = app
        .wait_for_event("project.opened", Duration::from_secs(2))
        .await?;
    assert_eq!(
        evt.other.get("name").and_then(|v| v.as_str()),
        Some("Phase 6 New"),
    );
    assert_eq!(
        evt.other.get("created").and_then(|v| v.as_bool()),
        Some(true)
    );

    // Verify the on-disk artifacts exist.
    assert!(project_path.join("project.json").exists());
    assert!(project_path.join("recordings").is_dir());

    app.quit().await?;
    Ok(())
}

#[tokio::test]
async fn new_project_refuses_to_overwrite() -> anyhow::Result<()> {
    let parent = TempDir::new()?;
    let project_path = parent.path().join("AlreadyHere");
    std::fs::create_dir(&project_path)?;
    std::fs::write(project_path.join("project.json"), "{}")?; // existing sentinel

    let mut app = App::launch().await?;
    let reply = app
        .send(serde_json::json!({
            "cmd": "new_project",
            "path": project_path.to_string_lossy(),
        }))
        .await?;
    assert_eq!(reply.ok, Some(false));
    assert!(
        reply
            .error
            .as_deref()
            .unwrap_or("")
            .contains("already contains a project.json"),
        "expected refuse-to-overwrite error, got: {:?}",
        reply.error
    );

    app.quit().await?;
    Ok(())
}

#[cfg(feature = "media")]
#[tokio::test]
async fn add_source_video_persists_to_disk() -> anyhow::Result<()> {
    use std::path::PathBuf;

    // Locate the source-1080p fixture relative to the workspace root.
    let mut fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    fixture.push("../../fixtures/source-1080p.mp4");
    let fixture = fixture.canonicalize()?;

    let parent = TempDir::new()?;
    let project_path = parent.path().join("phase7-source-test");
    std::fs::create_dir(&project_path)?;

    let mut app = App::launch().await?;

    // Create the project so AddSourceVideo has something to mutate.
    let create = app
        .send(serde_json::json!({
            "cmd": "new_project",
            "path": project_path.to_string_lossy(),
        }))
        .await?;
    assert_eq!(
        create.ok,
        Some(true),
        "new_project failed: {:?}",
        create.error
    );
    let _ = app
        .wait_for_event("project.opened", Duration::from_secs(2))
        .await?;

    // Add the fixture as a source video.
    let reply = app
        .send(serde_json::json!({
            "cmd": "add_source_video",
            "absolute_path": fixture.to_string_lossy(),
        }))
        .await?;
    assert_eq!(
        reply.ok,
        Some(true),
        "add_source_video failed: {:?}",
        reply.error
    );

    let evt = app
        .wait_for_event("source.added", Duration::from_secs(5))
        .await?;
    let duration = evt.other.get("duration_seconds").and_then(|v| v.as_f64());
    assert!(
        duration.is_some_and(|d| (d - 60.0).abs() < 1.0),
        "duration should be ~60s; got {:?}",
        duration
    );

    // Inspect the on-disk project.json to verify the SourceRef landed.
    let json = std::fs::read_to_string(project_path.join("project.json"))?;
    let parsed: serde_json::Value = serde_json::from_str(&json)?;
    let sources = parsed
        .get("sourceVideos")
        .and_then(|v| v.as_array())
        .expect("sourceVideos array");
    assert_eq!(sources.len(), 1, "expected exactly one source video");
    let rel = sources[0]
        .get("relativePath")
        .and_then(|v| v.as_str())
        .expect("relativePath");
    // Fixture lives outside the temp project folder, so the path
    // should start with `..` somewhere.
    assert!(
        rel.contains(".."),
        "relativePath should traverse out of project folder; got {rel:?}",
    );

    app.quit().await?;
    Ok(())
}

#[cfg(feature = "media")]
#[tokio::test]
async fn play_pause_seek_roundtrip_via_harness() -> anyhow::Result<()> {
    use std::path::PathBuf;

    let mut fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    fixture.push("../../fixtures/source-1080p.mp4");
    let fixture = fixture.canonicalize()?;

    let parent = TempDir::new()?;
    let project_path = parent.path().join("phase7-transport-test");
    std::fs::create_dir(&project_path)?;

    let mut app = App::launch().await?;

    let create = app
        .send(serde_json::json!({
            "cmd": "new_project",
            "path": project_path.to_string_lossy(),
        }))
        .await?;
    assert_eq!(
        create.ok,
        Some(true),
        "new_project failed: {:?}",
        create.error
    );
    let _ = app
        .wait_for_event("project.opened", Duration::from_secs(2))
        .await?;

    // Adding the first source should trigger the bus auto-spawn of a
    // SourcePlayer (Phase 7 Task 3 adversarial fix #3).
    let reply = app
        .send(serde_json::json!({
            "cmd": "add_source_video",
            "absolute_path": fixture.to_string_lossy(),
        }))
        .await?;
    assert_eq!(
        reply.ok,
        Some(true),
        "add_source_video failed: {:?}",
        reply.error
    );

    let opened = app
        .wait_for_event("player.opened", Duration::from_secs(10))
        .await?;
    let dur = opened
        .other
        .get("duration_seconds")
        .and_then(|v| v.as_f64());
    assert!(
        dur.is_some_and(|d| (d - 60.0).abs() < 1.0),
        "player.opened should report ~60s; got {:?}",
        dur
    );

    // Play, then wait briefly for frames to flow, then pause.
    let play_reply = app.send(serde_json::json!({"cmd": "play"})).await?;
    assert_eq!(
        play_reply.ok,
        Some(true),
        "play failed: {:?}",
        play_reply.error
    );
    app.wait_for_event("player.playing", Duration::from_secs(2))
        .await?;

    tokio::time::sleep(Duration::from_secs(1)).await;

    let pause_reply = app.send(serde_json::json!({"cmd": "pause"})).await?;
    assert_eq!(
        pause_reply.ok,
        Some(true),
        "pause failed: {:?}",
        pause_reply.error
    );
    app.wait_for_event("player.paused", Duration::from_secs(2))
        .await?;

    // Frame-exact seek to 5s.
    let seek_reply = app
        .send(serde_json::json!({
            "cmd": "seek",
            "seconds": 5.0,
            "accurate": true,
        }))
        .await?;
    assert_eq!(
        seek_reply.ok,
        Some(true),
        "seek failed: {:?}",
        seek_reply.error
    );
    let seeked = app
        .wait_for_event("player.seeked", Duration::from_secs(2))
        .await?;
    let landed = seeked.other.get("seconds").and_then(|v| v.as_f64());
    assert!(
        landed.is_some_and(|s| (s - 5.0).abs() < 0.001),
        "player.seeked should echo the requested time; got {:?}",
        landed
    );

    // SetScanVolume should round-trip cleanly (no event emitted; the
    // reply ok=true is the contract).
    let vol_reply = app
        .send(serde_json::json!({
            "cmd": "set_scan_volume",
            "value": 0.5,
        }))
        .await?;
    assert_eq!(
        vol_reply.ok,
        Some(true),
        "set_scan_volume failed: {:?}",
        vol_reply.error
    );

    app.quit().await?;
    Ok(())
}

#[tokio::test]
async fn play_without_source_returns_error() -> anyhow::Result<()> {
    let mut app = App::launch().await?;
    let reply = app.send(serde_json::json!({"cmd": "play"})).await?;
    assert_eq!(reply.ok, Some(false));
    // Default-features build has no media, so the error wording differs;
    // accept either shape.
    let err = reply.error.as_deref().unwrap_or("");
    assert!(
        err.contains("no source loaded") || err.contains("media feature disabled"),
        "unexpected play error wording: {err}",
    );
    app.quit().await?;
    Ok(())
}

#[tokio::test]
async fn open_project_missing_returns_error() -> anyhow::Result<()> {
    let dir = TempDir::new()?;
    // Don't create project.json — folder exists but is empty.

    let mut app = App::launch().await?;
    let reply = app
        .send(serde_json::json!({
            "cmd": "open_project",
            "path": dir.path().to_string_lossy(),
        }))
        .await?;
    assert_eq!(reply.ok, Some(false));
    assert!(
        reply
            .error
            .as_deref()
            .unwrap_or("")
            .contains("project.json not found"),
        "expected MissingProjectJson error, got: {:?}",
        reply.error
    );

    app.quit().await?;
    Ok(())
}
