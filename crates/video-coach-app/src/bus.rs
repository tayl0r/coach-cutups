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

/// Spawn the bus task on the given tokio runtime handle. Phase 6 dropped
/// `#[tokio::main]` so the bus runs on the same multi-threaded runtime
/// that drives the control socket and any UI-dispatched async work.
pub fn spawn_on(
    rt: &tokio::runtime::Handle,
    shutdown_tx: tokio::sync::watch::Sender<bool>,
) -> BusHandle {
    let (tx, mut rx) = mpsc::channel::<Envelope>(64);
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

        while let Some(env) = rx.recv().await {
            let reply = handle(
                env.command,
                &shutdown_tx,
                #[cfg(feature = "media")]
                &mut recording,
                &mut current,
            )
            .await;
            let _ = env.reply.send(reply);
        }
    });
    BusHandle { tx }
}

async fn handle(
    cmd: Command,
    shutdown_tx: &tokio::sync::watch::Sender<bool>,
    #[cfg(feature = "media")] recording: &mut Option<video_coach_media::recording::Recording>,
    current: &mut Option<(video_coach_core::project::Project, std::path::PathBuf)>,
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
                return CommandReply {
                    ok: false,
                    error: Some("media feature disabled in this build".into()),
                };
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
        Command::Play => CommandReply {
            ok: false,
            error: Some("play not yet implemented (Phase 7 Task 3)".into()),
        },
        Command::Pause => CommandReply {
            ok: false,
            error: Some("pause not yet implemented (Phase 7 Task 3)".into()),
        },
        Command::Seek {
            seconds: _,
            accurate: _,
        } => CommandReply {
            ok: false,
            error: Some("seek not yet implemented (Phase 7 Task 3)".into()),
        },
        Command::SetScanVolume { value: _ } => CommandReply {
            ok: false,
            error: Some("set_scan_volume not yet implemented (Phase 7 Task 7)".into()),
        },
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
