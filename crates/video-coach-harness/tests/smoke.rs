use std::time::Duration;
use video_coach_harness::App;

#[tokio::test]
async fn launch_ping_quit_roundtrip() -> anyhow::Result<()> {
    // App::launch() returning successfully already proves the app started
    // (it parsed `control_socket.ready` from stdout). We do NOT assert on
    // `app.launched` because it may have been emitted before the harness
    // connected to the socket — there's a real race between stdout reading
    // and TCP connection establishment.
    let mut app = App::launch().await?;

    // Send a ping. Both the reply and the resulting `app.ping` event are
    // emitted strictly after the socket connection exists, so they are
    // race-free observations.
    let reply = app.send(serde_json::json!({ "cmd": "ping" })).await?;
    assert_eq!(reply.ok, Some(true), "ping should succeed");
    app.wait_for_event("app.ping", Duration::from_secs(2))
        .await?;

    // Quit and verify clean exit.
    let status = app.quit().await?;
    assert!(
        status.success(),
        "app should exit cleanly, got {:?}",
        status
    );
    Ok(())
}
