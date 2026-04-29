# Phase 2: Testability Foundation — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Land the cross-cutting plumbing — `tracing` instrumentation, in-process command bus, control socket adapter, harness crate, Git LFS, fixture manifest — that every subsequent phase will build against. End state: an empty app shell can be launched by a harness, driven through a JSON-line control socket, and verified via a `tracing`-event stream. No real UI, no real capture, no real export — just the rails.

**Architecture:** A new `video-coach-app` binary crate with an async `tokio` runtime. UI events, external commands, and lifecycle actions all flow through one typed `Command` channel. A `cfg(feature = "control-socket")` adapter exposes the channel over TCP loopback as JSON-lines. `tracing` provides structured telemetry; the adapter forwards a curated subset of events to socket subscribers. Release builds compile the adapter out (`--no-default-features`).

**Tech Stack:** `tokio` (async runtime), `tracing` + `tracing-subscriber` (telemetry), `serde` + `serde_json` (wire types — already in workspace), `clap` (CLI parsing), `anyhow` (top-level error handling). Harness crate adds `assert_cmd` (subprocess control) and `tokio` for async IO.

**Reference for transport choice:** TCP loopback (`127.0.0.1:0`, OS-chosen port). The app prints `{"event":"control_socket.ready","addr":"127.0.0.1:N"}` to stdout as the first line of output; the harness reads stdout until it sees that line, then connects. This avoids the Unix-vs-Windows `UnixListener`/`NamedPipe` split entirely.

---

## Task 1: Bootstrap `video-coach-app` binary crate

**Files:**
- Create: `crates/video-coach-app/Cargo.toml`
- Create: `crates/video-coach-app/src/main.rs`
- Modify: `Cargo.toml` (workspace members)

**Step 1: Add the crate to the workspace**

In root `Cargo.toml`:

```toml
[workspace]
resolver = "2"
members = ["crates/video-coach-core", "crates/video-coach-app"]
```

**Step 2: Create the binary crate manifest**

```toml
# crates/video-coach-app/Cargo.toml
[package]
name = "video-coach-app"
version = "0.1.0"
edition.workspace = true
rust-version.workspace = true
license.workspace = true

[features]
default = ["control-socket"]
# When disabled (release packaging: --no-default-features), the control socket
# adapter is compiled out entirely. The app cannot be remote-driven.
control-socket = []

[dependencies]
video-coach-core = { path = "../video-coach-core" }
tokio = { version = "1", features = ["rt-multi-thread", "macros", "sync", "io-util", "net", "signal", "time"] }
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["json", "env-filter"] }
serde = { workspace = true }
serde_json = { workspace = true }
clap = { version = "4", features = ["derive"] }
anyhow = "1"
```

**Step 3: Create a minimal `main.rs`**

```rust
// crates/video-coach-app/src/main.rs
fn main() {
    println!("video-coach-app starting (placeholder)");
}
```

**Step 4: Verify it builds and runs**

Run: `cargo run -p video-coach-app`
Expected: prints `video-coach-app starting (placeholder)`.

**Step 5: Commit**

```bash
git add Cargo.toml crates/video-coach-app/
git commit -m "feat(app): bootstrap video-coach-app binary crate"
```

---

## Task 2: Wire `tracing` + JSON-line subscriber

**Files:**
- Modify: `crates/video-coach-app/src/main.rs`
- Create: `crates/video-coach-app/src/cli.rs`
- Create: `crates/video-coach-app/src/logging.rs`

**Step 1: Define CLI args**

```rust
// crates/video-coach-app/src/cli.rs
use clap::Parser;

#[derive(Debug, Parser)]
#[command(name = "video-coach", about = "Video tagging and export tool")]
pub struct Args {
    /// Emit logs as JSON-lines on stdout instead of human-readable on stderr.
    /// Required for the harness to parse lifecycle events.
    #[arg(long)]
    pub json_logs: bool,

    /// Bind a TCP control socket on 127.0.0.1 at the given port (0 = OS-chosen).
    /// Compiled out in release builds.
    #[cfg(feature = "control-socket")]
    #[arg(long)]
    pub control_socket: Option<u16>,
}
```

**Step 2: Wire the tracing subscriber**

