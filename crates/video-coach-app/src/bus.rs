// Until the Slint UI in Phase 6 Task 2 dispatches commands through the bus,
// the no-default-features build (no control-socket, no UI consumer) leaves
// BusHandle::send dormant. Allow dead_code in that shape only.
#![cfg_attr(not(feature = "control-socket"), allow(dead_code))]

use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, oneshot};

/// Every external command and UI action flows through this enum.
/// The variant set grows as new features land.
#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum Command {
    Quit,
    /// Probe — replies with `{"ok": true}` and emits an `app.ping` event.
    /// Used by the harness smoke test.
    Ping,
    /// Start a recording. `source` selects fixture vs. production. `output`
    /// is the .mov path; the parent dir is auto-created.
    /// Only handled when the app is built with `--features media`; without
    /// it, the dispatcher returns an error.
    StartRecording {
        source: SourceConfig,
        output: String,
    },
    StopRecording,
    /// Open the project folder at `path`. Reads `<path>/project.json`,
    /// validates the format version, and stashes the parsed `Project` in
    /// the bus task's per-task state. Emits a `project.opened` event with
    /// the project's `name` field on success.
    OpenProject {
        path: String,
    },
    /// Create a fresh v2 project at `path`. Writes `<path>/project.json`
    /// and ensures `<path>/recordings/` exists. Project name is derived
    /// from the folder's basename. Refuses to overwrite if a
    /// `project.json` is already present. After creating, the new
    /// project becomes the current project (same effect as a subsequent
    /// OpenProject) and a `project.opened` event fires so the UI's
    /// post-open path can run unchanged.
    NewProject {
        path: String,
    },
    /// Phase 7. Adds a source video to the currently-open project.
    /// `absolute_path` points at the picked file on disk. The handler
    /// computes a relative path against the project folder (with `..`
    /// allowed), probes the file's duration, appends a SourceRef to
    /// `project.source_videos`, and persists. If the project had no
    /// active player yet, this also instantiates one.
    AddSourceVideo {
        absolute_path: String,
    },
    /// Phase 7. Resume the source player. Errors if no player is loaded.
    Play,
    /// Phase 7. Pause the source player. Errors if no player is loaded.
    Pause,
    /// Phase 7. Seek to absolute time `seconds` in the active source.
    /// `accurate=true` requests frame-exact seek (GST_SEEK_FLAG_ACCURATE);
    /// `accurate=false` snaps to the nearest keyframe (KEY_UNIT). The UI
    /// uses `accurate=false` during live slider drag for snappy preview
    /// and `accurate=true` on release / from skip buttons + keyboard.
    Seek {
        seconds: f64,
        accurate: bool,
    },
    /// Phase 7. Set the scan volume (source-playback audio level) on the
    /// active player. Range 0.0..=1.0. Live tick during slider drag;
    /// persistence to project.json happens on slider release via a
    /// separate command path.
    SetScanVolume {
        value: f64,
    },
    /// Phase 8. Begin a clip recording: pause the source player, snapshot
    /// the playhead, derive a clip filename + path under
    /// `<project>/recordings/`, and start the platform-default capture
    /// pipeline. `playhead_snapshot_seconds` is captured by the UI
    /// BEFORE this command is dispatched (adversarial fix #1) — the bus
    /// uses it directly as `start_source_seconds` rather than re-reading
    /// after the async `player.pause()` round-trip (which can take
    /// 10–200 ms during which the source has moved on).
    StartClipRecording {
        playhead_snapshot_seconds: f64,
    },
    /// Phase 8. Stop the active clip recording, flush the qtmux moov
    /// atom, finalize a `Clip` record, append it to `project.clips`,
    /// and persist `project.json`. Transitions mode back to Scanning.
    StopClipRecording,
    /// Phase 8. Append a stroke event to the in-progress clip
    /// recording's event log. `points_json` is a JSON-encoded array of
    /// `{ "x": f64, "y": f64, "t": f64 }` entries; coordinates are in
    /// `[0, 1]` against the displayed video rect (post-letterbox), `t`
    /// is seconds since the recording's `t0`. Errors if no clip
    /// recording is in progress (`current_mode != Recording`).
    AppendStroke {
        points_json: String,
    },
}

