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

pub fn spawn(shutdown_tx: tokio::sync::watch::Sender<bool>) -> BusHandle {
    let (tx, mut rx) = mpsc::channel::<Envelope>(64);
    tokio::spawn(async move {
        // Per-task recording state. `None` until StartRecording succeeds;
        // taken by StopRecording. Held across loop iterations because start
        // and stop are necessarily separate commands.
        #[cfg(feature = "media")]
        let mut recording: Option<video_coach_media::recording::Recording> = None;

        while let Some(env) = rx.recv().await {
            let reply = handle(
                env.command,
                &shutdown_tx,
                #[cfg(feature = "media")]
                &mut recording,
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
) -> CommandReply {
    match cmd {
        Command::Quit => {
            tracing::info!(target: "app.lifecycle", event = "app.shutdown_requested");
            let _ = shutdown_tx.send(true);
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
    }
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