```rust
// crates/video-coach-app/src/logging.rs
use tracing_subscriber::{EnvFilter, fmt, prelude::*};

pub fn init(json: bool) {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    let registry = tracing_subscriber::registry().with(filter);
    if json {
        // JSON-lines on stdout — what the harness consumes.
        registry.with(fmt::layer().json().with_writer(std::io::stdout)).init();
    } else {
        // Human-readable on stderr for dev runs.
        registry.with(fmt::layer().with_writer(std::io::stderr)).init();
    }
}
```

**Step 3: Update `main.rs` to parse args and emit a startup event**

```rust
// crates/video-coach-app/src/main.rs
mod cli;
mod logging;

use clap::Parser;
use cli::Args;

fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    logging::init(args.json_logs);
    tracing::info!(target: "app.lifecycle", event = "app.launched", version = env!("CARGO_PKG_VERSION"));
    Ok(())
}
```

**Step 4: Verify both modes**

Run: `cargo run -p video-coach-app`
Expected: human-readable line on stderr containing `app.launched`.

Run: `cargo run -p video-coach-app -- --json-logs`
Expected: a JSON-line on stdout containing `"fields":{"event":"app.launched","version":"0.1.0",...}` (exact shape varies).

**Step 5: Commit**

```bash
git add crates/video-coach-app/src/cli.rs crates/video-coach-app/src/logging.rs crates/video-coach-app/src/main.rs
git commit -m "feat(app): tracing subscriber with JSON-lines mode for harness consumption"
```

---

## Task 3: Async runtime + typed `Command` bus

**Files:**
- Create: `crates/video-coach-app/src/bus.rs`
- Modify: `crates/video-coach-app/src/main.rs`

**Step 1: Define the Command enum + bus**

```rust
// crates/video-coach-app/src/bus.rs
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
        let env = Envelope { id, command, reply: reply_tx };
        if self.tx.send(env).await.is_err() {
            return CommandReply { ok: false, error: Some("bus closed".into()) };
        }
        reply_rx.await.unwrap_or(CommandReply { ok: false, error: Some("reply dropped".into()) })
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
            CommandReply { ok: true, error: None }
        }
        Command::Ping => {
            tracing::info!(target: "app.lifecycle", event = "app.ping");
            CommandReply { ok: true, error: None }
        }
    }
}
```

**Step 2: Wire the bus into `main`**

```rust
// crates/video-coach-app/src/main.rs
mod bus;
mod cli;
mod logging;

use clap::Parser;
use cli::Args;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    logging::init(args.json_logs);
    tracing::info!(target: "app.lifecycle", event = "app.launched", version = env!("CARGO_PKG_VERSION"));

    let (shutdown_tx, mut shutdown_rx) = tokio::sync::watch::channel(false);
    let _bus = bus::spawn(shutdown_tx.clone());

    // For now: wait for shutdown signal (Ctrl-C, or future Quit command).
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {
            tracing::info!(target: "app.lifecycle", event = "app.shutdown_requested", source = "signal");
        }
        _ = shutdown_rx.changed() => {
            // shutdown_tx was triggered (Quit command).
        }
    }

    tracing::info!(target: "app.lifecycle", event = "app.shutdown");
    Ok(())
}
```

**Step 3: Add a unit test for `Command` round-trip**

```rust
// in bus.rs, append:
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
```

**Step 4: Run tests**

Run: `cargo test -p video-coach-app bus::`
Expected: 3 passed.

**Step 5: Commit**

```bash
git add crates/video-coach-app/src/bus.rs crates/video-coach-app/src/main.rs
git commit -m "feat(app): tokio runtime + typed Command bus with Quit/Ping"
```

---

## Task 4: Wire protocol types — `Reply` and `Event`

**Files:**
- Create: `crates/video-coach-app/src/protocol.rs`

**Step 1: Define the wire types**

```rust
// crates/video-coach-app/src/protocol.rs
use serde::{Deserialize, Serialize};

/// One JSON line received on the control socket.
/// Wraps a Command with a correlation id.
#[derive(Debug, Deserialize)]
pub struct IncomingFrame {
    pub id: String,
    #[serde(flatten)]
    pub command: crate::bus::Command,
}

/// One JSON line sent on the control socket. Either a reply to a command
/// (correlated by id) or a lifecycle/state event.
#[derive(Debug, Serialize)]
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
    fn outgoing_reply_serializes_correctly() {
        let f = OutgoingFrame::Reply { reply_to: "abc".into(), ok: true, error: None };
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
```

