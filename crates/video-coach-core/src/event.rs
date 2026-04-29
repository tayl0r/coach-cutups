use crate::stroke::Stroke;
use serde::de::{self, Deserializer, MapAccess, Visitor};
use serde::ser::{SerializeMap, Serializer};
use serde::{Deserialize, Serialize};
use std::fmt;

// The custom Serialize/Deserialize uses `serde_json::Value` for lenient
// unit-variant payload consumption. That makes the impl serde_json-only;
// non-self-describing formats (bincode etc.) won't roundtrip correctly.
#[derive(Debug, Clone, PartialEq)]
pub enum EventKind {
    Play,
    Pause,
    Skip { delta: f64 },
    Stroke(Stroke),
    ClearAll,
}

impl Serialize for EventKind {
    fn serialize<S: Serializer>(&self, ser: S) -> Result<S::Ok, S::Error> {
        let mut m = ser.serialize_map(Some(1))?;
        match self {
            EventKind::Play => m.serialize_entry("play", &serde_json::json!({}))?,
            EventKind::Pause => m.serialize_entry("pause", &serde_json::json!({}))?,
            EventKind::Skip { delta } => {
                m.serialize_entry("skip", &serde_json::json!({ "delta": delta }))?
            }
            EventKind::Stroke(s) => m.serialize_entry("stroke", s)?,
            EventKind::ClearAll => m.serialize_entry("clearAll", &serde_json::json!({}))?,
        }
        m.end()
    }
}

impl<'de> Deserialize<'de> for EventKind {
    fn deserialize<D: Deserializer<'de>>(de: D) -> Result<Self, D::Error> {
        struct V;
        impl<'de> Visitor<'de> for V {
            type Value = EventKind;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("a single-key map describing an event kind")
            }
            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<EventKind, A::Error> {
                let key: String = map.next_key()?.ok_or_else(|| {
                    de::Error::custom("expected a single-key map for EventKind, got empty map")
                })?;
                match key.as_str() {
                    "play" => {
                        let _: serde_json::Value = map.next_value()?;
                        Ok(EventKind::Play)
                    }
                    "pause" => {
                        let _: serde_json::Value = map.next_value()?;
                        Ok(EventKind::Pause)
                    }
                    "clearAll" => {
                        let _: serde_json::Value = map.next_value()?;
                        Ok(EventKind::ClearAll)
                    }
                    "skip" => {
                        #[derive(Deserialize)]
                        struct P {
                            delta: f64,
                        }
                        let p: P = map.next_value()?;
                        Ok(EventKind::Skip { delta: p.delta })
                    }
                    "stroke" => {
                        let s: crate::stroke::Stroke = map.next_value()?;
                        Ok(EventKind::Stroke(s))
                    }
                    other => Err(de::Error::unknown_variant(
                        other,
                        &["play", "pause", "skip", "stroke", "clearAll"],
                    )),
                }
            }
        }
        de.deserialize_map(V)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommentaryEvent {
    pub record_time: f64,
    pub kind: EventKind,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn play_event_encodes_as_swift_dictionary_form() {
        let ev = CommentaryEvent {
            record_time: 0.0,
            kind: EventKind::Play,
        };
        let json: serde_json::Value = serde_json::to_value(&ev).unwrap();
        // Expected: {"recordTime": 0.0, "kind": {"play": {}}}
        assert_eq!(
            json,
            serde_json::json!({ "recordTime": 0.0, "kind": { "play": {} } })
        );
    }

    #[test]
    fn skip_event_encodes_with_delta_payload() {
        let ev = CommentaryEvent {
            record_time: 1.5,
            kind: EventKind::Skip { delta: 3.0 },
        };
        let json: serde_json::Value = serde_json::to_value(&ev).unwrap();
        assert_eq!(
            json,
            serde_json::json!({ "recordTime": 1.5, "kind": { "skip": { "delta": 3.0 } } })
        );
    }

    #[test]
    fn every_variant_roundtrips() {
        use crate::stroke::{Rgba, StrokePoint};
        use uuid::Uuid;
        let cases = vec![
            EventKind::Play,
            EventKind::Pause,
            EventKind::Skip { delta: -3.0 },
            EventKind::ClearAll,
            EventKind::Stroke(crate::stroke::Stroke {
                id: Uuid::nil(),
                color: Rgba::RED,
                line_width: 0.01,
                points: vec![StrokePoint {
                    x: 0.0,
                    y: 0.0,
                    t: 0.0,
                }],
                auto_clear_after_seconds: None,
            }),
        ];
        for k in cases {
            let s = serde_json::to_string(&k).unwrap();
            let back: EventKind = serde_json::from_str(&s).unwrap();
            assert_eq!(k, back, "variant did not roundtrip via {}", s);
        }
    }
}
