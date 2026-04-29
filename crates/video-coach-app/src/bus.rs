// `BusHandle::send`, `Envelope::id`, and `BusHandle::tx` are unused until Task 5
// wires the control socket; suppress dead_code so clippy stays clean.
#![allow(dead_code)]

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
}

/// A command paired with a reply channel.
pub struct Envelope {
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
        while let Some(env) = rx.recv().await {
            let reply = handle(env.command, &shutdown_tx).await;
            let _ = env.reply.send(reply);
        }
    });
    BusHandle { tx }
}

async fn handle(cmd: Command, shutdown_tx: &tokio::sync::watch::Sender<bool>) -> CommandReply {
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
}
