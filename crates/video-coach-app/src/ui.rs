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

use crate::bus::{BusHandle, Command, TagSelection};
use crate::frame_sink::{
    ClipListSlot, ExportProgressSlot, ExportRunOutcome, FrameSlot, PlayerStateSlot,
    RecordingStateSlot,
};
use crate::last_project;
use slint::{ComponentHandle, Model};
use std::path::PathBuf;

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

/// Phase 10 Task 3: synthetic tag-value used for the "All Clips" row.
/// The dispatch handler maps this back to `TagSelection::AllClips`;
/// real tag names land as `TagSelection::Tag { name }`. Picked so it
/// never collides with a user-defined tag (real tags are
/// alphanumeric + `-` per the tag-rename UX in v1; double-underscore
/// is reserved).
const ALL_CLIPS_TAG: &str = "__all__";

/// Aggregate the clip list's tags into the export-sheet rows.
///
/// Pre-condition: `clips` is `(recording_duration, tags)` per clip,
/// in arbitrary order. Post-condition: the returned vector is the
/// row model for the Slint sheet:
/// - First entry: synthetic `(__all__, "All Clips", count, total_dur, selected)`
///   with count = clips.len() and dur = sum-of-all clip durations.
/// - Following entries: one per unique tag, sorted alphabetically by
///   tag name; selected = the tag is in `selected_set`.
///
/// The `selected_set` is the UI's current `selected-export-tags`
/// property. Empty selections are normal — the form view's Export
/// button is disabled until at least one row is ticked.
fn aggregate_tag_rows(
    clips: &[(f64, Vec<String>)],
    selected_set: &std::collections::HashSet<String>,
) -> Vec<(String, String, i32, f32, bool)> {
    use std::collections::BTreeMap;
    let total_count = clips.len() as i32;
    let total_dur: f64 = clips.iter().map(|(d, _)| *d).sum();
    let mut by_tag: BTreeMap<String, (i32, f64)> = BTreeMap::new();
    for (dur, tags) in clips {
        for t in tags {
            let e = by_tag.entry(t.clone()).or_insert((0, 0.0));
            e.0 += 1;
            e.1 += *dur;
        }
    }
    let mut rows: Vec<(String, String, i32, f32, bool)> = Vec::with_capacity(by_tag.len() + 1);
    rows.push((
        ALL_CLIPS_TAG.to_string(),
        "All Clips".to_string(),
        total_count,
        total_dur as f32,
        selected_set.contains(ALL_CLIPS_TAG),
    ));
    for (tag, (count, dur)) in by_tag {
        let selected = selected_set.contains(&tag);
        rows.push((tag.clone(), tag, count, dur as f32, selected));
    }
    rows
}