Wire into `main.rs`:

```rust
mod protocol;
```

**Step 2: Run tests**

Run: `cargo test -p video-coach-app protocol::`
Expected: 3 passed.

**Step 3: Commit**

```bash
git add crates/video-coach-app/src/protocol.rs crates/video-coach-app/src/main.rs
git commit -m "feat(app): control socket wire protocol (IncomingFrame / OutgoingFrame)"
```

---

## Task 5: Control socket adapter (TCP loopback, JSON-lines)

**Files:**
- Create: `crates/video-coach-app/src/control_socket.rs`
- Modify: `crates/video-coach-app/src/main.rs`

**Step 1: Implement the adapter**

```rust
// crates/video-coach-app/src/control_socket.rs
#![cfg(feature = "control-socket")]

use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::broadcast;
use crate::bus::BusHandle;
use crate::protocol::{IncomingFrame, OutgoingFrame};

/// Bind a TCP listener on 127.0.0.1 at `port` (0 = OS-chosen).
/// Returns the bound address; the caller is responsible for emitting it.
pub async fn bind(port: u16) -> std::io::Result<(TcpListener, std::net::SocketAddr)> {
    let listener = TcpListener::bind(("127.0.0.1", port)).await?;
    let addr = listener.local_addr()?;
    Ok((listener, addr))
}

pub async fn serve(
    listener: TcpListener,
    bus: BusHandle,
    events: broadcast::Sender<OutgoingFrame>,
) {
    loop {
        let (sock, _peer) = match listener.accept().await {
            Ok(x) => x,
            Err(e) => {
                tracing::warn!(target: "control_socket", error = %e, "accept failed");
                continue;
            }
        };
        let bus = bus.clone();
        let events_rx = events.subscribe();
        tokio::spawn(handle_connection(sock, bus, events_rx));
    }
}

async fn handle_connection(
    sock: TcpStream,
    bus: BusHandle,
    mut events_rx: broadcast::Receiver<OutgoingFrame>,
) {
    let (read_half, mut write_half) = sock.into_split();
    let mut lines = BufReader::new(read_half).lines();
    let write_handle: Arc<tokio::sync::Mutex<tokio::net::tcp::OwnedWriteHalf>> =
        Arc::new(tokio::sync::Mutex::new(write_half));

    let writer_for_events = write_handle.clone();
    tokio::spawn(async move {
        loop {
            match events_rx.recv().await {
                Ok(frame) => {
                    let line = match serde_json::to_string(&frame) {
                        Ok(s) => s,
                        Err(_) => continue,
                    };
                    let mut w = writer_for_events.lock().await;
                    if w.write_all(line.as_bytes()).await.is_err() { return; }
                    if w.write_all(b"\n").await.is_err() { return; }
                }
                Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => return,
            }
        }
    });

    while let Ok(Some(line)) = lines.next_line().await {
        let frame: IncomingFrame = match serde_json::from_str(&line) {
            Ok(f) => f,
            Err(e) => {
                let reply = OutgoingFrame::Reply {
                    reply_to: "".into(), ok: false,
                    error: Some(format!("bad frame: {e}")),
                };
                let mut w = write_handle.lock().await;
                let _ = w.write_all(serde_json::to_string(&reply).unwrap().as_bytes()).await;
                let _ = w.write_all(b"\n").await;
                continue;
            }
        };
        let id = frame.id.clone();
        let reply = bus.send(id.clone(), frame.command).await;
        let out = OutgoingFrame::Reply {
            reply_to: id,
            ok: reply.ok,
            error: reply.error,
        };
        let mut w = write_handle.lock().await;
        if w.write_all(serde_json::to_string(&out).unwrap().as_bytes()).await.is_err() { return; }
        if w.write_all(b"\n").await.is_err() { return; }
    }
}
```

**Step 2: Wire it into `main.rs`**

Replace the `main` body so that when `--control-socket=PORT` is passed, the adapter binds and the address is printed via tracing:

