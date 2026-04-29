//! Slint UI bridge.
//!
//! Slint owns the main thread (winit's macOS NSApplication runloop must run
//! there). The tokio runtime runs on worker threads. UI callbacks dispatch
//! commands by spawning short-lived async tasks via the supplied
//! `tokio::runtime::Handle`; replies / state pushes from the bus side
//! re-enter the UI thread via `slint::invoke_from_event_loop`.

use crate::bus::BusHandle;

slint::include_modules!();

pub fn run(
    bus: BusHandle,
    rt: tokio::runtime::Handle,
    shutdown_tx: tokio::sync::watch::Sender<bool>,
) -> anyhow::Result<()> {
    // Bus, runtime handle, and shutdown_tx are wired into UI callbacks
    // in Tasks 3–5. The current Task 2 deliverable is "Slint runs on
    // main thread, tokio runs alongside" — proven by an empty window
    // opening and the bus + socket continuing to function.
    let _ = (&bus, &rt, &shutdown_tx);

    let window = MainWindow::new()?;
    window.run().map_err(Into::into)
}
