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
//! | File → Quit              | `on_quit_clicked` → bus `Quit`         |
//! | Cmd-Q (macOS)            | winit translates to close → same as #1 |
//! | Control socket `quit`    | bus `Quit` handler in bus.rs           |
//! | OS signal (`--headless`) | `tokio::select!` in main.rs            |

use crate::bus::{BusHandle, Command};
use slint::ComponentHandle;

slint::include_modules!();

/// Correlation id stamped on UI-originated bus commands. Future spans /
/// tracing bridge can route on this prefix.
const UI_COMMAND_ID: &str = "ui";

pub fn run(
    bus: BusHandle,
    rt: tokio::runtime::Handle,
    shutdown_tx: tokio::sync::watch::Sender<bool>,
) -> anyhow::Result<()> {
    let window = MainWindow::new()?;

    // Path 1: window close button / Cmd-Q (winit dispatches CloseRequested).
    let shutdown_for_close = shutdown_tx.clone();
    window.window().on_close_requested(move || {
        tracing::info!(
            target: "app.lifecycle",
            event = "app.shutdown_requested",
            source = "window_close",
        );
        let _ = shutdown_for_close.send(true);
        slint::CloseRequestResponse::HideWindow
    });

    // Path 3 / 4 echo: when shutdown_tx fires from any source, unblock
    // window.run().
    let mut shutdown_rx = shutdown_tx.subscribe();
    rt.spawn(async move {
        if shutdown_rx.changed().await.is_ok() && *shutdown_rx.borrow() {
            let _ = slint::quit_event_loop();
        }
    });

    // File → Quit: dispatch through bus so the same shutdown path runs
    // as for the socket-driven Quit.
    let bus_for_quit = bus.clone();
    let rt_for_quit = rt.clone();
    window.on_quit_clicked(move || {
        let bus = bus_for_quit.clone();
        rt_for_quit.spawn(async move {
            bus.send(UI_COMMAND_ID.into(), Command::Quit).await;
        });
    });

    // File → Open Project: pop a folder picker, dispatch OpenProject on
    // the user's choice, push the project's name back into the title-bar
    // label on success.
    let bus_for_open = bus.clone();
    let rt_for_open = rt.clone();
    let weak = window.as_weak();
    window.on_open_project_clicked(move || {
        let bus = bus_for_open.clone();
        let weak = weak.clone();
        rt_for_open.spawn(async move {
            // rfd uses xdg-portal on Linux, NSOpenPanel on macOS,
            // IFileOpenDialog on Windows. Cancellation returns None;
            // bail silently.
            let chosen = rfd::AsyncFileDialog::new().pick_folder().await;
            let Some(folder) = chosen else { return; };
            let path = folder.path().to_string_lossy().into_owned();
            let path_for_title = path.clone();
            let reply = bus
                .send(
                    UI_COMMAND_ID.into(),
                    Command::OpenProject { path: path.clone() },
                )
                .await;
            if reply.ok {
                slint::invoke_from_event_loop(move || {
                    if let Some(w) = weak.upgrade() {
                        w.set_project_title(path_for_title.into());
                    }
                })
                .ok();
            } else {
                tracing::warn!(
                    target: "ui",
                    error = ?reply.error,
                    path = %path,
                    "open_project failed",
                );
            }
        });
    });

    window.run().map_err(Into::into)
}