```rust
// crates/video-coach-app/src/main.rs (full replacement of main fn body)
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    logging::init(args.json_logs);
    tracing::info!(target: "app.lifecycle", event = "app.launched", version = env!("CARGO_PKG_VERSION"));

    let (shutdown_tx, mut shutdown_rx) = tokio::sync::watch::channel(false);
    let bus = bus::spawn(shutdown_tx.clone());
    let (events_tx, _) = tokio::sync::broadcast::channel::<protocol::OutgoingFrame>(256);

    #[cfg(feature = "control-socket")]
    if let Some(port) = args.control_socket {
        let (listener, addr) = control_socket::bind(port).await?;
        // The harness reads stdout for this exact event to discover the port.
        tracing::info!(target: "app.lifecycle", event = "control_socket.ready", addr = %addr);
        tokio::spawn(control_socket::serve(listener, bus.clone(), events_tx.clone()));
    }

    tokio::select! {
        _ = tokio::signal::ctrl_c() => {
            tracing::info!(target: "app.lifecycle", event = "app.shutdown_requested", source = "signal");
        }
        _ = shutdown_rx.changed() => {}
    }

    tracing::info!(target: "app.lifecycle", event = "app.shutdown");
    Ok(())
}
```

Add `mod control_socket;` near the other module declarations, gated:

```rust
#[cfg(feature = "control-socket")]
mod control_socket;
```

**Step 3: Manual smoke test**

Run: `cargo run -p video-coach-app -- --json-logs --control-socket 0`
Expected: a JSON-line with `"event":"control_socket.ready"` and an `"addr":"127.0.0.1:NNNN"` field. App stays running until Ctrl-C.

**Step 4: Verify release builds compile out the socket**

Run: `cargo build -p video-coach-app --release --no-default-features`
Expected: builds clean, with no `control_socket` symbol (verify via `nm target/release/video-coach-app | grep control_socket || echo OK_NOT_FOUND`).

**Step 5: Commit**

```bash
git add crates/video-coach-app/src/control_socket.rs crates/video-coach-app/src/main.rs
git commit -m "feat(app): control socket adapter (TCP loopback, JSON-lines, debug-only)"
```

---

## Task 6: Bridge `tracing` events → control socket subscribers

**Files:**
- Modify: `crates/video-coach-app/src/logging.rs`
- Create: `crates/video-coach-app/src/event_layer.rs`
- Modify: `crates/video-coach-app/src/main.rs`

**Background:** Right now the control socket can dispatch commands and emit replies, but there's no way for it to push lifecycle events. We need a `tracing-subscriber` `Layer` impl that intercepts events with `target = "app.lifecycle"` (and a curated list of others) and forwards them to the `events_tx` broadcast channel.

**Step 1: Define the curated event-target list**

In `event_layer.rs`:

```rust
// crates/video-coach-app/src/event_layer.rs
use std::collections::HashMap;
use tokio::sync::broadcast;
use tracing::{Event, Subscriber};
use tracing_subscriber::{layer::Context, registry::LookupSpan, Layer};
use crate::protocol::OutgoingFrame;

/// Event targets forwarded to the control socket. Anything outside this
/// list stays in the regular log stream and is not pushed to subscribers.
const FORWARDED_TARGETS: &[&str] = &[
    "app.lifecycle",
    "project",
    "recording",
    "preview",
    "export",
    "control_socket",
];

pub struct ForwardLayer {
    pub events: broadcast::Sender<OutgoingFrame>,
}

impl<S> Layer<S> for ForwardLayer
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        let target = event.metadata().target();
        if !FORWARDED_TARGETS.iter().any(|t| target == *t) { return; }

        let mut visitor = JsonVisitor::default();
        event.record(&mut visitor);
        let event_name = visitor.fields.remove("event")
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

#[derive(Default)]
struct JsonVisitor {
    fields: HashMap<String, serde_json::Value>,
}

impl tracing::field::Visit for JsonVisitor {
    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        self.fields.insert(field.name().to_string(), serde_json::Value::String(format!("{value:?}")));
    }
    fn record_str(&mut self, field: &tracing::field::Field, value: &str) {
        self.fields.insert(field.name().to_string(), serde_json::Value::String(value.to_string()));
    }
    fn record_i64(&mut self, field: &tracing::field::Field, value: i64) {
        self.fields.insert(field.name().to_string(), serde_json::Value::Number(value.into()));
    }
    fn record_u64(&mut self, field: &tracing::field::Field, value: u64) {
        self.fields.insert(field.name().to_string(), serde_json::Value::Number(value.into()));
    }
    fn record_bool(&mut self, field: &tracing::field::Field, value: bool) {
        self.fields.insert(field.name().to_string(), serde_json::Value::Bool(value));
    }
}
```

