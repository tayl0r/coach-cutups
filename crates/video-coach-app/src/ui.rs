//! Slint UI bridge.
//!
//! Slint owns the main thread (winit's macOS NSApplication runloop must run
//! there). The tokio runtime runs on worker threads. UI callbacks dispatch
//! commands by spawning short-lived async tasks via the supplied
//! `tokio::runtime::Handle`; replies / state pushes from the bus side
//! re-enter the UI thread via `slint::invoke_from_event_loop`.
//!
//! Shutdown topology (Phase 6 Task 3): every termination path converges
//! on (a) `shutdown_tx.send(true)` — for the headless block_on watch and
//! socket-server task — and (b) `slint::quit_event_loop()` to unblock the
//! main thread's `window.run()`. Specifically:
//!
//! | Trigger                  | Path                                   |
//! |--------------------------|----------------------------------------|
//! | Window close button      | `on_close_requested` in this file      |
//! | File → Quit (Phase 6 T5) | UI callback → bus `Quit`               |
//! | Cmd-Q (macOS)            | winit translates to close → same as #1 |
//! | Control socket `quit`    | bus `Quit` handler in bus.rs           |
//! | OS signal (`--headless`) | `tokio::select!` in main.rs            |

use crate::bus::BusHandle;
use slint::ComponentHandle;

slint::include_modules!();

pub fn run(
    bus: BusHandle,
    rt: tokio::runtime::Handle,
    shutdown_tx: tokio::sync::watch::Sender<bool>,
) -> anyhow::Result<()> {
    let window = MainWindow::new()?;

    // Path 1: window close button / Cmd-Q (winit dispatches CloseRequested).
    // Sending shutdown_tx ensures the socket-server task and any future
    // headless block_on watchers wake up. Returning HideWindow so Slint
    // also stops drawing and unwinds the event loop.
    let shutdown_for_close = shutdown_tx.clone();
    window.window().on_close_requested(move || {
        tracing::info!(target: "app.lifecycle", event = "app.shutdown_requested", source = "window_close");
        let _ = shutdown_for_close.send(true);
        slint::CloseRequestResponse::HideWindow
    });

    // Path 3 / 4 echo: when shutdown_tx fires from any source (socket Quit,
    // signal in --headless mode that already exited but the runtime is
    // still alive, etc.), unblock window.run() too. Using subscribe()
    // gives a fresh receiver per event-loop start, independent of the
    // original `shutdown_rx` that main.rs holds.
    let mut shutdown_rx = shutdown_tx.subscribe();
    rt.spawn(async move {
        // Skip the initial `false` value; we only care about transitions to
        // true. `changed()` returns immediately if the value has *already*
        // changed since the last call — for a freshly subscribed receiver
        // that's the same as "wait for the next change."
        if shutdown_rx.changed().await.is_ok() && *shutdown_rx.borrow() {
            let _ = slint::quit_event_loop();
        }
    });

    // Bus is held by future menu / file-dialog callbacks (Task 5). Holding
    // the reference here keeps the type plumbing exercised end-to-end so
    // Task 5's edits stay surgical.
    let _ = &bus;

    window.run().map_err(Into::into)
}
