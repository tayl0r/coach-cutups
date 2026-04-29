mod bus;
mod cli;
mod event_layer;
mod logging;
mod protocol;
mod ui;

// Only the control_socket adapter and the layer's broadcast wiring stay
// behind the feature flag. The bus + protocol are universal: Phase 6's
// Slint UI also dispatches via the bus.
#[cfg(feature = "control-socket")]
mod control_socket;

use clap::Parser;
use cli::Args;

fn main() -> anyhow::Result<()> {
    let args = Args::parse();

    // We drive the runtime explicitly rather than via #[tokio::main] because
    // Slint's event loop must own the main thread (winit/NSApplication on
    // macOS). The runtime has its own worker pool; entering it on the main
    // thread only enables `tokio::spawn` from this thread, it does not park
    // the thread on the runtime.
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    let _enter = runtime.enter();

    // events_tx must exist before logging::init so the ForwardLayer can hold
    // the sender. Constructed unconditionally; the no-feature build never
    // wires it to a subscriber but keeps the type plumbing uniform.
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
    tracing::info!(
        target: "app.lifecycle",
        event = "app.launched",
        version = env!("CARGO_PKG_VERSION"),
    );

    let (shutdown_tx, mut shutdown_rx) = tokio::sync::watch::channel(false);

    // The bus runs on the same runtime as the socket and any UI-spawned async
    // work. Phase 6 Task 5 will wire UI callbacks to bus.send() through this
    // same handle.
    let bus = bus::spawn_on(runtime.handle(), shutdown_tx.clone());
    let _ = &bus;

    #[cfg(feature = "control-socket")]
    {
        if let Some(port) = args.control_socket {
            let (listener, addr) = runtime.block_on(control_socket::bind(port))?;
            // The harness reads stdout for this exact event to discover the port.
            tracing::info!(
                target: "app.lifecycle",
                event = "control_socket.ready",
                addr = %addr,
            );
            runtime.spawn(control_socket::serve(
                listener,
                bus.clone(),
                events_tx.clone(),
            ));
        }
    }
    #[cfg(not(feature = "control-socket"))]
    let _ = &shutdown_tx;

    if args.headless {
        // No window to run — block on signal or socket-driven shutdown.
        runtime.block_on(async move {
            tokio::select! {
                _ = tokio::signal::ctrl_c() => {
                    tracing::info!(
                        target: "app.lifecycle",
                        event = "app.shutdown_requested",
                        source = "signal",
                    );
                }
                _ = shutdown_rx.changed() => {}
            }
        });
    } else {
        // Slint blocks the main thread until the window closes. Tokio
        // workers continue polling the socket / bus while the UI runs.
        ui::run(bus, runtime.handle().clone(), shutdown_tx)?;
    }

    tracing::info!(target: "app.lifecycle", event = "app.shutdown");
    Ok(())
}