**Step 2: Update `logging::init` to accept an optional `ForwardLayer`**

```rust
// crates/video-coach-app/src/logging.rs
use tracing_subscriber::{EnvFilter, fmt, prelude::*};
use crate::event_layer::ForwardLayer;

pub fn init(json: bool, forward: Option<ForwardLayer>) {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    let registry = tracing_subscriber::registry().with(filter);
    let registry = match forward {
        Some(l) => registry.with(Some(l)),
        None    => registry.with(None::<ForwardLayer>),
    };
    if json {
        registry.with(fmt::layer().json().with_writer(std::io::stdout)).init();
    } else {
        registry.with(fmt::layer().with_writer(std::io::stderr)).init();
    }
}
```

**Step 3: Update `main` to construct the layer when the socket is enabled**

```rust
// in main.rs, before logging::init
let (events_tx, _) = tokio::sync::broadcast::channel::<protocol::OutgoingFrame>(256);

let forward_layer;
#[cfg(feature = "control-socket")]
{
    forward_layer = if args.control_socket.is_some() {
        Some(event_layer::ForwardLayer { events: events_tx.clone() })
    } else {
        None
    };
}
#[cfg(not(feature = "control-socket"))]
let forward_layer: Option<event_layer::ForwardLayer> = None;

logging::init(args.json_logs, forward_layer);
```

Add `mod event_layer;` (always — the `Layer` itself is platform-agnostic; only the *socket* is gated).

**Step 4: Manual smoke test**

Run: `cargo run -p video-coach-app -- --json-logs --control-socket 0`
Then in another shell:
```bash
nc 127.0.0.1 <PORT-FROM-FIRST-LINE>
{"id":"1","cmd":"ping"}
```
Expected: receive `{"reply_to":"1","ok":true}` and an event `{"event":"app.ping","ts":...}`. Then send `{"id":"2","cmd":"quit"}` — expect a reply, an `app.shutdown_requested` event, an `app.shutdown` event, and the app exits.

**Step 5: Commit**

```bash
git add crates/video-coach-app/src/event_layer.rs crates/video-coach-app/src/logging.rs crates/video-coach-app/src/main.rs
git commit -m "feat(app): bridge tracing events to control socket subscribers"
```

---

## Task 7: `video-coach-harness` library — subprocess launcher + client

**Files:**
- Create: `crates/video-coach-harness/Cargo.toml`
- Create: `crates/video-coach-harness/src/lib.rs`
- Modify: root `Cargo.toml` (workspace members)

**Step 1: Add to workspace**

Root `Cargo.toml`:

```toml
members = ["crates/video-coach-core", "crates/video-coach-app", "crates/video-coach-harness"]
```

**Step 2: Create the crate manifest**

```toml
# crates/video-coach-harness/Cargo.toml
[package]
name = "video-coach-harness"
version = "0.1.0"
edition.workspace = true
rust-version.workspace = true
license.workspace = true

[dependencies]
tokio = { version = "1", features = ["rt-multi-thread", "macros", "io-util", "net", "process", "time", "sync"] }
serde = { workspace = true }
serde_json = { workspace = true }
anyhow = "1"

[dev-dependencies]
tokio = { version = "1", features = ["test-util"] }
```

**Step 3: Implement the harness library**

