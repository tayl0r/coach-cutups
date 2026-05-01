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
use crate::frame_sink::{
    ClipListSlot, ExportProgressSlot, FrameSlot, PlayerStateSlot, RecordingStateSlot,
};
use crate::last_project;
use slint::ComponentHandle;

slint::include_modules!();

/// Correlation id stamped on UI-originated bus commands. Future spans /
/// tracing bridge can route on this prefix.
const UI_COMMAND_ID: &str = "ui";

/// Display-rate timer interval. 30 Hz is the source's native rate for
/// our test fixtures and the modal expectation for source-video
/// playback. Slint's Timer fires on the UI thread, so the closure is
/// allowed to call window setters directly — no `invoke_from_event_loop`
/// hop.
const FRAME_TICK_MS: u64 = 33;

// Phase 9: ui::run plumbs ClipListSlot for Task 4's sidebar; signature
// crosses the clippy too-many-arguments threshold. Splitting into a
// builder/struct is mechanical churn that the wider rewrite already
// rules out (every signature in this crate gets these slots passed
// directly), so allow it here the same way Phase 8 did for the bus
// handler.
#[allow(clippy::too_many_arguments)]
pub fn run(
    bus: BusHandle,
    rt: tokio::runtime::Handle,
    shutdown_tx: tokio::sync::watch::Sender<bool>,
    frame_slot: FrameSlot,
    player_state: PlayerStateSlot,
    // Phase 8: shared recording-mode state. Read by the 30 Hz timer to
    // drive the REC indicator + elapsed M:SS label. UI does not write
    // this slot; the bus owns mode transitions (Task 1) and the UI
    // observes them (Task 3).
    recording_state: RecordingStateSlot,
    // Phase 9: shared clip list for the sidebar. UI reader, bus writer
    // (Task 3 hydrates per fix #13). The 30 Hz timer reads it, converts
    // to a Slint model, and pushes via `set_clips`. Held alive for the
    // lifetime of the UI process.
    clip_list: ClipListSlot,
    // Phase 10 Task 0: export-progress slot. Plumbed through the
    // signature now so main.rs can wire it; Task 3's UI work hydrates
    // the export-sheet view from this slot. Task 0 holds the
    // reference for the lifetime of `run` but does not yet read it
    // (per the plan's hard scope guardrails).
    export_progress: ExportProgressSlot,
    startup_project: Option<String>,
) -> anyhow::Result<()> {
    // Hold the slot alive for the lifetime of `run`. Task 3 reads it
    // in the 30 Hz timer; Task 0 just keeps the reference rooted so
    // the bus-side writer's Arc clone stays valid.
    let _export_progress = export_progress;
    let window = MainWindow::new()?;

    // Phase 7 Task 4: drive `source-frame` from the shared frame slot at
    // display rate. The slot is overwritten at GStreamer's frame rate
    // (~30fps for our fixture) by SlintFrameSink on the streaming
    // thread; this timer reads + applies on the main thread, dropping
    // any frame the streaming thread has already replaced.
    let frame_timer = slint::Timer::default();
    let weak_for_frames = window.as_weak();
    let slot_for_timer = frame_slot.clone();
    let player_state_for_timer = player_state.clone();
    let recording_state_for_timer = recording_state.clone();
    let clip_list_for_timer = clip_list.clone();
    // Phase 9 Task 4: cache last-seen clip-list signature so we only
    // rebuild the Slint model when something actually changed.
    // (id, name, duration) tuples — same shape we hand to Slint.
    let mut cached_clips: Vec<(uuid::Uuid, String, f64)> = Vec::new();
    frame_timer.start(
        slint::TimerMode::Repeated,
        std::time::Duration::from_millis(FRAME_TICK_MS),
        move || {
            let next_frame = {
                let mut guard = slot_for_timer.lock().expect("frame slot poisoned");
                guard.take()
            };
            // Phase 8 adversarial fix #8: read RecordingStateSlot
            // BEFORE PlayerStateSlot so a transition out of Recording
            // (REC indicator clears) lands in the same frame as the
            // player resuming, not one tick later.
            let (mode_str, elapsed) = {
                use crate::frame_sink::RecordingMode;
                let g = recording_state_for_timer
                    .lock()
                    .expect("recording_state poisoned");
                let mode_str = match g.mode {
                    RecordingMode::Scanning => "scanning",
                    RecordingMode::RecordingStarting => "recording_starting",
                    RecordingMode::Recording => "recording",
                    // Phase 9 Task 4: surfaced via the same `mode`
                    // property; sidebar/transport bar conditionals key
                    // off this string.
                    RecordingMode::PreviewClip => "preview_clip",
                    // Phase 10 Task 0: the export-sheet UI in Task 3
                    // reads this string to swap to the progress view.
                    // Match the AppMode serde rename for consistency.
                    RecordingMode::Exporting => "exporting",
                };
                let elapsed = g
                    .recording_started_at_host
                    .map(|t0| t0.elapsed().as_secs_f32())
                    .unwrap_or(0.0);
                (mode_str, elapsed)
            };
            // Snapshot transport state. Drop the lock before touching
            // the window so we never block the position-poll task.
            let (pos, dur, playing) = {
                let g = player_state_for_timer
                    .lock()
                    .expect("player_state poisoned");
                (g.position_seconds, g.duration_seconds, g.is_playing)
            };
            // Phase 9 Task 4: clip list. Read; if changed, build a
            // Slint VecModel and push. Cheap to compare (clip lists
            // stay small — typical project has fewer than 50 clips).
            let clip_snapshot: Vec<(uuid::Uuid, String, f64)> = {
                let g = clip_list_for_timer.lock().expect("clip_list poisoned");
                g.iter()
                    .map(|c| (c.id, c.name.clone(), c.recording_duration))
                    .collect()
            };
            let clips_changed = clip_snapshot != cached_clips;
            // Phase 9 Task 4. The `selected-clip-id` + `preview-clip-name`
            // properties want to derive from the active clip when
            // mode == "preview_clip". The bus owns the source-of-truth
            // (current_mode) but the UI only sees the mode string and
            // the clip list — to find the current clip's id we'd need
            // to plumb the active uuid through. Workaround: when in
            // preview mode AND the clip list is non-empty, search by
            // the displayed `selected-clip-id` value the UI is
            // already setting (it's empty pre-open). For the MVP we
            // pick a simpler path: the clip-clicked handler stamps
            // selected-clip-id locally (UI-only) when it dispatches
            // open; on close-preview we clear it. So the timer just
            // resolves preview-clip-name from selected-clip-id. This
            // works because the bus has already validated and opened
            // the preview by the time the user-visible `mode`
            // property flips to preview_clip.
            let preview_name = if mode_str == "preview_clip" {
                if let Some(w) = weak_for_frames.upgrade() {
                    let sel = w.get_selected_clip_id().to_string();
                    clip_snapshot
                        .iter()
                        .find(|(id, _, _)| id.to_string() == sel)
                        .map(|(_, name, _)| name.clone())
                        .unwrap_or_default()
                } else {
                    String::new()
                }
            } else {
                String::new()
            };
            if let Some(w) = weak_for_frames.upgrade() {
                if let Some(buf) = next_frame {
                    w.set_source_frame(slint::Image::from_rgba8(buf));
                }
                w.set_position_seconds(pos as f32);
                w.set_duration_seconds(dur as f32);
                w.set_is_playing(playing);
                w.set_mode(mode_str.into());
                w.set_recording_elapsed_seconds(elapsed);
                if clips_changed {
                    let model: Vec<(f32, slint::SharedString, slint::SharedString)> = clip_snapshot
                        .iter()
                        .map(|(id, name, dur)| {
                            (
                                *dur as f32,
                                slint::SharedString::from(id.to_string()),
                                slint::SharedString::from(name.as_str()),
                            )
                        })
                        .collect();
                    w.set_clips(slint::ModelRc::new(slint::VecModel::from(model)));
                }
                w.set_preview_clip_name(preview_name.into());
                // When mode flips out of preview_clip, clear the local
                // selection-id stamp.
                if mode_str != "preview_clip" && !w.get_selected_clip_id().is_empty() {
                    w.set_selected_clip_id("".into());
                }
            }
            if clips_changed {
                cached_clips = clip_snapshot;
            }
        },
    );
    // Keep the timer alive for the lifetime of `run()`. Slint Timers
    // stop and free their captured closure on drop; the local binding
    // lives until window.run() returns at end of function.
    let _frame_timer = frame_timer;

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

    // Transport: play/pause toggle. Dispatches Play or Pause based on
    // the current is-playing property; doesn't try to remember its own
    // state since the bus + position-poll is the source of truth.
    let bus_for_play = bus.clone();
    let rt_for_play = rt.clone();
    let weak_for_play = window.as_weak();
    window.on_play_pause_clicked(move || {
        let bus = bus_for_play.clone();
        let was_playing = weak_for_play
            .upgrade()
            .map(|w| w.get_is_playing())
            .unwrap_or(false);
        rt_for_play.spawn(async move {
            let cmd = if was_playing {
                Command::Pause
            } else {
                Command::Play
            };
            bus.send(UI_COMMAND_ID.into(), cmd).await;
        });
    });

    // Volume slider: live-update player. Persistence to
    // project.preferences happens inside the SetScanVolume bus
    // handler. Slint slider's `changed` fires per-tick during drag,
    // so this is the live update path AND the persist path; the
    // inline writes are cheap (project.json is small + atomic rename).
    // Future patch can debounce if profiling shows it matters.
    let bus_for_vol = bus.clone();
    let rt_for_vol = rt.clone();
    window.on_scan_volume_changed(move |value: f32| {
        let bus = bus_for_vol.clone();
        let v = value as f64;
        rt_for_vol.spawn(async move {
            bus.send(UI_COMMAND_ID.into(), Command::SetScanVolume { value: v })
                .await;
        });
    });

    // Skip ±3s / ±10s buttons + Left/Right keyboard. UI reads the
    // current position-seconds and dispatches Seek with accurate=true
    // so the user lands exactly delta seconds away (within decoder
    // tolerance — ~50ms on modern HW).
    let bus_for_skip = bus.clone();
    let rt_for_skip = rt.clone();
    let weak_for_skip = window.as_weak();
    window.on_skip_clicked(move |delta_seconds: i32| {
        let bus = bus_for_skip.clone();
        let current = weak_for_skip
            .upgrade()
            .map(|w| w.get_position_seconds())
            .unwrap_or(0.0) as f64;
        let target = (current + delta_seconds as f64).max(0.0);
        rt_for_skip.spawn(async move {
            bus.send(
                UI_COMMAND_ID.into(),
                Command::Seek {
                    seconds: target,
                    accurate: true,
                },
            )
            .await;
        });
    });

    // Scrub during drag: keyframe-snap seek for snappy preview.
    let bus_for_drag = bus.clone();
    let rt_for_drag = rt.clone();
    window.on_scrub_dragged(move |seconds: f32| {
        let bus = bus_for_drag.clone();
        let s = seconds as f64;
        rt_for_drag.spawn(async move {
            bus.send(
                UI_COMMAND_ID.into(),
                Command::Seek {
                    seconds: s,
                    accurate: false,
                },
            )
            .await;
        });
    });

    // Scrub on release: frame-exact seek so the user lands where they
    // pointed.
    let bus_for_release = bus.clone();
    let rt_for_release = rt.clone();
    window.on_scrub_released(move |seconds: f32| {
        let bus = bus_for_release.clone();
        let s = seconds as f64;
        rt_for_release.spawn(async move {
            bus.send(
                UI_COMMAND_ID.into(),
                Command::Seek {
                    seconds: s,
                    accurate: true,
                },
            )
            .await;
        });
    });

    // Phase 8 Task 3. R-press toggles clip recording. Read the current
    // mode property + the live playhead BEFORE dispatching (adversarial
    // fix #1: the bus uses the snapshotted seconds directly as
    // start_source_seconds rather than re-reading after async
    // player.pause() — which can take 10–200 ms during which the
    // source has moved on).
    let bus_for_record = bus.clone();
    let rt_for_record = rt.clone();
    let weak_for_record = window.as_weak();
    let player_state_for_record = player_state.clone();
    window.on_record_toggled(move || {
        let bus = bus_for_record.clone();
        let mode = weak_for_record
            .upgrade()
            .map(|w| w.get_mode().to_string())
            .unwrap_or_default();
        match mode.as_str() {
            "scanning" => {
                // Snapshot the playhead while we hold the slot lock,
                // before crossing the await boundary. position_seconds
                // is f64; the bus accepts the same type.
                let playhead = {
                    let g = player_state_for_record
                        .lock()
                        .expect("player_state poisoned");
                    g.position_seconds
                };
                rt_for_record.spawn(async move {
                    bus.send(
                        UI_COMMAND_ID.into(),
                        Command::StartClipRecording {
                            playhead_snapshot_seconds: playhead,
                        },
                    )
                    .await;
                });
            }
            "recording" => {
                rt_for_record.spawn(async move {
                    bus.send(UI_COMMAND_ID.into(), Command::StopClipRecording)
                        .await;
                });
            }
            // "recording_starting" — mid-transition, ignore.
            _ => {}
        }
    });

    // Phase 8 Task 4. Stroke release → AppendStroke. The Slint TouchArea
    // overlay collects points + builds the JSON in-place; we just
    // forward the encoded array. Bus parses + appends to
    // recording_clip.events. Errors come back on the reply but we don't
    // surface them to the user UI — out-of-rect strokes are silently
    // dropped by the bus (they're a UI dispatch artifact, not a user
    // error).
    let bus_for_stroke = bus.clone();
    let rt_for_stroke = rt.clone();
    window.on_stroke_completed(move |points_json: slint::SharedString| {
        let bus = bus_for_stroke.clone();
        let json = points_json.to_string();
        rt_for_stroke.spawn(async move {
            bus.send(
                UI_COMMAND_ID.into(),
                Command::AppendStroke { points_json: json },
            )
            .await;
        });
    });

    // Phase 9 Task 4. Clip sidebar → OpenClipPreview. The Slint side
    // emits `clip-clicked(string)` carrying the stringified UUID; we
    // forward it as-is. The bus parses + validates. We also stamp
    // `selected-clip-id` locally so the sidebar highlights the active
    // row immediately rather than waiting for the bus's mode flip to
    // round-trip; if the open fails the bus's error path leaves mode
    // = Scanning and the timer above clears the selection on the next
    // tick.
    let bus_for_clip = bus.clone();
    let rt_for_clip = rt.clone();
    let weak_for_clip = window.as_weak();
    window.on_clip_clicked(move |clip_id: slint::SharedString| {
        let bus = bus_for_clip.clone();
        let id_string = clip_id.to_string();
        // Stamp selected-clip-id immediately for UI highlight feedback.
        if let Some(w) = weak_for_clip.upgrade() {
            w.set_selected_clip_id(clip_id.clone());
        }
        rt_for_clip.spawn(async move {
            bus.send(
                UI_COMMAND_ID.into(),
                Command::OpenClipPreview { clip_id: id_string },
            )
            .await;
        });
    });

    // Phase 9 Task 4. "← Source" button OR Esc key in preview mode →
    // ClosePreview. The bus tears down the preview pipeline and
    // returns mode to Scanning; the 30 Hz timer picks up the mode
    // change on its next tick and clears selected-clip-id.
    let bus_for_close = bus.clone();
    let rt_for_close = rt.clone();
    window.on_close_preview_clicked(move || {
        let bus = bus_for_close.clone();
        rt_for_close.spawn(async move {
            bus.send(UI_COMMAND_ID.into(), Command::ClosePreview).await;
        });
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

    // File → New Project: pop a folder picker. The picked folder will
    // host the new project; ProjectStore::write creates the
    // recordings/ subdir + project.json, then the bus auto-opens it
    // (same project.opened event the open path uses, so the title
    // updates by the same code below).
    let bus_for_new = bus.clone();
    let rt_for_new = rt.clone();
    let weak_for_new = window.as_weak();
    window.on_new_project_clicked(move || {
        let bus = bus_for_new.clone();
        let weak = weak_for_new.clone();
        rt_for_new.spawn(async move {
            let chosen = rfd::AsyncFileDialog::new()
                .set_title("Choose a folder for the new project")
                .pick_folder()
                .await;
            let Some(folder) = chosen else {
                return;
            };
            let path = folder.path().to_string_lossy().into_owned();
            let path_for_title = path.clone();
            let reply = bus
                .send(
                    UI_COMMAND_ID.into(),
                    Command::NewProject { path: path.clone() },
                )
                .await;
            if reply.ok {
                last_project::save(&path);
                slint::invoke_from_event_loop(move || {
                    if let Some(w) = weak.upgrade() {
                        w.set_project_title(path_for_title.into());
                        w.set_error_message("".into());
                    }
                })
                .ok();
            } else {
                let err_text = reply
                    .error
                    .clone()
                    .unwrap_or_else(|| "new_project failed (no error detail)".into());
                tracing::warn!(
                    target: "ui",
                    error = ?reply.error,
                    path = %path,
                    "new_project failed",
                );
                let display = format!("Couldn't create project at {path}\n{err_text}");
                slint::invoke_from_event_loop(move || {
                    if let Some(w) = weak.upgrade() {
                        w.set_error_message(display.into());
                    }
                })
                .ok();
            }
        });
    });

    // File → Add Source Video: pop a file picker (filtered to video
    // formats), dispatch AddSourceVideo. The bus auto-spawns the
    // SourcePlayer if this is the first source, so play/pause/seek
    // become available immediately.
    let bus_for_add = bus.clone();
    let rt_for_add = rt.clone();
    let weak_for_add = window.as_weak();
    window.on_add_source_video_clicked(move || {
        let bus = bus_for_add.clone();
        let weak = weak_for_add.clone();
        rt_for_add.spawn(async move {
            let chosen = rfd::AsyncFileDialog::new()
                .set_title("Add a source video to this project")
                .add_filter("Video", &["mp4", "mov", "m4v", "mkv"])
                .pick_file()
                .await;
            let Some(file) = chosen else {
                return;
            };
            let path = file.path().to_string_lossy().into_owned();
            let reply = bus
                .send(
                    UI_COMMAND_ID.into(),
                    Command::AddSourceVideo {
                        absolute_path: path.clone(),
                    },
                )
                .await;
            if !reply.ok {
                let err_text = reply
                    .error
                    .clone()
                    .unwrap_or_else(|| "add_source_video failed (no error detail)".into());
                tracing::warn!(
                    target: "ui",
                    error = ?reply.error,
                    path = %path,
                    "add_source_video failed",
                );
                let display = format!("Couldn't add {path}\n{err_text}");
                slint::invoke_from_event_loop(move || {
                    if let Some(w) = weak.upgrade() {
                        w.set_error_message(display.into());
                    }
                })
                .ok();
            } else {
                slint::invoke_from_event_loop(move || {
                    if let Some(w) = weak.upgrade() {
                        w.set_error_message("".into());
                    }
                })
                .ok();
            }
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
            let Some(folder) = chosen else {
                return;
            };
            let path = folder.path().to_string_lossy().into_owned();
            let path_for_title = path.clone();
            let reply = bus
                .send(
                    UI_COMMAND_ID.into(),
                    Command::OpenProject { path: path.clone() },
                )
                .await;
            if reply.ok {
                last_project::save(&path);
                slint::invoke_from_event_loop(move || {
                    if let Some(w) = weak.upgrade() {
                        w.set_project_title(path_for_title.into());
                        w.set_error_message("".into());
                    }
                })
                .ok();
            } else {
                let err_text = reply
                    .error
                    .clone()
                    .unwrap_or_else(|| "open_project failed (no error detail)".into());
                tracing::warn!(
                    target: "ui",
                    error = ?reply.error,
                    path = %path,
                    "open_project failed",
                );
                let display = format!("Couldn't open {path}\n{err_text}");
                slint::invoke_from_event_loop(move || {
                    if let Some(w) = weak.upgrade() {
                        w.set_error_message(display.into());
                    }
                })
                .ok();
            }
        });
    });

    // Auto-reopen the project that was active when we last quit. Failure
    // here is non-fatal — we surface the error in the UI's error label
    // and leave the window in the no-project-open state. We don't
    // re-save the path on success: it's already persisted; saving here
    // would be a no-op write but also masks the case where startup
    // open succeeds against a path the user later moves (we'd happily
    // re-save the now-stale path).
    if let Some(path) = startup_project {
        let bus_for_init = bus.clone();
        let weak = window.as_weak();
        rt.spawn(async move {
            let path_for_title = path.clone();
            let reply = bus_for_init
                .send(
                    UI_COMMAND_ID.into(),
                    Command::OpenProject { path: path.clone() },
                )
                .await;
            if reply.ok {
                slint::invoke_from_event_loop(move || {
                    if let Some(w) = weak.upgrade() {
                        w.set_project_title(path_for_title.into());
                        w.set_error_message("".into());
                    }
                })
                .ok();
            } else {
                let err_text = reply
                    .error
                    .clone()
                    .unwrap_or_else(|| "open_project failed (no error detail)".into());
                tracing::warn!(
                    target: "app.lifecycle",
                    path = %path,
                    error = ?reply.error,
                    "auto-reopen of last project failed",
                );
                let display = format!("Couldn't reopen {path}\n{err_text}");
                slint::invoke_from_event_loop(move || {
                    if let Some(w) = weak.upgrade() {
                        w.set_error_message(display.into());
                    }
                })
                .ok();
            }
        });
    }

    window.run().map_err(Into::into)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Phase 6 Task 6 — proves the Slint component build pipeline + the
    /// headless testing backend are wired up.
    ///
    /// Honest scope (per the adversarial review): this test does NOT cover
    /// native MenuBar interaction. Slint's testing backend cannot drive
    /// macOS `NSMenu` items. The only real test of the menu→bus path is
    /// the manual smoke checklist in Task 8 plus the existing harness E2E
    /// coverage of the underlying OpenProject / Quit bus commands.
    ///
    /// What this DOES prove: `slint::include_modules!()` produced a usable
    /// `MainWindow` type, the `project-title` `in property <string>`
    /// round-trips through the generated getter/setter, and
    /// `i_slint_backend_testing` initializes a backend without a display.
    /// Future phases can extend this scaffold.
    #[test]
    fn main_window_project_title_property_round_trips() {
        // init_no_event_loop is idempotent across multiple #[test]s in the
        // same binary (cargo test runs them serially in the same process by
        // default); subsequent calls are cheap no-ops.
        i_slint_backend_testing::init_no_event_loop();
        let window = MainWindow::new().expect("MainWindow::new must succeed under testing backend");
        assert_eq!(
            window.get_project_title().as_str(),
            "No project open",
            "default project-title should match the .slint default",
        );
        window.set_project_title("Phase 6 Smoke".into());
        assert_eq!(window.get_project_title().as_str(), "Phase 6 Smoke");
    }
}