/// Phase 8. Mutually-exclusive UI/bus modes. Mirrors v1's
/// `App/Models/AppMode.swift` enum 1:1 (modulo preview cases which
/// land in Phase 9).
///
/// Used by the bus task as `current_mode` (Task 1) and serialized as a
/// string field on `mode.changed` events. The Task-0 stub for the new
/// commands doesn't reference it yet; the `dead_code` allow keeps the
/// no-default-features build warning-free until Task 1 lands.
#[allow(dead_code)]
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AppMode {
    /// Idle: source player is mounted, transport runs, R-press starts a
    /// recording.
    Scanning,
    /// `R` pressed: capture pipeline is being constructed (camera
    /// permission prompts may pop here on macOS first run). The
    /// transport bar shows a yellow "Preparing…" indicator. Mid-
    /// transition presses of `R` are ignored.
    RecordingStarting,
    /// Capture pipeline is recording; stroke events accumulate into the
    /// in-progress clip; second `R` press stops + finalizes the clip.
    Recording,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SourceConfig {
    /// Fixture file source — used by tests.
    Fixture { path: String },
    /// Default platform camera + mic — Phase 3 ships macOS only (not yet
    /// implemented; returns an error at dispatch).
    PlatformDefault,
}

/// A command paired with a reply channel.
pub struct Envelope {
    /// Echoed back as `reply_to` on the matching reply, and propagated as the
    /// originating id when forwarding events. Read in Task 6's tracing bridge.
    #[allow(dead_code)]
    pub id: String,
    pub command: Command,
    pub reply: oneshot::Sender<CommandReply>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct CommandReply {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Clone)]
pub struct BusHandle {
    tx: mpsc::Sender<Envelope>,
}

impl BusHandle {
    pub async fn send(&self, id: String, command: Command) -> CommandReply {
        let (reply_tx, reply_rx) = oneshot::channel();
        let env = Envelope {
            id,
            command,
            reply: reply_tx,
        };
        if self.tx.send(env).await.is_err() {
            return CommandReply {
                ok: false,
                error: Some("bus closed".into()),
            };
        }
        reply_rx.await.unwrap_or(CommandReply {
            ok: false,
            error: Some("reply dropped".into()),
        })
    }
}

/// Build a fresh `FrameSink` for a newly-spawned `SourcePlayer`. The bus
/// task can't hold a `slint::Weak` directly (UI types are not always
/// `Send`-friendly to bind to), so the UI hands the bus a factory at
/// startup which the bus invokes whenever it spawns a new player. For
/// headless builds (no UI), the factory yields `NullFrameSink` and frames
/// are dropped on the GStreamer streaming thread.
#[cfg(feature = "media")]
pub type FrameSinkFactory =
    std::sync::Arc<dyn Fn() -> Box<dyn video_coach_media::source_player::FrameSink> + Send + Sync>;

/// Spawn the bus task on the given tokio runtime handle. Phase 6 dropped
/// `#[tokio::main]` so the bus runs on the same multi-threaded runtime
/// that drives the control socket and any UI-dispatched async work.
pub fn spawn_on(
    rt: &tokio::runtime::Handle,
    shutdown_tx: tokio::sync::watch::Sender<bool>,
    #[cfg(feature = "media")] frame_sink_factory: FrameSinkFactory,
    #[cfg(feature = "media")] player_state: crate::frame_sink::PlayerStateSlot,
) -> BusHandle {
    let (tx, mut rx) = mpsc::channel::<Envelope>(64);
    #[cfg(feature = "media")]
    let rt_for_poll = rt.clone();
    #[cfg(feature = "media")]
    let shutdown_tx_for_poll = shutdown_tx.clone();
    rt.spawn(async move {
        // Per-task recording state. `None` until StartRecording succeeds;
        // taken by StopRecording. Held across loop iterations because start
        // and stop are necessarily separate commands.
        #[cfg(feature = "media")]
        let mut recording: Option<video_coach_media::recording::Recording> = None;

        // Per-task project state. `None` until OpenProject / NewProject
        // succeeds. Stored as (Project, project_folder) so subsequent
        // commands (Phase 7 AddSourceVideo, future ExportClip, etc.)
        // can resolve paths relative to the project folder and write
        // back to the same `project.json`.
        let mut current: Option<(video_coach_core::project::Project, std::path::PathBuf)> = None;

        // Phase 7: per-task source-player state. Spawned (in
        // spawn_blocking) when a project with `sourceVideos[0]` becomes
        // current. Played/paused/seeked by the bus's transport commands.
        // Held in an `Arc` so position-poll tasks (Task 5) can also read
        // a snapshot without blocking the bus loop.
        #[cfg(feature = "media")]
        let mut current_player: Option<
            std::sync::Arc<video_coach_media::source_player::SourcePlayer>,
        > = None;

        while let Some(env) = rx.recv().await {
            let reply = handle(
                env.command,
                &shutdown_tx,
                #[cfg(feature = "media")]
                &mut recording,
                &mut current,
                #[cfg(feature = "media")]
                &mut current_player,
                #[cfg(feature = "media")]
                &frame_sink_factory,
                #[cfg(feature = "media")]
                &rt_for_poll,
                #[cfg(feature = "media")]
                &shutdown_tx_for_poll,
                #[cfg(feature = "media")]
                &player_state,
            )
            .await;
            let _ = env.reply.send(reply);
        }
    });
    BusHandle { tx }
}

/// Phase 7 Task 5. Position-polling task. Spawned alongside each
/// SourcePlayer; reads `snapshot()` every 100 ms and writes the result
/// to the shared `PlayerStateSlot`. Runs until `shutdown_rx` fires —
/// for the MVP we don't support multiple players, so a single
/// long-lived task is correct. (When swap-player lands in Phase 7.5+
/// this will need an AbortHandle to cancel the old task.)
#[cfg(feature = "media")]
fn spawn_position_poll(
    rt: &tokio::runtime::Handle,
    player: std::sync::Arc<video_coach_media::source_player::SourcePlayer>,
    state: crate::frame_sink::PlayerStateSlot,
    mut shutdown_rx: tokio::sync::watch::Receiver<bool>,
) {
    rt.spawn(async move {
        let mut tick = tokio::time::interval(std::time::Duration::from_millis(100));
        // Skip the initial tick — `interval` fires immediately on
        // creation; we want the first poll to happen after 100ms so
        // GStreamer has had time to publish a position.
        tick.tick().await;
        loop {
            tokio::select! {
                _ = tick.tick() => {
                    let snap = player.snapshot();
                    let mut guard = state.lock().expect("player_state poisoned");
                    // Suppress one cycle after a recent seek (200 ms
                    // window — the decoder typically delivers its
                    // first post-seek buffer well within that).
                    let suppress = guard
                        .last_seek_at
                        .map(|t| t.elapsed() < std::time::Duration::from_millis(200))
                        .unwrap_or(false);
                    if !suppress {
                        guard.position_seconds = snap.position_seconds;
                    }
                    guard.duration_seconds = snap.duration_seconds;
                    guard.is_playing = snap.is_playing;
                }
                _ = shutdown_rx.changed() => {
                    if *shutdown_rx.borrow() {
                        break;
                    }
                }
            }
        }
    });
}

#[allow(clippy::too_many_arguments)]
async fn handle(
    cmd: Command,
    shutdown_tx: &tokio::sync::watch::Sender<bool>,
    #[cfg(feature = "media")] recording: &mut Option<video_coach_media::recording::Recording>,
    current: &mut Option<(video_coach_core::project::Project, std::path::PathBuf)>,
    #[cfg(feature = "media")] current_player: &mut Option<
        std::sync::Arc<video_coach_media::source_player::SourcePlayer>,
    >,
    #[cfg(feature = "media")] frame_sink_factory: &FrameSinkFactory,
    #[cfg(feature = "media")] rt_for_poll: &tokio::runtime::Handle,
    #[cfg(feature = "media")] shutdown_tx_for_poll: &tokio::sync::watch::Sender<bool>,
    #[cfg(feature = "media")] player_state: &crate::frame_sink::PlayerStateSlot,
) -> CommandReply {
    match cmd {
        Command::Quit => {
            tracing::info!(target: "app.lifecycle", event = "app.shutdown_requested");
            let _ = shutdown_tx.send(true);
            // When a Slint UI is running on the main thread, the watch on
            // shutdown_rx in ui::run also calls quit_event_loop. Calling it
            // here too is a belt-and-suspenders no-op when no event loop
            // is active (e.g. --headless), and it shaves the shutdown
            // latency by one tokio scheduling round-trip when the UI is up.
            // quit_event_loop is documented as thread-safe in Slint 1.8.
            let _ = slint::quit_event_loop();
            CommandReply {
                ok: true,
                error: None,
            }
        }
        Command::Ping => {
            tracing::info!(target: "app.lifecycle", event = "app.ping");
            CommandReply {
                ok: true,
                error: None,
            }
        }
        Command::StartRecording { source, output } => {
            #[cfg(not(feature = "media"))]
            {
                let _ = (source, output);
                CommandReply {
                    ok: false,
                    error: Some("media feature disabled in this build".into()),
                }
            }
            #[cfg(feature = "media")]
            {
                use std::sync::Arc;
                use video_coach_media::fixture_source::FixtureSource;
                use video_coach_media::source::CaptureSourceFactory;

                if recording.is_some() {
                    return CommandReply {
                        ok: false,
                        error: Some("already recording".into()),
                    };
                }
                let factory: Arc<dyn CaptureSourceFactory> = match source {
                    SourceConfig::Fixture { path } => Arc::new(FixtureSource::new(path)),
                    SourceConfig::PlatformDefault => {
                        return CommandReply {
                            ok: false,
                            error: Some("platform default source not yet implemented".into()),
                        };
                    }
                };
                match video_coach_media::recording::start(factory, output.into()) {
                    Ok(rec) => {
                        *recording = Some(rec);
                        CommandReply {
                            ok: true,
                            error: None,
                        }
                    }
                    Err(e) => CommandReply {
                        ok: false,
                        error: Some(e.to_string()),
                    },
                }
            }
        }
        Command::StopRecording => {
            #[cfg(not(feature = "media"))]
            {
                CommandReply {
                    ok: false,
                    error: Some("media feature disabled in this build".into()),
                }
            }
            #[cfg(feature = "media")]
            {
                match recording.take() {
                    Some(rec) => {
                        // Recording::stop blocks for up to 5s waiting on a
                        // GStreamer bus message. Offload to a blocking pool
                        // so we don't stall the tokio executor thread.
                        let result = tokio::task::spawn_blocking(move || rec.stop()).await;
                        match result {
                            Ok(Ok(())) => CommandReply {
                                ok: true,
                                error: None,
                            },
                            Ok(Err(e)) => CommandReply {
                                ok: false,
                                error: Some(e.to_string()),
                            },
                            Err(join) => CommandReply {
                                ok: false,
                                error: Some(format!("join: {join}")),
                            },
                        }
                    }
                    None => CommandReply {
                        ok: false,
                        error: Some("no active recording".into()),
                    },
                }
            }
        }
        Command::NewProject { path } => {
            let folder = normalize_project_folder(&path);
            // Canonicalize ahead of pathdiff math (Phase 7 AddSourceVideo
            // stores paths relative to this folder). Required on macOS
            // where `/tmp` is a symlink to `/private/tmp` — non-canonical
            // folder + canonical source produces a relative path with the
            // wrong number of `..` segments and filesrc can't open it.
            // For NewProject the folder may not exist yet, so canonicalize
            // the parent and rejoin the basename.
            let folder = match folder.parent().and_then(|p| {
                p.canonicalize()
                    .ok()
                    .and_then(|cp| folder.file_name().map(|name| cp.join(name)))
            }) {
                Some(c) => c,
                None => folder,
            };
            let folder_for_blocking = folder.clone();
            let result = tokio::task::spawn_blocking(
                move || -> Result<video_coach_core::project::Project, String> {
                    if folder_for_blocking.join("project.json").exists() {
                        return Err(format!(
                            "{} already contains a project.json — refusing to overwrite",
                            folder_for_blocking.display()
                        ));
                    }
                    let name = folder_for_blocking
                        .file_name()
                        .and_then(|s| s.to_str())
                        .unwrap_or("Untitled")
                        .to_string();
                    let project = video_coach_core::project::Project::new(name);
                    video_coach_core::project_store::write(&project, &folder_for_blocking)
                        .map_err(|e| e.to_string())?;
                    Ok(project)
                },
            )
            .await;
            match result {
                Ok(Ok(project)) => {
                    tracing::info!(
                        target: "project.lifecycle",
                        event = "project.opened",
                        path = %path,
                        name = %project.name,
                        created = true,
                    );
                    *current = Some((project, folder));
                    #[cfg(feature = "media")]
                    {
                        try_spawn_current_player(
                            current,
                            current_player,
                            frame_sink_factory,
                            rt_for_poll,
                            shutdown_tx_for_poll,
                            player_state,
                        )
                        .await;
                    }
                    CommandReply {
                        ok: true,
                        error: None,
                    }
                }
                Ok(Err(msg)) => CommandReply {
                    ok: false,
                    error: Some(msg),
                },
                Err(join) => CommandReply {
                    ok: false,
                    error: Some(format!("join: {join}")),
                },
            }
        }
        Command::OpenProject { path } => {
            let folder = normalize_project_folder(&path);
            // Same canonicalize as NewProject — see comment there.
            let folder = folder.canonicalize().unwrap_or(folder);
            let folder_for_blocking = folder.clone();
            // ProjectStore::read does sync file IO + serde_json::from_slice
            // on potentially megabytes of stroke data. Same pattern as
            // StopRecording: spawn_blocking so the bus task isn't held
            // while disk reads complete.
            let result = tokio::task::spawn_blocking(move || {
                video_coach_core::project_store::read(&folder_for_blocking)
            })
            .await;
            match result {
                Ok(Ok(project)) => {
                    tracing::info!(
                        target: "project.lifecycle",
                        event = "project.opened",
                        path = %path,
                        name = %project.name,
                    );
                    *current = Some((project, folder));
                    #[cfg(feature = "media")]
                    {
                        try_spawn_current_player(
                            current,
                            current_player,
                            frame_sink_factory,
                            rt_for_poll,
                            shutdown_tx_for_poll,
                            player_state,
                        )
                        .await;
                    }
                    CommandReply {
                        ok: true,
                        error: None,
                    }
                }
                Ok(Err(e)) => CommandReply {
                    ok: false,
                    error: Some(e.to_string()),
                },
                Err(join) => CommandReply {
                    ok: false,
                    error: Some(format!("join: {join}")),
                },
            }
        }
        Command::AddSourceVideo { absolute_path } => {
            #[cfg(not(feature = "media"))]
            {
                let _ = absolute_path;
                CommandReply {
                    ok: false,
                    error: Some("media feature disabled in this build".into()),
                }
            }
            #[cfg(feature = "media")]
            {
                let Some((project, project_folder)) = current.as_mut() else {
                    return CommandReply {
                        ok: false,
                        error: Some("no project open".into()),
                    };
                };
                let abs = std::path::PathBuf::from(&absolute_path);
                if !abs.is_file() {
                    return CommandReply {
                        ok: false,
                        error: Some(format!("{} is not a regular file", abs.display())),
                    };
                }
                let folder_for_blocking = project_folder.clone();
                let abs_for_blocking = abs.clone();
                // Discoverer + relative-path math both want to run off
                // the bus task — Discoverer is a brief but blocking
                // GStreamer call.
                let result = tokio::task::spawn_blocking(
                    move || -> Result<(String, String, f64), String> {
                        let duration =
                            video_coach_media::source_player::probe_duration(&abs_for_blocking)
                                .map_err(|e| e.to_string())?;
                        let rel = pathdiff::diff_paths(&abs_for_blocking, &folder_for_blocking)
                            .ok_or_else(|| {
                                "could not compute relative path (different drives?)".to_string()
                            })?;
                        let display_name = abs_for_blocking
                            .file_name()
                            .and_then(|s| s.to_str())
                            .unwrap_or("source")
                            .to_string();
                        Ok((rel.to_string_lossy().into_owned(), display_name, duration))
                    },
                )
                .await;
                let (relative_path, display_name, duration_seconds) = match result {
                    Ok(Ok(t)) => t,
                    Ok(Err(msg)) => {
                        return CommandReply {
                            ok: false,
                            error: Some(msg),
                        }
                    }
                    Err(join) => {
                        return CommandReply {
                            ok: false,
                            error: Some(format!("join: {join}")),
                        }
                    }
                };
                project
                    .source_videos
                    .push(video_coach_core::project::SourceRef {
                        relative_path: relative_path.clone(),
                        display_name: display_name.clone(),
                        duration_seconds,
                    });
                // Persist. Failure here leaves the in-memory project
                // ahead of disk — surface as an error and roll back the
                // push so the user sees a consistent state.
                let project_clone = project.clone();
                let folder_for_write = project_folder.clone();
                let write_result = tokio::task::spawn_blocking(move || {
                    video_coach_core::project_store::write(&project_clone, &folder_for_write)
                })
                .await;
                match write_result {
                    Ok(Ok(())) => {
                        tracing::info!(
                            target: "project.lifecycle",
                            event = "source.added",
                            relative_path = %relative_path,
                            display_name = %display_name,
                            duration_seconds,
                            count = project.source_videos.len(),
                        );
                        // If this was the first source ever added to this
                        // project AND no player is loaded yet, spin one
                        // up so subsequent Play/Pause/Seek commands have
                        // somewhere to land. (Adversarial fix #3.)
                        try_spawn_current_player(
                            current,
                            current_player,
                            frame_sink_factory,
                            rt_for_poll,
                            shutdown_tx_for_poll,
                            player_state,
                        )
                        .await;
                        CommandReply {
                            ok: true,
                            error: None,
                        }
                    }
                    Ok(Err(e)) => {
                        project.source_videos.pop();
                        CommandReply {
                            ok: false,
                            error: Some(format!("write project.json: {e}")),
                        }
                    }
                    Err(join) => {
                        project.source_videos.pop();
                        CommandReply {
                            ok: false,
                            error: Some(format!("join: {join}")),
                        }
                    }
                }
            }
        }
        Command::Play => {
            #[cfg(not(feature = "media"))]
            {
                CommandReply {
                    ok: false,
                    error: Some("media feature disabled in this build".into()),
                }
            }
            #[cfg(feature = "media")]
            {
                let Some(player) = current_player.as_ref() else {
                    return CommandReply {
                        ok: false,
                        error: Some("no source loaded".into()),
                    };
                };
                let player = player.clone();
                let result = tokio::task::spawn_blocking(move || player.play()).await;
                match result {
                    Ok(Ok(())) => CommandReply {
                        ok: true,
                        error: None,
                    },
                    Ok(Err(e)) => CommandReply {
                        ok: false,
                        error: Some(e.to_string()),
                    },
                    Err(join) => CommandReply {
                        ok: false,
                        error: Some(format!("join: {join}")),
                    },
                }
            }
        }
        Command::Pause => {
            #[cfg(not(feature = "media"))]
            {
                CommandReply {
                    ok: false,
                    error: Some("media feature disabled in this build".into()),
                }
            }
            #[cfg(feature = "media")]
            {
                let Some(player) = current_player.as_ref() else {
                    return CommandReply {
                        ok: false,
                        error: Some("no source loaded".into()),
                    };
                };
                let player = player.clone();
                let result = tokio::task::spawn_blocking(move || player.pause()).await;
                match result {
                    Ok(Ok(())) => CommandReply {
                        ok: true,
                        error: None,
                    },
                    Ok(Err(e)) => CommandReply {
                        ok: false,
                        error: Some(e.to_string()),
                    },
                    Err(join) => CommandReply {
                        ok: false,
                        error: Some(format!("join: {join}")),
                    },
                }
            }
        }
        Command::Seek { seconds, accurate } => {
            #[cfg(not(feature = "media"))]
            {
                let _ = (seconds, accurate);
                CommandReply {
                    ok: false,
                    error: Some("media feature disabled in this build".into()),
                }
            }
            #[cfg(feature = "media")]
            {
                let Some(player) = current_player.as_ref() else {
                    return CommandReply {
                        ok: false,
                        error: Some("no source loaded".into()),
                    };
                };
                let player = player.clone();
                let result =
                    tokio::task::spawn_blocking(move || player.seek(seconds, accurate)).await;
                // Record the seek so the position-poll task suppresses
                // its next update — otherwise the bar briefly snaps
                // back to the pre-seek position while the decoder
                // flushes. (Adversarial-review fix #8.)
                if matches!(result, Ok(Ok(()))) {
                    let mut g = player_state.lock().expect("player_state poisoned");
                    g.last_seek_at = Some(std::time::Instant::now());
                    g.position_seconds = seconds.max(0.0);
                }
                match result {
                    Ok(Ok(())) => CommandReply {
                        ok: true,
                        error: None,
                    },
                    Ok(Err(e)) => CommandReply {
                        ok: false,
                        error: Some(e.to_string()),
                    },
                    Err(join) => CommandReply {
                        ok: false,
                        error: Some(format!("join: {join}")),
                    },
                }
            }
        }
        Command::SetScanVolume { value } => {
            #[cfg(not(feature = "media"))]
            {
                let _ = value;
                CommandReply {
                    ok: false,
                    error: Some("media feature disabled in this build".into()),
                }
            }
            #[cfg(feature = "media")]
            {
                let Some(player) = current_player.as_ref() else {
                    return CommandReply {
                        ok: false,
                        error: Some("no source loaded".into()),
                    };
                };
                // set_volume is a cheap GObject property write; no need
                // to spawn_blocking. The volume name lookup is mutex'd
                // inside GStreamer.
                player.set_volume(value);
                // Persist to project.preferences.scan_volume so the
                // setting survives across sessions. Phase 7 MVP writes
                // on every change — project.json is small and atomic
                // rename is cheap. Future patch can debounce.
                if let Some((project, folder)) = current.as_mut() {
                    project.preferences.scan_volume = value;
                    let project_clone = project.clone();
                    let folder_clone = folder.clone();
                    let _ = tokio::task::spawn_blocking(move || {
                        let _ =
                            video_coach_core::project_store::write(&project_clone, &folder_clone);
                    })
                    .await;
                }
                CommandReply {
                    ok: true,
                    error: None,
                }
            }
        }
        Command::StartClipRecording {
            playhead_snapshot_seconds,
        } => {
            // Task 0 stub: serde shape only. Real handler lands in Task 1.
            let _ = playhead_snapshot_seconds;
            CommandReply {
                ok: false,
                error: Some("start_clip_recording: not yet implemented".into()),
            }
        }
        Command::StopClipRecording => {
            // Task 0 stub: serde shape only. Real handler lands in Task 1.
            CommandReply {
                ok: false,
                error: Some("stop_clip_recording: not yet implemented".into()),
            }
        }
        Command::AppendStroke { points_json } => {
            // Task 0 stub: serde shape only. Real handler lands in Task 4.
            let _ = points_json;
            CommandReply {
                ok: false,
                error: Some("append_stroke: not yet implemented".into()),
            }
        }
    }
}

/// If `current` has a project with `sourceVideos[0]` and no player is
/// already attached, open a `SourcePlayer` for that source. The disk
/// path is resolved by joining `relative_path` against the project
/// folder, so cross-platform `..` traversal lands at the original file.
///
/// Spawning blocks on GStreamer preroll (~tens of milliseconds for an
/// already-decoded mp4, longer for first-time hardware-decoder cold
/// starts), so this runs inside `spawn_blocking` and does not stall the
/// bus's mpsc loop. Failure to open does not unwind the project — we
/// log the error and leave `current_player` empty so subsequent
/// transport commands return "no source loaded" cleanly.
#[cfg(feature = "media")]
#[allow(clippy::too_many_arguments)]
async fn try_spawn_current_player(
    current: &Option<(video_coach_core::project::Project, std::path::PathBuf)>,
    current_player: &mut Option<std::sync::Arc<video_coach_media::source_player::SourcePlayer>>,
    frame_sink_factory: &FrameSinkFactory,
    rt_for_poll: &tokio::runtime::Handle,
    shutdown_tx_for_poll: &tokio::sync::watch::Sender<bool>,
    player_state: &crate::frame_sink::PlayerStateSlot,
) {
    if current_player.is_some() {
        return;
    }
    let Some((project, folder)) = current.as_ref() else {
        return;
    };
    let Some(first) = project.source_videos.first() else {
        return;
    };
    // Resolve to a clean absolute path. PathBuf::join keeps `..`
    // components literal (e.g. `/tmp/proj/../../Users/...`); GStreamer's
    // filesrc on macOS can't open such paths cleanly. Canonicalize
    // collapses them. Fall back to the joined path if canonicalize
    // fails (e.g. file moved) so the error message stays informative.
    let joined = folder.join(&first.relative_path);
    let abs = joined.canonicalize().unwrap_or(joined);
    let duration = first.duration_seconds;
    let display_name = first.display_name.clone();
    let frame_sink = frame_sink_factory();
    let abs_for_blocking = abs.clone();
    let result = tokio::task::spawn_blocking(move || {
        video_coach_media::source_player::SourcePlayer::open(
            &abs_for_blocking,
            frame_sink,
            duration,
        )
    })
    .await;
    match result {
        Ok(Ok(player)) => {
            tracing::info!(
                target: "player.lifecycle",
                event = "player.opened",
                path = %abs.display(),
                display_name = %display_name,
                duration_seconds = duration,
            );
            let player = std::sync::Arc::new(player);
            // Seed the state slot with the known duration so the UI's
            // first paint shows a non-zero scrub track.
            {
                let mut g = player_state.lock().expect("player_state poisoned");
                g.duration_seconds = duration;
                g.position_seconds = 0.0;
                g.is_playing = false;
                g.last_seek_at = None;
            }
            spawn_position_poll(
                rt_for_poll,
                player.clone(),
                player_state.clone(),
                shutdown_tx_for_poll.subscribe(),
            );
            *current_player = Some(player);
        }
        Ok(Err(e)) => {
            tracing::warn!(
                target: "player.lifecycle",
                error = %e,
                path = %abs.display(),
                "failed to open source player",
            );
        }
        Err(join) => {
            tracing::warn!(
                target: "player.lifecycle",
                error = %join,
                "join error opening source player",
            );
        }
    }
}

/// Resolve a user-supplied "project folder" path. If the user (or a
/// frontend dialog) hands us a path that ends in `project.json` we want
/// the directory containing it, not the file itself. This keeps later
/// relative-path math (Phase 7 AddSourceVideo) from sprouting a stray
/// `..` component.
fn normalize_project_folder(path: &str) -> std::path::PathBuf {
    let p = std::path::PathBuf::from(path);
    if p.is_file() && p.file_name().and_then(|n| n.to_str()) == Some("project.json") {
        if let Some(parent) = p.parent() {
            return parent.to_path_buf();
        }
    }
    p
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quit_command_serializes_with_snake_case_tag() {
        let json = serde_json::to_value(&Command::Quit).unwrap();
        assert_eq!(json, serde_json::json!({"cmd": "quit"}));
    }

    #[test]
    fn ping_command_serializes_with_snake_case_tag() {
        let json = serde_json::to_value(&Command::Ping).unwrap();
        assert_eq!(json, serde_json::json!({"cmd": "ping"}));
    }

    #[test]
    fn command_deserializes_from_tagged_json() {
        let cmd: Command = serde_json::from_value(serde_json::json!({"cmd": "quit"})).unwrap();
        assert!(matches!(cmd, Command::Quit));
    }

    #[test]
    fn start_recording_serializes_with_fixture_source() {
        let cmd = Command::StartRecording {
            source: SourceConfig::Fixture {
                path: "fixtures/webcam.mov".into(),
            },
            output: "/tmp/x.mov".into(),
        };
        let v = serde_json::to_value(&cmd).unwrap();
        assert_eq!(v["cmd"], "start_recording");
        assert_eq!(v["source"]["kind"], "fixture");
        assert_eq!(v["source"]["path"], "fixtures/webcam.mov");
        assert_eq!(v["output"], "/tmp/x.mov");
    }

    #[test]
    fn stop_recording_serializes_to_bare_tag() {
        let cmd = Command::StopRecording;
        let v = serde_json::to_value(&cmd).unwrap();
        assert_eq!(v, serde_json::json!({"cmd": "stop_recording"}));
    }

    #[test]
    fn new_project_serializes_with_path() {
        let cmd = Command::NewProject {
            path: "/tmp/freshproj".into(),
        };
        let v = serde_json::to_value(&cmd).unwrap();
        assert_eq!(v["cmd"], "new_project");
        assert_eq!(v["path"], "/tmp/freshproj");
    }

    #[test]
    fn new_project_deserializes_with_path() {
        let v = serde_json::json!({"cmd": "new_project", "path": "/tmp/freshproj"});
        let cmd: Command = serde_json::from_value(v).unwrap();
        match cmd {
            Command::NewProject { path } => assert_eq!(path, "/tmp/freshproj"),
            _ => panic!("expected NewProject"),
        }
    }

    #[test]
    fn add_source_video_serde_roundtrips() {
        let cmd = Command::AddSourceVideo {
            absolute_path: "/Users/x/clip.mp4".into(),
        };
        let v = serde_json::to_value(&cmd).unwrap();
        assert_eq!(v["cmd"], "add_source_video");
        assert_eq!(v["absolute_path"], "/Users/x/clip.mp4");

        let cmd: Command = serde_json::from_value(v).unwrap();
        match cmd {
            Command::AddSourceVideo { absolute_path } => {
                assert_eq!(absolute_path, "/Users/x/clip.mp4")
            }
            _ => panic!("expected AddSourceVideo"),
        }
    }

    #[test]
    fn play_pause_serialize_to_bare_tags() {
        assert_eq!(
            serde_json::to_value(&Command::Play).unwrap(),
            serde_json::json!({"cmd": "play"})
        );
        assert_eq!(
            serde_json::to_value(&Command::Pause).unwrap(),
            serde_json::json!({"cmd": "pause"})
        );
    }

    #[test]
    fn seek_serde_roundtrips() {
        let cmd = Command::Seek {
            seconds: 12.5,
            accurate: true,
        };
        let v = serde_json::to_value(&cmd).unwrap();
        assert_eq!(v["cmd"], "seek");
        assert_eq!(v["seconds"], 12.5);
        assert_eq!(v["accurate"], true);

        let cmd: Command = serde_json::from_value(v).unwrap();
        match cmd {
            Command::Seek { seconds, accurate } => {
                assert!((seconds - 12.5).abs() < f64::EPSILON);
                assert!(accurate);
            }
            _ => panic!("expected Seek"),
        }
    }

    #[test]
    fn set_scan_volume_serde_roundtrips() {
        let cmd = Command::SetScanVolume { value: 0.75 };
        let v = serde_json::to_value(&cmd).unwrap();
        assert_eq!(v["cmd"], "set_scan_volume");
        assert_eq!(v["value"], 0.75);

        let cmd: Command = serde_json::from_value(v).unwrap();
        match cmd {
            Command::SetScanVolume { value } => assert!((value - 0.75).abs() < f64::EPSILON),
            _ => panic!("expected SetScanVolume"),
        }
    }

    #[test]
    fn normalize_project_folder_passes_through_directory() {
        // A directory path resolves to itself (whether it exists or not is
        // irrelevant here — is_file() returns false for non-existent paths,
        // so the `else` branch returns the original).
        let p = std::path::PathBuf::from("/some/dir/that/does/not/exist");
        assert_eq!(normalize_project_folder("/some/dir/that/does/not/exist"), p);
    }

    #[test]
    fn normalize_project_folder_strips_project_json() {
        // Build a real temp directory + project.json so is_file() returns
        // true. Otherwise the function can't distinguish a hypothetical
        // file path from a directory path.
        let dir = tempfile::TempDir::new().unwrap();
        let json = dir.path().join("project.json");
        std::fs::write(&json, "{}").unwrap();
        assert_eq!(normalize_project_folder(json.to_str().unwrap()), dir.path());
    }

    #[test]
    fn open_project_serializes_with_path() {
        let cmd = Command::OpenProject {
            path: "/tmp/proj".into(),
        };
        let v = serde_json::to_value(&cmd).unwrap();
        assert_eq!(v["cmd"], "open_project");
        assert_eq!(v["path"], "/tmp/proj");
    }

    #[test]
    fn open_project_deserializes_with_path() {
        let v = serde_json::json!({
            "cmd": "open_project",
            "path": "/tmp/proj"
        });
        let cmd: Command = serde_json::from_value(v).unwrap();
        match cmd {
            Command::OpenProject { path } => assert_eq!(path, "/tmp/proj"),
            _ => panic!("expected OpenProject"),
        }
    }

    #[test]
    fn start_clip_recording_serde_roundtrips() {
        let cmd = Command::StartClipRecording {
            playhead_snapshot_seconds: 12.5,
        };
        let v = serde_json::to_value(&cmd).unwrap();
        assert_eq!(v["cmd"], "start_clip_recording");
        assert_eq!(v["playhead_snapshot_seconds"], 12.5);

        let cmd: Command = serde_json::from_value(v).unwrap();
        match cmd {
            Command::StartClipRecording {
                playhead_snapshot_seconds,
            } => {
                assert!((playhead_snapshot_seconds - 12.5).abs() < f64::EPSILON);
            }
            _ => panic!("expected StartClipRecording"),
        }
    }

    #[test]
    fn stop_clip_recording_serializes_to_bare_tag() {
        let cmd = Command::StopClipRecording;
        let v = serde_json::to_value(&cmd).unwrap();
        assert_eq!(v, serde_json::json!({"cmd": "stop_clip_recording"}));

        let cmd: Command =
            serde_json::from_value(serde_json::json!({"cmd": "stop_clip_recording"})).unwrap();
        assert!(matches!(cmd, Command::StopClipRecording));
    }

    #[test]
    fn append_stroke_serde_roundtrips() {
        let cmd = Command::AppendStroke {
            points_json: r#"[{"x":0.5,"y":0.5,"t":0.1}]"#.into(),
        };
        let v = serde_json::to_value(&cmd).unwrap();
        assert_eq!(v["cmd"], "append_stroke");
        assert_eq!(v["points_json"], r#"[{"x":0.5,"y":0.5,"t":0.1}]"#);

        let cmd: Command = serde_json::from_value(v).unwrap();
        match cmd {
            Command::AppendStroke { points_json } => {
                assert_eq!(points_json, r#"[{"x":0.5,"y":0.5,"t":0.1}]"#);
            }
            _ => panic!("expected AppendStroke"),
        }
    }

    #[test]
    fn app_mode_serializes_with_snake_case() {
        // AppMode is published over the bus / control socket as the
        // value of a "mode" field on mode.changed events; verify the
        // serde shape directly.
        assert_eq!(
            serde_json::to_value(AppMode::Scanning).unwrap(),
            serde_json::Value::String("scanning".into()),
        );
        assert_eq!(
            serde_json::to_value(AppMode::RecordingStarting).unwrap(),
            serde_json::Value::String("recording_starting".into()),
        );
        assert_eq!(
            serde_json::to_value(AppMode::Recording).unwrap(),
            serde_json::Value::String("recording".into()),
        );
        let m: AppMode = serde_json::from_value(serde_json::Value::String("recording".into()))
            .expect("snake_case roundtrip");
        assert_eq!(m, AppMode::Recording);
    }

    #[test]
    fn start_recording_deserializes_with_fixture_source() {
        let v = serde_json::json!({
            "cmd": "start_recording",
            "source": { "kind": "fixture", "path": "fixtures/webcam.mov" },
            "output": "/tmp/x.mov"
        });
        let cmd: Command = serde_json::from_value(v).unwrap();
        match cmd {
            Command::StartRecording {
                source: SourceConfig::Fixture { path },
                output,
            } => {
                assert_eq!(path, "fixtures/webcam.mov");
                assert_eq!(output, "/tmp/x.mov");
            }
            _ => panic!("expected StartRecording with Fixture source"),
        }
    }
}