```rust
// crates/video-coach-harness/src/lib.rs
use std::path::PathBuf;
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio::process::{Child, Command};
use tokio::sync::mpsc;

#[derive(Debug, serde::Deserialize)]
pub struct Frame {
    #[serde(default)]
    pub event: Option<String>,
    #[serde(default)]
    pub reply_to: Option<String>,
    #[serde(default)]
    pub ok: Option<bool>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub ts: Option<u128>,
    #[serde(flatten)]
    pub other: serde_json::Map<String, serde_json::Value>,
}

pub struct App {
    child: Child,
    events: mpsc::UnboundedReceiver<Frame>,
    sock_writer: tokio::net::tcp::OwnedWriteHalf,
    next_id: u64,
}

impl App {
    /// Locate the app binary. Cargo sets CARGO_BIN_EXE_<crate> at test time.
    pub fn binary_path() -> PathBuf {
        std::env::var("CARGO_BIN_EXE_video-coach-app")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("../debug/video-coach-app"))
    }

    pub async fn launch() -> anyhow::Result<Self> {
        let mut cmd = Command::new(Self::binary_path());
        cmd.arg("--json-logs").arg("--control-socket").arg("0");
        cmd.stdout(Stdio::piped()).stderr(Stdio::null());
        let mut child = cmd.spawn()?;

        let stdout = child.stdout.take().expect("piped stdout");
        let mut lines = BufReader::new(stdout).lines();

        // Drain stdout looking for the control_socket.ready event.
        let mut port: Option<u16> = None;
        while let Some(line) = lines.next_line().await? {
            let v: serde_json::Value = serde_json::from_str(&line)?;
            if v["fields"]["event"] == "control_socket.ready" {
                let addr = v["fields"]["addr"].as_str().unwrap_or("");
                port = addr.rsplit(':').next().and_then(|s| s.parse().ok());
                break;
            }
        }
        let port = port.ok_or_else(|| anyhow::anyhow!("never saw control_socket.ready"))?;

        let stream = TcpStream::connect(("127.0.0.1", port)).await?;
        let (read_half, write_half) = stream.into_split();

        let (event_tx, event_rx) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            let mut sock_lines = BufReader::new(read_half).lines();
            while let Ok(Some(line)) = sock_lines.next_line().await {
                if let Ok(frame) = serde_json::from_str::<Frame>(&line) {
                    let _ = event_tx.send(frame);
                }
            }
        });

        Ok(Self { child, events: event_rx, sock_writer: write_half, next_id: 0 })
    }

    pub async fn send(&mut self, cmd: serde_json::Value) -> anyhow::Result<Frame> {
        self.next_id += 1;
        let id = self.next_id.to_string();
        let mut frame = cmd;
        frame.as_object_mut().unwrap().insert("id".into(), id.clone().into());
        let line = serde_json::to_string(&frame)?;
        self.sock_writer.write_all(line.as_bytes()).await?;
        self.sock_writer.write_all(b"\n").await?;
        loop {
            let f = self.events.recv().await
                .ok_or_else(|| anyhow::anyhow!("event channel closed"))?;
            if f.reply_to.as_deref() == Some(&id) { return Ok(f); }
        }
    }

    pub async fn next_event(&mut self) -> Option<Frame> {
        self.events.recv().await
    }

    pub async fn wait_for_event(&mut self, name: &str, timeout: std::time::Duration) -> anyhow::Result<Frame> {
        tokio::time::timeout(timeout, async {
            loop {
                let f = self.events.recv().await
                    .ok_or_else(|| anyhow::anyhow!("channel closed"))?;
                if f.event.as_deref() == Some(name) { return Ok(f); }
            }
        }).await?
    }

    pub async fn quit(mut self) -> anyhow::Result<std::process::ExitStatus> {
        let _ = self.send(serde_json::json!({"cmd": "quit"})).await;
        Ok(self.child.wait().await?)
    }
}
```

**Step 4: Run cargo check on the workspace**

Run: `cargo check --workspace`
Expected: clean.

**Step 5: Commit**

```bash
git add Cargo.toml crates/video-coach-harness/
git commit -m "feat(harness): subprocess launcher + JSON-line client for control socket"
```

---

## Task 8: First end-to-end smoke test

**Files:**
- Create: `crates/video-coach-harness/tests/smoke.rs`

**Step 1: Write the failing test**

```rust
// crates/video-coach-harness/tests/smoke.rs
use std::time::Duration;
use video_coach_harness::App;

#[tokio::test]
async fn launch_ping_quit_roundtrip() -> anyhow::Result<()> {
    let mut app = App::launch().await?;

    // Verify app.launched event arrived.
    app.wait_for_event("app.launched", Duration::from_secs(2)).await?;

    // Send a ping and verify it's acknowledged.
    let reply = app.send(serde_json::json!({ "cmd": "ping" })).await?;
    assert_eq!(reply.ok, Some(true), "ping should succeed");
    app.wait_for_event("app.ping", Duration::from_secs(2)).await?;

    // Quit and verify clean exit.
    let status = app.quit().await?;
    assert!(status.success(), "app should exit cleanly, got {:?}", status);
    Ok(())
}
```

