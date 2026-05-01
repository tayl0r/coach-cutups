#[cfg(feature = "control-socket")]
use std::collections::HashMap;
#[cfg(feature = "control-socket")]
use tokio::sync::broadcast;
use tracing::{Event, Subscriber};
use tracing_subscriber::{layer::Context, registry::LookupSpan, Layer};

#[cfg(feature = "control-socket")]
use crate::protocol::OutgoingFrame;

/// Event targets forwarded to the control socket. Anything outside this
/// list stays in the regular log stream and is not pushed to subscribers.
#[cfg(feature = "control-socket")]
const FORWARDED_TARGETS: &[&str] = &[
    "app.lifecycle",
    "project",
    "project.lifecycle",
    "recording",
    "preview",
    "export",
    "control_socket",
    // Phase 7 — source-video transport. `player.lifecycle` covers
    // open/close, `player.state` covers play/pause/seeked/position.
    "player.lifecycle",
    "player.state",
    // Phase 8 — clip-recording mode transitions (mode.changed,
    // recording.started, recording.stopped, recording.failed). Distinct
    // from the lower-level "recording" target which carries the
    // capture-pipeline lifecycle events (recording.encoder_picked etc).
    "recording.lifecycle",
    // Phase 9 — clip preview lifecycle (clip_preview.opened,
    // clip_preview.closed, clip_preview.failed, clip_preview.completed).
    // Per adversarial-review fix #1, every Phase 9 event names under
    // `clip_preview.*` so the harness's wait_for_event (which matches by
    // event name only, not target) can't collide with `recording.*` or
    // `clip_recording.*`.
    "clip_preview.lifecycle",
];

#[cfg(feature = "control-socket")]
pub struct ForwardLayer {
    pub events: broadcast::Sender<OutgoingFrame>,
}

#[cfg(feature = "control-socket")]
impl<S> Layer<S> for ForwardLayer
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        let target = event.metadata().target();
        if !FORWARDED_TARGETS.contains(&target) {
            return;
        }

        let mut visitor = JsonVisitor::default();
        event.record(&mut visitor);
        let event_name = visitor
            .fields
            .remove("event")
            .and_then(|v| v.as_str().map(String::from))
            .unwrap_or_else(|| target.to_string());
        let ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let frame = OutgoingFrame::Event {
            event: event_name,
            ts,
            fields: serde_json::Value::Object(visitor.fields.into_iter().collect()),
        };
        let _ = self.events.send(frame);
    }
}

/// Uninhabited stub: `logging::init` keeps a uniform signature regardless of
/// the `control-socket` feature, but the no-feature build can never construct
/// or invoke this layer.
#[cfg(not(feature = "control-socket"))]
pub enum ForwardLayer {}

#[cfg(not(feature = "control-socket"))]
impl<S> Layer<S> for ForwardLayer
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    fn on_event(&self, _event: &Event<'_>, _ctx: Context<'_, S>) {
        match *self {}
    }
}

#[cfg(feature = "control-socket")]
#[derive(Default)]
struct JsonVisitor {
    fields: HashMap<String, serde_json::Value>,
}

#[cfg(feature = "control-socket")]
impl tracing::field::Visit for JsonVisitor {
    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        self.fields.insert(
            field.name().to_string(),
            serde_json::Value::String(format!("{value:?}")),
        );
    }
    fn record_str(&mut self, field: &tracing::field::Field, value: &str) {
        self.fields.insert(
            field.name().to_string(),
            serde_json::Value::String(value.to_string()),
        );
    }
    fn record_i64(&mut self, field: &tracing::field::Field, value: i64) {
        self.fields.insert(
            field.name().to_string(),
            serde_json::Value::Number(value.into()),
        );
    }
    fn record_u64(&mut self, field: &tracing::field::Field, value: u64) {
        self.fields.insert(
            field.name().to_string(),
            serde_json::Value::Number(value.into()),
        );
    }
    fn record_bool(&mut self, field: &tracing::field::Field, value: bool) {
        self.fields
            .insert(field.name().to_string(), serde_json::Value::Bool(value));
    }
    fn record_f64(&mut self, field: &tracing::field::Field, value: f64) {
        // serde_json::Number::from_f64 returns None for NaN / Inf — fall
        // back to a string in those cases so the field still shows up.
        let v = serde_json::Number::from_f64(value)
            .map(serde_json::Value::Number)
            .unwrap_or_else(|| serde_json::Value::String(format!("{value}")));
        self.fields.insert(field.name().to_string(), v);
    }
}

#[cfg(all(test, feature = "control-socket"))]
mod tests {
    use super::FORWARDED_TARGETS;

    #[test]
    fn forwarded_targets_include_recording() {
        assert!(
            FORWARDED_TARGETS.contains(&"recording"),
            "recording.* events must reach the control socket",
        );
    }
}
