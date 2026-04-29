mod bus;
mod cli;
mod event_layer;
mod logging;
mod protocol;

// Only the control_socket adapter and the layer's broadcast wiring stay
// behind the feature flag. The bus + protocol are universal: Phase 6's
// Slint UI also dispatches via the bus.
#[cfg(feature = "control-socket")]
mod control_socket;

use clap::Parser;
use cli::Args;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();

    // events_tx must exist before logging::init so the ForwardLayer can hold
    // the sender. Constructed unconditionally; the no-feature build never wires
    // it to a subscriber but keeps the type plumbing uniform.
    #[cfg(feature = "control-socket")]
    let (events_tx, _) = tokio::sync::broadcast::channel::<protocol::OutgoingFrame>(256);

    #[cfg(feature = "control-socket")]
    let forward_layer = if args.control_socket.is_some() {
        Some(event_layer::ForwardLayer {
            events: events_tx.clone(),
        })
    } else {
        None
    };
    #[cfg(not(feature = "control-socket"))]
    let forward_layer: Option<event_layer::ForwardLayer> = None;

    logging::init(args.json_logs, forward_layer);
    // Note: this event fires before the control_socket binds and before any
    // socket client subscribes to the broadcast channel. Socket-based test
    // harnesses cannot observe `app.launched` — they rely on
    // `control_socket.ready` (parsed from stdout) as the launch signal.
    // See `video-coach-harness::App::launch` and `tests/smoke.rs` for the
    // existing workaround. Don't add tests that wait on `app.launched`.
    tracing::info!(target: "app.lifecycle", event = "app.launched", version = env!("CARGO_PKG_VERSION"));

    let (shutdown_tx, mut shutdown_rx) = tokio::sync::watch::channel(false);

    // The bus is universal — every command (UI, socket, signal) flows through
    // it. Spawning unconditionally costs one idle mpsc loop in the
    // no-feature build; harmless and avoids dead-code warnings on bus.rs.
    let bus = bus::spawn(shutdown_tx.clone());
    let _ = &bus; // silence unused warning when no consumer is wired in this build

    #[cfg(feature = "control-socket")]
    {
        if let Some(port) = args.control_socket {
            let (listener, addr) = control_socket::bind(port).await?;
            // The harness reads stdout for this exact event to discover the port.
            tracing::info!(target: "app.lifecycle", event = "control_socket.ready", addr = %addr);
            tokio::spawn(control_socket::serve(
                listener,
                bus.clone(),
                events_tx.clone(),
            ));
        }
    }
    #[cfg(not(feature = "control-socket"))]
    let _ = &shutdown_tx;

    // `--headless` is currently always implied (no UI built yet). Phase 6
    // Task 1 wires the Slint window behind `!args.headless`.
    let _ = args.headless;

    tokio::select! {
        _ = tokio::signal::ctrl_c() => {
            tracing::info!(target: "app.lifecycle", event = "app.shutdown_requested", source = "signal");
        }
        _ = shutdown_rx.changed() => {}
    }

    tracing::info!(target: "app.lifecycle", event = "app.shutdown");
    Ok(())
}