**Step 2: Run the test**

Run: `cargo test -p video-coach-harness --test smoke`
Expected: PASS. The full launch → handshake → command → event → quit loop is now proven end-to-end.

**Step 3: Commit**

```bash
git add crates/video-coach-harness/tests/smoke.rs
git commit -m "test(harness): smoke test — launch, ping, quit roundtrip via control socket"
```

---

## Task 9: Git LFS + fixtures manifest

**Files:**
- Create: `.gitattributes`
- Create: `fixtures/manifest.json`
- Create: `fixtures/.gitkeep`

**Prerequisite:** Git LFS installed locally — `git lfs version` should print a version. If not: `brew install git-lfs && git lfs install`.

**Step 1: Configure LFS tracking**

```
# .gitattributes
fixtures/**/*.mp4 filter=lfs diff=lfs merge=lfs -text
fixtures/**/*.mov filter=lfs diff=lfs merge=lfs -text
fixtures/**/*.wav filter=lfs diff=lfs merge=lfs -text
fixtures/**/*.m4a filter=lfs diff=lfs merge=lfs -text
```

**Step 2: Prepare the fixtures**

Source files on the user's machine outside the repo:

- **Webcam clip**: `/Users/taylor/coach-cutups/2026-spring/week-2/recordings/clip-EE39C52F-C292-4B1F-9702-44F6A4BADC50.mov`
  Duration 17.3 s, 1920×1080, H.264 + AAC, 45 MB. Copy verbatim into `fixtures/webcam.mov`.

- **Source video** (master): `/Users/taylor/Downloads/VID_20260425_090418_01_01.mp4`
  Duration 83.7 min, 3840×2160 (4K), H.264 + AAC, 32 GB. Extracted into **two fixtures from different minutes** so they double as distinct source assets — exercises the multi-source-video project case (v1 supports up to 2 source videos per project):
  - `fixtures/source-1080p.mp4` — minute **25** (`00:25:00 → 00:26:00`), re-encoded to 1920×1080 at ~6 Mbps (~45 MB). Default for most flow tests.
  - `fixtures/source-4k.mp4` — **30 seconds** starting at minute **50** (`00:50:00 → 00:50:30`), re-encoded at native 3840×2160 at ~20 Mbps (~75 MB). Used for 4K-playback regression tests; v1 had real bugs in the 4K decode/scrub path that we want to catch automatically. 30s is plenty to exercise decode/scrub; the duration is shorter than the 1080p fixture purely to keep LFS bandwidth in check.

`ffmpeg` is used here as a one-time dev/build tool. It is **not** an app dependency — the runtime project still uses GStreamer exclusively. Install with `brew install ffmpeg` if not present.

```bash
mkdir -p fixtures

# Webcam: straight copy.
cp "/Users/taylor/coach-cutups/2026-spring/week-2/recordings/clip-EE39C52F-C292-4B1F-9702-44F6A4BADC50.mov" \
   fixtures/webcam.mov

# 1080p source: extract minute 25, downscale to 1080p, re-encode at 6 Mbps.
# -ss before -i seeks fast (keyframe-aligned); the re-encode pass cleans
# up the seek edge.
ffmpeg -ss 00:25:00 -t 00:01:00 -i "/Users/taylor/Downloads/VID_20260425_090418_01_01.mp4" \
       -vf "scale=1920:1080:flags=lanczos" \
       -c:v libx264 -preset slow -b:v 6000k -maxrate 6500k -bufsize 12000k \
       -c:a aac -b:a 128k \
       -movflags +faststart \
       fixtures/source-1080p.mp4

# 4K source: different minute (50, not 25) so this doubles as a second
# distinct source asset. 30 seconds at native resolution, ~20 Mbps —
# enough to exercise 4K decode/scrub without bloating LFS.
ffmpeg -ss 00:50:00 -t 00:00:30 -i "/Users/taylor/Downloads/VID_20260425_090418_01_01.mp4" \
       -c:v libx264 -preset slow -b:v 20000k -maxrate 22000k -bufsize 40000k \
       -c:a aac -b:a 128k \
       -movflags +faststart \
       fixtures/source-4k.mp4

# Sanity-check both files: 1080p should print ~60s, 4K should print ~30s.
ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 fixtures/source-1080p.mp4
ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 fixtures/source-4k.mp4
```

