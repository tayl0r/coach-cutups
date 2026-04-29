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
    assert!(status.success(), "app should exit cleanly, got {:?}", status);
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
