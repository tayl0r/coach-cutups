mod cli;
mod event_layer;
mod logging;

// bus, protocol, and control_socket are only reachable from the control-socket
// feature path; gating the modules together keeps release-no-default-features
// builds free of dead bus/protocol code.
#[cfg(feature = "control-socket")]
mod bus;
#[cfg(feature = "control-socket")]
mod control_socket;
#[cfg(feature = "control-socket")]
mod protocol;

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
    tracing::info!(target: "app.lifecycle", event = "app.launched", version = env!("CARGO_PKG_VERSION"));

    let (shutdown_tx, mut shutdown_rx) = tokio::sync::watch::channel(false);

    // Bus + control socket are only useful when the socket is the remote
    // driver. Without the feature, only Ctrl-C ends the app.
    #[cfg(feature = "control-socket")]
    {
        let bus = bus::spawn(shutdown_tx.clone());
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

    tokio::select! {
        _ = tokio::signal::ctrl_c() => {
            tracing::info!(target: "app.lifecycle", event = "app.shutdown_requested", source = "signal");
        }
        _ = shutdown_rx.changed() => {}
    }

    tracing::info!(target: "app.lifecycle", event = "app.shutdown");
    Ok(())
}