For audio (`fixtures/mic.wav`), defer until a recording-flow test actually needs it. Phase 2's smoke test does not. When needed, generate a synthetic tone or extract the audio track from the webcam clip.

**Step 3: Initialize the fixtures manifest**

```json
// fixtures/manifest.json
{
  "schemaVersion": 1,
  "fixtures": {
    "source-1080p.mp4": {
      "purpose": "Default sports source video — input timeline for most recording-flow tests.",
      "durationSeconds": 60,
      "width": 1920,
      "height": 1080,
      "originalSource": "/Users/taylor/Downloads/VID_20260425_090418_01_01.mp4",
      "trimSpec": "00:25:00 → 00:26:00 (re-encoded 1080p H.264 ~6 Mbps)"
    },
    "source-4k.mp4": {
      "purpose": "4K source for playback/scrub regression tests (v1 had bugs in the 4K decode path) AND a distinct second source asset for multi-source-video project tests.",
      "durationSeconds": 30,
      "width": 3840,
      "height": 2160,
      "originalSource": "/Users/taylor/Downloads/VID_20260425_090418_01_01.mp4",
      "trimSpec": "00:50:00 → 00:50:30 (re-encoded native 4K H.264 ~20 Mbps)"
    },
    "webcam.mov": {
      "purpose": "Pre-recorded webcam clip swapped in for live capture in test mode.",
      "durationSeconds": 17.26,
      "width": 1920,
      "height": 1080,
      "originalSource": "/Users/taylor/coach-cutups/2026-spring/week-2/recordings/clip-EE39C52F-C292-4B1F-9702-44F6A4BADC50.mov",
      "note": "Short — test recordings should stay ≤15s, or the fixture pipeline must loop the clip."
    }
  },
  "totalSizeBudgetMB": 300
}
```

**Step 4: Commit (LFS will pick up the binary files automatically)**

```bash
git add .gitattributes fixtures/manifest.json fixtures/source-1080p.mp4 fixtures/source-4k.mp4 fixtures/webcam.mov
git commit -m "build: enable Git LFS for fixtures + initial source/webcam fixtures"
```

Verify LFS picked up the binaries (not committed inline as text):

```bash
git lfs ls-files
```

Expected output: lines naming each fixture with its LFS SHA.

**Note on `mic.wav`**: not included in this task — defer until a recording-flow test in a later phase needs it. The `manifest.json` will be extended at that point.

---

## Task 10: CI — LFS checkout + harness tests

**Files:**
- Modify: `.github/workflows/rust.yml`

**Step 1: Update the workflow**

```yaml
# .github/workflows/rust.yml
name: rust
on:
  push:
    branches: [main, rust-rewrite]
  pull_request:
jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        os: [macos-latest, windows-latest, ubuntu-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
        with:
          lfs: true
      - uses: dtolnay/rust-toolchain@stable
        with:
          components: rustfmt, clippy
      - uses: Swatinem/rust-cache@v2
      - run: cargo fmt --check
      - run: cargo clippy --workspace --all-targets -- -D warnings
      - run: cargo test --workspace
```

**Step 2: Push and verify**

```bash
git add .github/workflows/rust.yml
git commit -m "ci: enable LFS checkout + ensure harness tests run on all OSes"
git push
```

Wait for the GitHub Actions run.
Expected: all three OS jobs green. The smoke test from Task 8 runs as part of `cargo test --workspace` and exercises the full subprocess launch on every OS.

---

## Phase 2 exit criteria

- `cargo test --workspace` green on all three platforms in CI.
- Harness smoke test (Task 8) passes — proves launch / control socket / Command bus / tracing-event forwarding all work end-to-end.
- Release build with `--no-default-features` produces a binary with no control-socket symbols (Task 5 Step 4).
- Git LFS configured and CI checks out fixture content (even if `fixtures/` is empty for now).
- The architecture is extensible: adding a new command type is a single enum variant + match arm in `bus.rs`; adding a new tracking event is a single `tracing::info!` call with a recognized target.

When this is green, every subsequent phase (capture, compositor, export, UI) is built on top of these rails. Phase 3 starts wiring real GStreamer pipelines and gets E2E coverage from day one via the harness.