/// Phase 10 Task 3 (per fix #35). Reveal a folder in the platform's
/// native file manager. Best-effort: on spawn error we log a warning
/// and return — the export sheet still shows the folder path so the
/// user can copy it manually.
///
/// Uses plain `open <folder>` on macOS (NOT `open -R`, which reveals
/// a single file's parent rather than opening the folder itself);
/// `explorer <folder>` on Windows; `xdg-open <folder>` on Linux.
fn reveal_folder(folder: &std::path::Path) {
    #[cfg(target_os = "macos")]
    let cmd = "open";
    #[cfg(target_os = "windows")]
    let cmd = "explorer";
    #[cfg(all(not(target_os = "macos"), not(target_os = "windows")))]
    let cmd = "xdg-open";
    match std::process::Command::new(cmd).arg(folder).spawn() {
        Ok(_) => {
            tracing::info!(
                target: "ui",
                event = "export.reveal",
                folder = %folder.display(),
            );
        }
        Err(e) => {
            tracing::warn!(
                target: "ui",
                event = "export.reveal_failed",
                folder = %folder.display(),
                error = %e,
            );
        }
    }
}

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
    let export_progress_for_timer = export_progress.clone();
    // Phase 9 Task 4: cache last-seen clip-list signature so we only
    // rebuild the Slint model when something actually changed.
    // (id, name, duration) tuples — same shape we hand to Slint.
    let mut cached_clips: Vec<(uuid::Uuid, String, f64)> = Vec::new();
    // Phase 10 Task 3 caches: prevent gratuitous Slint property
    // writes when nothing has changed.
    //
    // export-tag-rows is rebuilt from the live clip list whenever
    // (a) the clip list itself changes OR (b) the user's selection
    // changes. We snapshot the aggregated tag list (sorted, with the
    // synthetic all-clips row) and the selection state, and rewrite
    // the Slint model only when either signature shifts.
    let mut cached_tag_rows: Vec<(String, String, i32, f32, bool)> = Vec::new();
    // Outcome-kind transitions trigger summary-field updates. Track
    // the last serialized outcome string so we know when to rewrite.
    let mut cached_outcome_kind: String = "none".into();
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
            // Phase 10 Task 3 also collects each clip's tags so the
            // export-sheet's tag aggregation runs without a separate
            // bus round-trip.
            let clip_snapshot: Vec<(uuid::Uuid, String, f64)> = {
                let g = clip_list_for_timer.lock().expect("clip_list poisoned");
                g.iter()
                    .map(|c| (c.id, c.name.clone(), c.recording_duration))
                    .collect()
            };
            let clip_tag_snapshot: Vec<(f64, Vec<String>)> = {
                let g = clip_list_for_timer.lock().expect("clip_list poisoned");
                g.iter()
                    .map(|c| (c.recording_duration, c.tags.clone()))
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
            // Phase 10 Task 3: snapshot ExportProgressSlot. Map the
            // outcome enum to the Slint string view selector and
            // pull the per-state fields. Lock duration is short —
            // we clone() the small enum + a few scalar fields.
            let (
                outcome_kind,
                export_active,
                total_tags,
                completed_tags,
                current_tag,
                summary_folder,
                summary_file_count,
                error_text,
                failed_tag,
                cancelled_completed,
                current_tag_progress,
                batch_progress,
            ) = {
                let g = export_progress_for_timer
                    .lock()
                    .expect("export_progress poisoned");
                // Phase 11 Plan #2 (Fix #8): per-arm
                // (current_tag_progress, batch_progress) defaults
                // spelled out for all 5 ExportRunOutcome arms.
                match &g.outcome {
                    ExportRunOutcome::None => (
                        "none",
                        false,
                        0_i32,
                        0_i32,
                        String::new(),
                        String::new(),
                        0_i32,
                        String::new(),
                        String::new(),
                        0_i32,
                        0.0_f32,
                        0.0_f32,
                    ),
                    ExportRunOutcome::InProgress => (
                        "in_progress",
                        true,
                        g.total_tags as i32,
                        g.completed_tags as i32,
                        g.current_tag.clone().unwrap_or_default(),
                        String::new(),
                        0,
                        String::new(),
                        String::new(),
                        0,
                        g.current_tag_progress,
                        g.batch_progress,
                    ),
                    ExportRunOutcome::SucceededAll { folder, tag_count } => (
                        "succeeded_all",
                        false,
                        g.total_tags as i32,
                        g.completed_tags as i32,
                        String::new(),
                        folder.to_string_lossy().into_owned(),
                        *tag_count as i32,
                        String::new(),
                        String::new(),
                        0,
                        1.0_f32,
                        1.0_f32,
                    ),
                    ExportRunOutcome::PartialFailure {
                        folder,
                        completed,
                        failed_tag,
                        error,
                    } => (
                        "partial_failure",
                        false,
                        g.total_tags as i32,
                        *completed as i32,
                        String::new(),
                        folder.to_string_lossy().into_owned(),
                        0,
                        error.clone(),
                        failed_tag.clone(),
                        0,
                        g.current_tag_progress,
                        g.batch_progress,
                    ),
                    ExportRunOutcome::Cancelled { folder, completed } => (
                        "cancelled",
                        false,
                        g.total_tags as i32,
                        *completed as i32,
                        String::new(),
                        folder.to_string_lossy().into_owned(),
                        0,
                        String::new(),
                        String::new(),
                        *completed as i32,
                        g.current_tag_progress,
                        g.batch_progress,
                    ),
                }
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

                // Phase 10 Task 3: project-open is true whenever we
                // have a non-empty title (the bus's open-project /
                // new-project handlers stamp the path; "No project
                // open" is the sentinel default from main.slint).
                let title = w.get_project_title();
                let project_is_open = title.as_str() != "No project open" && !title.is_empty();
                w.set_project_open(project_is_open);
                // Seed export-project-name once on first project
                // open so the form view can show it. We don't
                // re-seed on every tick because the user might
                // edit it later (Phase 10 ships a read-only
                // display, but the property is in-out for future
                // editing).
                if project_is_open && w.get_export_project_name().is_empty() {
                    // Project name == folder basename per the bus's
                    // NewProject handler; pick the trailing path
                    // component off the project-title path.
                    let basename = std::path::Path::new(title.as_str())
                        .file_name()
                        .and_then(|s| s.to_str())
                        .unwrap_or(title.as_str())
                        .to_string();
                    w.set_export_project_name(basename.into());
                }

                // Phase 10 Task 3: rebuild export-tag-rows when the
                // clip list OR the user's selection has changed.
                // The synthetic all-clips row is pinned first.
                let selected_set: std::collections::HashSet<String> = w
                    .get_selected_export_tags()
                    .iter()
                    .map(|s| s.to_string())
                    .collect();
                let aggregated = aggregate_tag_rows(&clip_tag_snapshot, &selected_set);
                if aggregated != cached_tag_rows {
                    // Slint compiles anonymous-struct list properties
                    // to tuples with fields in alphabetical order;
                    // the property type is
                    //   [{tag, label, clip-count, duration, selected}]
                    // → (clip-count, duration, label, selected, tag).
                    let model: Vec<(i32, f32, slint::SharedString, bool, slint::SharedString)> =
                        aggregated
                            .iter()
                            .map(|(tag, label, count, dur, sel)| {
                                (
                                    *count,
                                    *dur,
                                    slint::SharedString::from(label.as_str()),
                                    *sel,
                                    slint::SharedString::from(tag.as_str()),
                                )
                            })
                            .collect();
                    w.set_export_tag_rows(slint::ModelRc::new(slint::VecModel::from(model)));
                    cached_tag_rows = aggregated;
                }

                // Phase 10 Task 3: hydrate outcome-derived
                // properties. We always write `export-active` /
                // total/completed counts (cheap scalars) and only
                // write the summary fields when the outcome string
                // changes — Slint property writes are idempotent
                // but each one allocates a SharedString.
                w.set_export_active(export_active);
                w.set_export_total_tags(total_tags);
                w.set_export_completed_tags(completed_tags);
                w.set_export_current_tag(current_tag.into());
                if outcome_kind != cached_outcome_kind {
                    w.set_export_outcome_kind(outcome_kind.into());
                    cached_outcome_kind = outcome_kind.to_string();
                }
                w.set_export_summary_folder(summary_folder.into());
                w.set_export_summary_file_count(summary_file_count);
                w.set_export_error(error_text.into());
                w.set_export_failed_tag(failed_tag.into());
                w.set_export_cancelled_completed(cancelled_completed);
                // Phase 11 Plan #2: hydrate the real-progress fields.
                w.set_export_current_tag_progress(current_tag_progress);
                w.set_export_batch_progress(batch_progress);
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

    // ─────────────────────────── Phase 10 Task 3 ───────────────────────────
    // Export-sheet callbacks. The sheet's outcome state lives on
    // ExportProgressSlot (bus-side writer, UI 30 Hz timer reader,
    // wired above). The handlers below are pure dispatch; they read
    // Slint properties that the user has touched, build the bus
    // command, and forward.
    //
    // Note: rfd's pick_folder MUST run on a tokio runtime when used
    // with the "tokio" feature, which is how the existing
    // open-project / new-project handlers wire it. We follow that
    // pattern — spawn an async task and await the dialog there.

    // Tag toggle. The Slint tag string is `__all__` for the synthetic
    // row, otherwise a real tag name. We mutate the in-out
    // selected-export-tags property; the 30 Hz timer's tag-row
    // rebuild picks up the new selection on its next tick.
    let weak_for_tag = window.as_weak();
    window.on_export_tag_toggled(move |tag: slint::SharedString| {
        let Some(w) = weak_for_tag.upgrade() else {
            return;
        };
        let current = w.get_selected_export_tags();
        let s = tag.to_string();
        let mut next: Vec<slint::SharedString> = current.iter().collect();
        if let Some(pos) = next.iter().position(|x| x.as_str() == s) {
            next.remove(pos);
        } else {
            next.push(slint::SharedString::from(s.as_str()));
        }
        w.set_selected_export_tags(slint::ModelRc::new(slint::VecModel::from(next)));
    });

    let weak_for_sa = window.as_weak();
    window.on_export_select_all_clicked(move || {
        let Some(w) = weak_for_sa.upgrade() else {
            return;
        };
        let rows = w.get_export_tag_rows();
        // Slint anon-struct field tuple order is alphabetized;
        // tag is the 5th (index 4) field.
        let all: Vec<slint::SharedString> = rows.iter().map(|row| row.4.clone()).collect();
        w.set_selected_export_tags(slint::ModelRc::new(slint::VecModel::from(all)));
    });

    let weak_for_sn = window.as_weak();
    window.on_export_select_none_clicked(move || {
        let Some(w) = weak_for_sn.upgrade() else {
            return;
        };
        w.set_selected_export_tags(slint::ModelRc::new(slint::VecModel::from(Vec::<
            slint::SharedString,
        >::new())));
    });

    // Resolution / quality pickers — straight property writes.
    let weak_for_res = window.as_weak();
    window.on_export_resolution_changed(move |s: slint::SharedString| {
        if let Some(w) = weak_for_res.upgrade() {
            w.set_export_resolution(s);
        }
    });
    let weak_for_qual = window.as_weak();
    window.on_export_quality_changed(move |s: slint::SharedString| {
        if let Some(w) = weak_for_qual.upgrade() {
            w.set_export_quality(s);
        }
    });

    // Folder picker. Same async-rfd pattern as new/open-project.
    // Path written back to the in-out export-output-folder property
    // via invoke_from_event_loop because rfd::AsyncFileDialog
    // resolves on a worker thread.
    let rt_for_pick = rt.clone();
    let weak_for_pick = window.as_weak();
    window.on_export_folder_pick_clicked(move || {
        let weak = weak_for_pick.clone();
        rt_for_pick.spawn(async move {
            let chosen = rfd::AsyncFileDialog::new()
                .set_title("Choose an export output folder")
                .pick_folder()
                .await;
            let Some(folder) = chosen else {
                return;
            };
            let path = folder.path().to_string_lossy().into_owned();
            slint::invoke_from_event_loop(move || {
                if let Some(w) = weak.upgrade() {
                    w.set_export_output_folder(path.into());
                }
            })
            .ok();
        });
    });

    // Start. Read the form fields, build TagSelection vec +
    // Resolution / Quality enums, dispatch ExportCompilations.
    let bus_for_start = bus.clone();
    let rt_for_start = rt.clone();
    let weak_for_start = window.as_weak();
    window.on_export_start_clicked(move || {
        let bus = bus_for_start.clone();
        let Some(w) = weak_for_start.upgrade() else {
            return;
        };
        let selections: Vec<TagSelection> = w
            .get_selected_export_tags()
            .iter()
            .map(|s| {
                if s.as_str() == ALL_CLIPS_TAG {
                    TagSelection::AllClips
                } else {
                    TagSelection::Tag {
                        name: s.to_string(),
                    }
                }
            })
            .collect();
        let output_folder = w.get_export_output_folder().to_string();
        let resolution = match w.get_export_resolution().as_str() {
            "source" => video_coach_core::project::Resolution::Source,
            "720" => video_coach_core::project::Resolution::R720,
            // Default (incl. "1080" sentinel and any unknown future
            // value) rounds to 1080p — same as project Preferences
            // default.
            _ => video_coach_core::project::Resolution::R1080,
        };
        let quality = match w.get_export_quality().as_str() {
            "low" => video_coach_core::project::Quality::Low,
            "high" => video_coach_core::project::Quality::High,
            _ => video_coach_core::project::Quality::Medium,
        };
        let project_name = w.get_export_project_name().to_string();
        rt_for_start.spawn(async move {
            bus.send(
                UI_COMMAND_ID.into(),
                Command::ExportCompilations {
                    selections,
                    output_folder,
                    resolution,
                    quality,
                    project_name,
                },
            )
            .await;
        });
    });

    // Cancel an in-flight export. We DO NOT close the sheet here;
    // the bus's CancelExport handler flips the AtomicBool, the
    // export driver tears down + writes the Cancelled outcome to
    // the slot, the 30 Hz timer's next tick swaps the sheet to the
    // cancelled view, and the user clicks Done.
    let bus_for_cancel = bus.clone();
    let rt_for_cancel = rt.clone();
    window.on_export_cancel_clicked(move || {
        let bus = bus_for_cancel.clone();
        rt_for_cancel.spawn(async move {
            bus.send(UI_COMMAND_ID.into(), Command::CancelExport).await;
        });
    });

    // Close the sheet. From any non-InProgress outcome state. Reset
    // the slot's outcome back to None so the next sheet open starts
    // in the form state.
    let weak_for_close = window.as_weak();
    let export_progress_for_close = export_progress.clone();
    window.on_export_close_clicked(move || {
        if let Some(w) = weak_for_close.upgrade() {
            w.set_export_sheet_visible(false);
        }
        // Reset the slot if the run is in a terminal state. We
        // never reset while InProgress — that would race the bus
        // task (the click-outside / Esc path is gated on
        // outcome != "in_progress" in the .slint, but the Done
        // button on a terminal-state view still triggers this
        // close handler, which is fine).
        let mut g = export_progress_for_close
            .lock()
            .expect("export_progress poisoned");
        if !matches!(g.outcome, ExportRunOutcome::InProgress) {
            *g = crate::frame_sink::ExportProgressSlotData::default();
        }
    });

    // Reveal in Finder. Cross-platform per fix #35: macOS `open`,
    // Windows `explorer`, Linux `xdg-open`. The folder path comes
    // from the export-summary-folder Slint property (set by the
    // 30 Hz timer's outcome hydration). On spawn failure we just
    // log a warning — the path label is still visible in the sheet
    // for the user to copy.
    let weak_for_reveal = window.as_weak();
    window.on_export_reveal_clicked(move || {
        let Some(w) = weak_for_reveal.upgrade() else {
            return;
        };
        let folder = w.get_export_summary_folder().to_string();
        if folder.is_empty() {
            return;
        }
        let path = PathBuf::from(folder);
        reveal_folder(&path);
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

    /// Phase 10 Task 3. Aggregation contract for the export-sheet's tag
    /// rows: synthetic `__all__` row first, real tags sorted, counts +
    /// total durations match, and the `selected` flag mirrors the
    /// caller's selection set.
    #[test]
    fn aggregate_tag_rows_pins_all_clips_first_and_sorts_real_tags() {
        let clips = vec![
            (3.0, vec!["zebra".into(), "wing".into()]),
            (4.5, vec!["alpha".into()]),
            (1.5, vec!["alpha".into(), "wing".into()]),
        ];
        let mut sel = std::collections::HashSet::new();
        sel.insert("alpha".to_string());
        sel.insert(super::ALL_CLIPS_TAG.to_string());
        let rows = super::aggregate_tag_rows(&clips, &sel);
        // 1 synthetic + 3 unique tags
        assert_eq!(rows.len(), 4);
        // synthetic comes first
        assert_eq!(rows[0].0, super::ALL_CLIPS_TAG);
        assert_eq!(rows[0].1, "All Clips");
        assert_eq!(rows[0].2, 3); // 3 clips
        assert!((rows[0].3 - 9.0).abs() < 1e-3); // total duration
        assert!(rows[0].4); // selected
                            // real tags alphabetized
        assert_eq!(rows[1].0, "alpha");
        assert_eq!(rows[1].2, 2);
        assert!((rows[1].3 - 6.0).abs() < 1e-3);
        assert!(rows[1].4); // selected
        assert_eq!(rows[2].0, "wing");
        assert_eq!(rows[2].2, 2);
        assert!(!rows[2].4); // not selected
        assert_eq!(rows[3].0, "zebra");
        assert!(!rows[3].4);
    }

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
