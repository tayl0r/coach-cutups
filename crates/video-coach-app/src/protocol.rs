// Used by control_socket adapter (Task 5); only tests consume these for now.
#![allow(dead_code)]

use crate::bus::Command;
use serde::{de, Deserialize, Deserializer, Serialize};

/// One JSON line received on the control socket.
/// Wraps a Command with a correlation id.
///
/// We hand-roll Deserialize because `#[serde(flatten)]` does not work over
/// internally-tagged enums (serde-rs/serde#1189). The wire shape stays flat:
/// `{"id": "1", "cmd": "quit"}` — `id` is split off, the rest deserializes
/// as a Command via `serde_json::from_value`.
#[derive(Debug)]
pub struct IncomingFrame {
    pub id: String,
    pub command: Command,
}

impl<'de> Deserialize<'de> for IncomingFrame {
    fn deserialize<D: Deserializer<'de>>(de: D) -> Result<Self, D::Error> {
        let mut map = serde_json::Map::<String, serde_json::Value>::deserialize(de)?;
        let id = map
            .remove("id")
            .and_then(|v| v.as_str().map(String::from))
            .ok_or_else(|| de::Error::missing_field("id"))?;
        let command = serde_json::from_value::<Command>(serde_json::Value::Object(map))
            .map_err(de::Error::custom)?;
        Ok(IncomingFrame { id, command })
    }
}

/// One JSON line sent on the control socket. Either a reply to a command
/// (correlated by id) or a lifecycle/state event.
#[derive(Debug, Clone, Serialize)]
#[serde(untagged)]
pub enum OutgoingFrame {
    Reply {
        reply_to: String,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    Event {
        event: String,
        ts: u128,
        #[serde(flatten)]
        fields: serde_json::Value,
    },
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bus::Command;

    #[test]
    fn incoming_frame_parses_quit_with_id() {
        let frame: IncomingFrame = serde_json::from_str(r#"{"id":"abc","cmd":"quit"}"#).unwrap();
        assert_eq!(frame.id, "abc");
        assert!(matches!(frame.command, Command::Quit));
    }

    #[test]
    fn incoming_frame_parses_ping_with_id() {
        let frame: IncomingFrame = serde_json::from_str(r#"{"id":"42","cmd":"ping"}"#).unwrap();
        assert_eq!(frame.id, "42");
        assert!(matches!(frame.command, Command::Ping));
    }

    #[test]
    fn incoming_frame_missing_id_errors() {
        let res: Result<IncomingFrame, _> = serde_json::from_str(r#"{"cmd":"quit"}"#);
        assert!(res.is_err());
    }

    #[test]
    fn outgoing_reply_serializes_correctly() {
        let f = OutgoingFrame::Reply {
            reply_to: "abc".into(),
            ok: true,
            error: None,
        };
        assert_eq!(
            serde_json::to_value(&f).unwrap(),
            serde_json::json!({ "reply_to": "abc", "ok": true })
        );
    }

    #[test]
    fn outgoing_event_serializes_with_event_and_ts() {
        let f = OutgoingFrame::Event {
            event: "app.launched".into(),
            ts: 1_000,
            fields: serde_json::json!({ "version": "0.1.0" }),
        };
        let v = serde_json::to_value(&f).unwrap();
        assert_eq!(v["event"], "app.launched");
        assert_eq!(v["ts"], 1_000);
        assert_eq!(v["version"], "0.1.0");
    }
}
