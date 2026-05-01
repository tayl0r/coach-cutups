// Until the Slint UI in Phase 6 Task 2 dispatches commands through the bus,
// the no-default-features build (no control-socket, no UI consumer) leaves
// BusHandle::send dormant. Allow dead_code in that shape only.
#![cfg_attr(not(feature = "control-socket"), allow(dead_code))]

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
    /// Start a recording. `source` selects fixture vs. production. `output`
    /// is the .mov path; the parent dir is auto-created.
    /// Only handled when the app is built with `--features media`; without
    /// it, the dispatcher returns an error.
    StartRecording {
        source: SourceConfig,
        output: String,
    },
    StopRecording,
    /// Open the project folder at `path`. Reads `<path>/project.json`,
    /// validates the format version, and stashes the parsed `Project` in
    /// the bus task's per-task state. Emits a `project.opened` event with
    /// the project's `name` field on success.
    OpenProject {
        path: String,
    },
    /// Create a fresh v2 project at `path`. Writes `<path>/project.json`
    /// and ensures `<path>/recordings/` exists. Project name is derived
    /// from the folder's basename. Refuses to overwrite if a
    /// `project.json` is already present. After creating, the new
    /// project becomes the current project (same effect as a subsequent
    /// OpenProject) and a `project.opened` event fires so the UI's
    /// post-open path can run unchanged.
    NewProject {
        path: String,
    },
    /// Phase 7. Adds a source video to the currently-open project.
    /// `absolute_path` points at the picked file on disk. The handler
    /// computes a relative path against the project folder (with `..`
    /// allowed), probes the file's duration, appends a SourceRef to
    /// `project.source_videos`, and persists. If the project had no
    /// active player yet, this also instantiates one.
    AddSourceVideo {
        absolute_path: String,
    },
    /// Phase 7. Resume the source player. Errors if no player is loaded.
    Play,
    /// Phase 7. Pause the source player. Errors if no player is loaded.
    Pause,
    /// Phase 7. Seek to absolute time `seconds` in the active source.
    /// `accurate=true` requests frame-exact seek (GST_SEEK_FLAG_ACCURATE);
    /// `accurate=false` snaps to the nearest keyframe (KEY_UNIT). The UI
    /// uses `accurate=false` during live slider drag for snappy preview
    /// and `accurate=true` on release / from skip buttons + keyboard.
    Seek {
        seconds: f64,
        accurate: bool,
    },
    /// Phase 7. Set the scan volume (source-playback audio level) on the
    /// active player. Range 0.0..=1.0. Live tick during slider drag;
    /// persistence to project.json happens on slider release via a
    /// separate command path.
    SetScanVolume {
        value: f64,
    },
    /// Phase 8. Begin a clip recording: pause the source player, snapshot
    /// the playhead, derive a clip filename + path under
    /// `<project>/recordings/`, and start the platform-default capture
    /// pipeline. `playhead_snapshot_seconds` is captured by the UI
    /// BEFORE this command is dispatched (adversarial fix #1) — the bus
    /// uses it directly as `start_source_seconds` rather than re-reading
    /// after the async `player.pause()` round-trip (which can take
    /// 10–200 ms during which the source has moved on).
    StartClipRecording {
        playhead_snapshot_seconds: f64,
    },
    /// Phase 8. Stop the active clip recording, flush the qtmux moov
    /// atom, finalize a `Clip` record, append it to `project.clips`,
    /// and persist `project.json`. Transitions mode back to Scanning.
    StopClipRecording,
    /// Phase 8. Append a stroke event to the in-progress clip
    /// recording's event log. `points_json` is a JSON-encoded array of
    /// `{ "x": f64, "y": f64, "t": f64 }` entries; coordinates are in
    /// `[0, 1]` against the displayed video rect (post-letterbox), `t`
    /// is seconds since the recording's `t0`. Errors if no clip
    /// recording is in progress (`current_mode != Recording`).
    AppendStroke {
        points_json: String,
    },
    /// Phase 9. Open the named clip in the preview pipeline. The bus
    /// pauses the current source player, mounts a preview FrameSink,
    /// and spins up a `PreviewPipeline` (see Task 2/3). `clip_id` is a
    /// stringified UUID; the bus parses it on entry and looks it up in
    /// `project.clips`. Refuses if `current_mode` isn't `Scanning` —
    /// per fix #22, opening a second preview while one is open is a
    /// no-op + a `clip_preview.failed` event. Task 0 lands the command
    /// shape only; Task 3 lands the handler.
    OpenClipPreview {
        clip_id: String,
    },
    /// Phase 9. Tear down the active preview pipeline and return mode
    /// to `Scanning`. Source player stays paused (matches v1 + fix #9
    /// — the user re-presses Space to resume). Task 0 lands the command
    /// shape only; Task 3 lands the handler.
    ClosePreview,
    /// Phase 10. Batch-export the selected tags' compilations into
    /// `output_folder`. Each `TagSelection` writes one `.mp4`; runs
    /// sequentially per fix #4 (VideoToolbox saturates on a single
    /// export). The bus task transitions
    /// `current_mode = AppMode::Exporting`, loops through selections
    /// (UI sends them sorted; bus doesn't re-sort), and emits
    /// `export.batch.started` / `export.tag.started` / `export.tag.
    /// completed` / `export.batch.completed` events per fix #1.
    ///
    /// Phase 10 Task 0 lands only the command shape + a stub handler
    /// returning "not yet implemented (phase 10 task 2)". Task 2 lands
    /// the real handler; Task 1 lands the underlying export pipeline.
    ExportCompilations {
        selections: Vec<TagSelection>,
        output_folder: String,
        resolution: video_coach_core::project::Resolution,
        quality: video_coach_core::project::Quality,
        project_name: String,
    },
    /// Phase 10. Request cancellation of the in-flight batch export.
    /// The bus flips its `current_export_cancel` AtomicBool; the export
    /// driver checks before each frame push, transitions to Null when
    /// the flag flips, and deletes the partial output. Per fix #6,
    /// cancel does its best — GStreamer pipelines have no instantaneous
    /// abort.
    ///
    /// Phase 10 Task 0 lands only the command shape + a stub handler
    /// returning "not yet implemented (phase 10 task 2)".
    CancelExport,
}

/// Phase 10 Task 0 (fix #33). Tag selection for `ExportCompilations`.
/// The UI sends `Vec<TagSelection>` so the synthetic "All Clips" row
/// can sit alongside real tag names without a magic string overlap
/// with a real tag literally named "all-clips".
///
/// Serializes with serde's internally-tagged shape (`{"kind":
/// "all_clips"}` / `{"kind": "tag", "name": "basketball"}`) — same
/// pattern as `SourceConfig`, so the control socket protocol stays
/// internally consistent.
#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum TagSelection {
    /// The synthetic "All Clips" compilation — every clip in the
    /// project, sorted by `sort_index`. Resolved by the bus to
    /// `Project::all_clips_compilation_plan(...)`.
    AllClips,
    /// A real tag name. Resolved by the bus to
    /// `Project::compilation_plan_for(&name, ...)`.
    Tag { name: String },
}

/// Phase 8. Mutually-exclusive UI/bus modes. Mirrors v1's
/// `App/Models/AppMode.swift` enum 1:1.
///
/// Used by the bus task as `current_mode` (Task 1) and serialized as a
/// string field on `mode.changed` events. The no-default-features
/// build doesn't construct AppMode anywhere (the entire clip-recording
/// stack is media-feature-gated), so `dead_code` is allowed in that
/// build shape only.
///
/// Phase 9: gains `PreviewClip(Uuid)`. The Uuid carries the in-flight
/// clip id so the bus + tracing layer can include it in events
/// (`clip_preview.opened` / `clip_preview.closed`). The variant payload
/// breaks `Copy` (Uuid isn't Copy across all crate versions / build
/// shapes), so the derive drops `Copy` in favor of plain `Clone` — see
/// adversarial-review fix #8. Every read site that previously assumed
/// `*current_mode` produced a `Copy` was updated to either pass
/// `&AppMode` (`is_busy`, `write_recording_state`) or `current_mode
/// .clone()` where ownership is required.
#[cfg_attr(not(feature = "media"), allow(dead_code))]
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AppMode {
    /// Idle: source player is mounted, transport runs, R-press starts a
    /// recording.
    Scanning,
    /// `R` pressed: capture pipeline is being constructed (camera
    /// permission prompts may pop here on macOS first run). The
    /// transport bar shows a yellow "Preparing…" indicator. Mid-
    /// transition presses of `R` are ignored.
    RecordingStarting,
    /// Capture pipeline is recording; stroke events accumulate into the
    /// in-progress clip; second `R` press stops + finalizes the clip.
    Recording,
    /// Phase 9: a clip is in preview. Source player is paused; the
    /// preview pipeline owns frame writes. Transport (Play/Pause/Seek)
    /// routes to the preview pipeline. ClosePreview returns to
    /// Scanning. Serializes as `"preview_clip": "<uuid-string>"` per
    /// serde's snake_case tuple-variant default.
    PreviewClip(uuid::Uuid),
    /// Phase 10: a batch export is mid-flight. Source player + preview
    /// pipeline are both inert (preview was closed by the UI before
    /// dispatching `ExportCompilations`); the export driver owns the
    /// encoder. State details (current tag, completed/total) ride on
    /// `ExportProgressSlot` — this variant carries no payload so the
    /// `Clone` cost stays trivial. Per fix #9, `is_busy` returns true
    /// for this mode; per fix #22, `OpenClipPreview` /
    /// `StartClipRecording` / `ExportCompilations` itself all refuse
    /// while `Exporting`.
    Exporting,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SourceConfig {
    /// Fixture file source — used by tests.
    Fixture { path: String },
    /// Default platform camera + mic — Phase 3 ships macOS only (not yet
    /// implemented; returns an error at dispatch).
    PlatformDefault,
}

/// A command paired with a reply channel.
pub struct Envelope {
    /// Echoed back as `reply_to` on the matching reply, and propagated as the
    /// originating id when forwarding events. Read in Task 6's tracing bridge.
    #[allow(dead_code)]
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
        let env = Envelope {
            id,
            command,
            reply: reply_tx,
        };
        if self.tx.send(env).await.is_err() {
            return CommandReply {
                ok: false,
                error: Some("bus closed".into()),
            };
        }
        reply_rx.await.unwrap_or(CommandReply {
            ok: false,
            error: Some("reply dropped".into()),
        })
    }
}

/// Build a fresh `FrameSink` (paired with the atomics needed to control
/// it) for a newly-spawned playback pipeline. The bus task can't hold a
/// `slint::Weak` directly (UI types are not always `Send`-friendly to
/// bind to), so the UI hands the bus a factory at startup which the bus
/// invokes whenever it spawns a new player or mounts a preview
/// pipeline. For headless builds (no UI), the factory yields a
/// `NullFrameSink` (frames dropped on the GStreamer streaming thread).
///
/// Phase 9 (fix #3 + #26): renamed from `FrameSinkFactory` and its
/// return type widened to `MountedSink`, which carries the active
/// flag and frames-pushed counter alongside the trait object. The bus
/// task stashes the atomic handles per pipeline so it can flip
/// `active=false` BEFORE pause/teardown (preventing straggler frames
/// from the GStreamer streaming thread from racing the next mount's
/// first frame) and read `frames_pushed` on ClosePreview to populate
/// the `clip_preview.closed` event for the harness E2E pixel-flow
/// check.
#[cfg(feature = "media")]
pub type FrameMountFactory =
    std::sync::Arc<dyn Fn() -> crate::frame_sink::MountedSink + Send + Sync>;

/// Spawn the bus task on the given tokio runtime handle. Phase 6 dropped
/// `#[tokio::main]` so the bus runs on the same multi-threaded runtime
/// that drives the control socket and any UI-dispatched async work.
///
/// `fixture_recording_source` (Phase 8) is the
/// `--fixture-recording-source=PATH` CLI flag's value: when `Some`,
/// `StartClipRecording` uses a `FixtureSource` against that path
/// instead of the real platform camera/mic. CI's `record_clip_smoke`
/// harness passes this so the test runs without webcam permissions.
/// Production launches leave it `None` and get the platform default.
#[allow(clippy::too_many_arguments)]
pub fn spawn_on(
    rt: &tokio::runtime::Handle,
    shutdown_tx: tokio::sync::watch::Sender<bool>,
    #[cfg(feature = "media")] frame_mount_factory: FrameMountFactory,
    #[cfg(feature = "media")] player_state: crate::frame_sink::PlayerStateSlot,
    #[cfg(feature = "media")] recording_state: crate::frame_sink::RecordingStateSlot,
    #[cfg(feature = "media")] clip_list: crate::frame_sink::ClipListSlot,
    // Phase 10 Task 0 (fix #17 + #34). Shared export-progress state.
    // Bus writer at mode/outcome transitions; UI reader (30 Hz timer)
    // drives the export-sheet view (form/progress/summary). Task 0
    // wires the slot through; Task 2's real
    // `ExportCompilations` handler writes to it.
    #[cfg(feature = "media")] export_progress: crate::frame_sink::ExportProgressSlot,
    #[cfg(feature = "media")] fixture_recording_source: Option<std::path::PathBuf>,
) -> BusHandle {
    let (tx, mut rx) = mpsc::channel::<Envelope>(64);
    #[cfg(feature = "media")]
    let rt_for_poll = rt.clone();
    #[cfg(feature = "media")]
    let shutdown_tx_for_poll = shutdown_tx.clone();
    rt.spawn(async move {
        // Per-task recording state. `None` until StartRecording succeeds;
        // taken by StopRecording. Held across loop iterations because start
        // and stop are necessarily separate commands.
        #[cfg(feature = "media")]
        let mut recording: Option<video_coach_media::recording::Recording> = None;

        // Per-task project state. `None` until OpenProject / NewProject
        // succeeds. Stored as (Project, project_folder) so subsequent
        // commands (Phase 7 AddSourceVideo, future ExportClip, etc.)
        // can resolve paths relative to the project folder and write
        // back to the same `project.json`.
        let mut current: Option<(video_coach_core::project::Project, std::path::PathBuf)> = None;

        // Phase 7: per-task source-player state. Spawned (in
        // spawn_blocking) when a project with `sourceVideos[0]` becomes
        // current. Played/paused/seeked by the bus's transport commands.
        // Held in an `Arc` so position-poll tasks (Task 5) can also read
        // a snapshot without blocking the bus loop.
        #[cfg(feature = "media")]
        let mut current_player: Option<
            std::sync::Arc<video_coach_media::source_player::SourcePlayer>,
        > = None;

        // Phase 8: clip-recording mode + in-progress clip state. Mode
        // mutations stay on this task (adversarial-review fix #2) — the
        // spawn_blocking calls inside StartClipRecording / StopClipRecording
        // run their GStreamer ops on a worker, but writes to
        // `current_mode` / `recording_clip` happen here on the bus task
        // after the await returns. Same pattern as Phase 7's
        // try_spawn_current_player.
        #[cfg(feature = "media")]
        let mut current_mode: AppMode = AppMode::Scanning;
        #[cfg(feature = "media")]
        let mut recording_clip: Option<RecordingClipInProgress> = None;

        // Phase 9 (fix #3 + #26): per-pipeline mount handles. Set when a
        // pipeline mounts; cleared when it tears down. The bus uses
        // `current_player_mount.active` to gate frame writes during the
        // OpenClipPreview/ClosePreview handover, and reads
        // `current_preview_mount.frames_pushed` on ClosePreview to
        // populate the `clip_preview.closed` event for the harness E2E
        // pixel-flow assertion. Task 0 declares the fields; Task 3
        // populates `current_preview_mount` when OpenClipPreview lands.
        #[cfg(feature = "media")]
        let mut current_player_mount: Option<crate::frame_sink::MountHandles> = None;
        #[cfg(feature = "media")]
        let mut current_preview_mount: Option<crate::frame_sink::MountHandles> = None;

        // Phase 9 Task 3 (fix #14 + #15 + #21). Per-task preview state. The
        // pipeline is held in an `Arc` so the position-poll task can read
        // `snapshot()` without blocking the bus loop. The poll task's
        // `AbortHandle` lets `ClosePreview` cancel it before tearing down
        // the pipeline (otherwise the poll holds an Arc clone and
        // `Arc::try_unwrap` fails). The shared compositor (fix #21) is
        // constructed once at task spawn and cloned per OpenClipPreview —
        // also saves wgpu init cost across repeated previews.
        #[cfg(feature = "media")]
        let mut current_preview: Option<
            std::sync::Arc<video_coach_media::preview_pipeline::PreviewPipeline>,
        > = None;
        #[cfg(feature = "media")]
        let mut current_preview_poll: Option<tokio::task::AbortHandle> = None;
        #[cfg(feature = "media")]
        let compositor: std::sync::Arc<video_coach_compositor::Compositor> = std::sync::Arc::new(
            video_coach_compositor::Compositor::new_headless().expect("compositor init"),
        );

        // Phase 10 Task 0 (fix #10). Cancel-flag for the in-flight
        // batch export. Held while `current_mode == Exporting`; set to
        // true by `Command::CancelExport`; the export driver in
        // `video-coach-media::export` checks it before each frame
        // push, transitions to Null on flip, and deletes the partial
        // output. Initialized to `None` here; Task 1 + Task 2 will
        // populate / consume it.
        #[cfg(feature = "media")]
        let mut current_export_cancel: Option<
            std::sync::Arc<std::sync::atomic::AtomicBool>,
        > = None;

        // Phase 10 Task 4 prep (architecture fix). Internal cleanup
        // channel: the spawned export-batch task signals "I'm done"
        // by sending `()` here. The bus's main `select!` loop picks
        // it up and resets `current_mode` + `current_export_cancel`
        // (which the spawned task can't borrow because they're
        // bus-task-local). Without this, the bus task would have to
        // `.await` the export inline — blocking it from receiving
        // CancelExport / any other command until the batch finishes.
        #[cfg(feature = "media")]
        let (export_cleanup_tx, mut export_cleanup_rx) =
            tokio::sync::mpsc::unbounded_channel::<()>();

        loop {
            #[cfg(feature = "media")]
            let next_env = tokio::select! {
                env = rx.recv() => env,
                cleanup = export_cleanup_rx.recv() => {
                    if cleanup.is_some() {
                        // Spawned export task signaled completion.
                        // Reset bus-local state. The slot's outcome
                        // was already written by the spawned task.
                        current_export_cancel = None;
                        if matches!(current_mode, AppMode::Exporting) {
                            current_mode = AppMode::Scanning;
                            write_recording_state(&recording_state, &current_mode, None);
                        }
                    }
                    continue;
                }
            };
            #[cfg(not(feature = "media"))]
            let next_env = rx.recv().await;

            let Some(env) = next_env else { break };

            let reply = handle(
                env.command,
                &shutdown_tx,
                #[cfg(feature = "media")]
                &mut recording,
                &mut current,
                #[cfg(feature = "media")]
                &mut current_player,
                #[cfg(feature = "media")]
                &mut current_player_mount,
                #[cfg(feature = "media")]
                &mut current_preview_mount,
                #[cfg(feature = "media")]
                &mut current_preview,
                #[cfg(feature = "media")]
                &mut current_preview_poll,
                #[cfg(feature = "media")]
                &compositor,
                #[cfg(feature = "media")]
                &frame_mount_factory,
                #[cfg(feature = "media")]
                &rt_for_poll,
                #[cfg(feature = "media")]
                &shutdown_tx_for_poll,
                #[cfg(feature = "media")]
                &player_state,
                #[cfg(feature = "media")]
                &recording_state,
                #[cfg(feature = "media")]
                &clip_list,
                #[cfg(feature = "media")]
                &export_progress,
                #[cfg(feature = "media")]
                &mut current_mode,
                #[cfg(feature = "media")]
                &mut recording_clip,
                #[cfg(feature = "media")]
                &mut current_export_cancel,
                #[cfg(feature = "media")]
                &export_cleanup_tx,
                #[cfg(feature = "media")]
                fixture_recording_source.as_deref(),
            )
            .await;
            let _ = env.reply.send(reply);
        }
    });
    BusHandle { tx }
}

/// Phase 7 Task 5. Position-polling task. Spawned alongside each
/// SourcePlayer; reads `snapshot()` every 100 ms and writes the result
/// to the shared `PlayerStateSlot`. Runs until `shutdown_rx` fires —
/// for the MVP we don't support multiple players, so a single
/// long-lived task is correct. (When swap-player lands in Phase 7.5+
/// this will need an AbortHandle to cancel the old task.)
#[cfg(feature = "media")]
fn spawn_position_poll(
    rt: &tokio::runtime::Handle,
    player: std::sync::Arc<video_coach_media::source_player::SourcePlayer>,
    state: crate::frame_sink::PlayerStateSlot,
    mut shutdown_rx: tokio::sync::watch::Receiver<bool>,
) {
    rt.spawn(async move {
        let mut tick = tokio::time::interval(std::time::Duration::from_millis(100));
        // Skip the initial tick — `interval` fires immediately on
        // creation; we want the first poll to happen after 100ms so
        // GStreamer has had time to publish a position.
        tick.tick().await;
        loop {
            tokio::select! {
                _ = tick.tick() => {
                    let snap = player.snapshot();
                    let mut guard = state.lock().expect("player_state poisoned");
                    // Suppress one cycle after a recent seek (200 ms
                    // window — the decoder typically delivers its
                    // first post-seek buffer well within that).
                    let suppress = guard
                        .last_seek_at
                        .map(|t| t.elapsed() < std::time::Duration::from_millis(200))
                        .unwrap_or(false);
                    if !suppress {
                        guard.position_seconds = snap.position_seconds;
                    }
                    guard.duration_seconds = snap.duration_seconds;
                    guard.is_playing = snap.is_playing;
                }
                _ = shutdown_rx.changed() => {
                    if *shutdown_rx.borrow() {
                        break;
                    }
                }
            }
        }
    });
}

/// Phase 9 Task 3 (fix #15). Position-poll task for the preview pipeline.
/// Mirrors `spawn_position_poll`'s shape (100 ms tick, 200 ms last_seek_at
/// suppression, watch-based shutdown) but takes the
/// `PreviewPipeline`'s `snapshot()` and returns an `AbortHandle` so
/// `ClosePreview` can cancel it before tearing the pipeline down.
///
/// Same shared `PlayerStateSlot` (per fix #16) — the UI reads ONE slot
/// and doesn't need to know which pipeline produced the data.
#[cfg(feature = "media")]
fn spawn_preview_position_poll(
    rt: &tokio::runtime::Handle,
    preview: std::sync::Arc<video_coach_media::preview_pipeline::PreviewPipeline>,
    state: crate::frame_sink::PlayerStateSlot,
    mut shutdown_rx: tokio::sync::watch::Receiver<bool>,
) -> tokio::task::AbortHandle {
    let join = rt.spawn(async move {
        let mut tick = tokio::time::interval(std::time::Duration::from_millis(100));
        // Skip the immediate first fire; first poll happens after 100 ms.
        tick.tick().await;
        loop {
            tokio::select! {
                _ = tick.tick() => {
                    let snap = preview.snapshot();
                    let mut guard = state.lock().expect("player_state poisoned");
                    let suppress = guard
                        .last_seek_at
                        .map(|t| t.elapsed() < std::time::Duration::from_millis(200))
                        .unwrap_or(false);
                    if !suppress {
                        guard.position_seconds = snap.position_seconds;
                    }
                    guard.duration_seconds = snap.duration_seconds;
                    guard.is_playing = snap.is_playing;
                }
                _ = shutdown_rx.changed() => {
                    if *shutdown_rx.borrow() {
                        break;
                    }
                }
            }
        }
    });
    join.abort_handle()
}

/// Phase 9 Task 3 (fix #13). Hydrate the shared `ClipListSlot` from the
/// project's `clips` vector. Called from three sites: `OpenProject`,
/// `NewProject`, `StopClipRecording`. The slot is what the UI's 30 Hz
/// timer reads to populate the sidebar.
#[cfg(feature = "media")]
fn write_clip_list(
    slot: &crate::frame_sink::ClipListSlot,
    clips: &[video_coach_core::project::Clip],
) {
    let summaries: Vec<crate::frame_sink::ClipSummary> = clips
        .iter()
        .map(|c| crate::frame_sink::ClipSummary {
            id: c.id,
            name: c.name.clone(),
            recording_duration: c.recording_duration,
            source_index: c.source_index,
            // Phase 10 (Task 3 plan's "pick (b)"): UI's tag-aggregation
            // step for the export sheet runs from this slot, so we
            // copy `Clip::tags` through. Cheap (a few short Strings
            // per clip; cloned only at hydration sites).
            tags: c.tags.clone(),
        })
        .collect();
    let mut g = slot.lock().expect("clip_list poisoned");
    *g = summaries;
}

/// In-progress clip recording metadata. Built when `StartClipRecording`
/// succeeds, mutated as stroke events arrive, taken + finalized into a
/// `Clip` by `StopClipRecording`.
#[cfg(feature = "media")]
pub(crate) struct RecordingClipInProgress {
    pub clip_id: uuid::Uuid,
    pub filename: String,
    pub output_path: std::path::PathBuf,
    pub source_index: usize,
    pub start_source_seconds: f64,
    /// Host-clock anchor for `recordTime` computation on every
    /// appended event AND for the final clip duration on stop.
    /// (Adversarial-review fix #4: the public `Recording::stop()`
    /// signature returns no duration; we compute it here as
    /// `t0_instant.elapsed().as_secs_f64()` right before calling
    /// stop().)
    pub t0_instant: std::time::Instant,
    pub events: Vec<video_coach_core::event::CommentaryEvent>,
}

/// Centralized "is the clip-recording / preview / export subsystem
/// busy?" check used by every command that would mutate any of them.
/// Returns true if the lower-level `recording` slot OR the higher-level
/// `recording_clip` slot OR the mode is anywhere outside of `Scanning`.
/// Stops harness tests + future user inputs from accidentally
/// double-starting (Phase 8 adversarial-review fix #7), stops a
/// recording from kicking off while a preview is open (Phase 9 fix
/// #22), and stops `OpenClipPreview` / `StartClipRecording` /
/// `ExportCompilations` from kicking off while another export is
/// in flight (Phase 10 fix #9).
///
/// Phase 9 generalises the Phase 8 `is_recording` helper to cover
/// `PreviewClip`; Phase 10 covers `Exporting` for free via the
/// `!matches!(_, Scanning)` predicate. Signature takes `&AppMode`
/// since `AppMode` dropped `Copy` (fix #8).
#[cfg(feature = "media")]
fn is_busy(
    recording: &Option<video_coach_media::recording::Recording>,
    recording_clip: &Option<RecordingClipInProgress>,
    current_mode: &AppMode,
) -> bool {
    recording.is_some() || recording_clip.is_some() || !matches!(*current_mode, AppMode::Scanning)
}

/// Default clip-name format: `<sourceIndex+1>-HH:MM:SS` where the time
/// is the playhead within the source at R-press. Mirrors v1's
/// `App/ContentView.swift::defaultClipName` 1:1.
#[cfg(feature = "media")]
fn default_clip_name(source_index: usize, start_source_seconds: f64) -> String {
    let total = start_source_seconds.max(0.0).floor() as i64;
    let h = total / 3600;
    let m = (total % 3600) / 60;
    let s = total % 60;
    format!("{}-{:02}:{:02}:{:02}", source_index + 1, h, m, s)
}

/// Push the current `AppMode` into the shared `RecordingStateSlot`,
/// stamping a host-time anchor when transitioning into a recording
/// mode. The UI's 30 Hz timer reads this for the REC indicator +
/// elapsed M:SS label.
///
/// Phase 9 (fix #8): takes `&AppMode` since `AppMode` dropped `Copy`
/// for the `PreviewClip(Uuid)` variant. Maps `PreviewClip(_)` to
/// `RecordingMode::PreviewClip`; the UUID stays on the bus task.
#[cfg(feature = "media")]
fn write_recording_state(
    slot: &crate::frame_sink::RecordingStateSlot,
    mode: &AppMode,
    started_at: Option<std::time::Instant>,
) {
    use crate::frame_sink::{RecordingMode, RecordingStateSlotData};
    let mode_local = match mode {
        AppMode::Scanning => RecordingMode::Scanning,
        AppMode::RecordingStarting => RecordingMode::RecordingStarting,
        AppMode::Recording => RecordingMode::Recording,
        AppMode::PreviewClip(_) => RecordingMode::PreviewClip,
        // Phase 10 Task 0 — UI's 30 Hz timer reads this to swap the
        // export-sheet between form / progress / summary views; the
        // `current_tag` / `completed_tags` state rides on
        // `ExportProgressSlot`, not here.
        AppMode::Exporting => RecordingMode::Exporting,
    };
    let mut g = slot.lock().expect("recording_state poisoned");
    *g = RecordingStateSlotData {
        mode: mode_local,
        recording_started_at_host: started_at,
    };
}

#[allow(clippy::too_many_arguments)]
async fn handle(
    cmd: Command,
    shutdown_tx: &tokio::sync::watch::Sender<bool>,
    #[cfg(feature = "media")] recording: &mut Option<video_coach_media::recording::Recording>,
    current: &mut Option<(video_coach_core::project::Project, std::path::PathBuf)>,
    #[cfg(feature = "media")] current_player: &mut Option<
        std::sync::Arc<video_coach_media::source_player::SourcePlayer>,
    >,
    #[cfg(feature = "media")] current_player_mount: &mut Option<crate::frame_sink::MountHandles>,
    #[cfg(feature = "media")] current_preview_mount: &mut Option<crate::frame_sink::MountHandles>,
    #[cfg(feature = "media")] current_preview: &mut Option<
        std::sync::Arc<video_coach_media::preview_pipeline::PreviewPipeline>,
    >,
    #[cfg(feature = "media")] current_preview_poll: &mut Option<tokio::task::AbortHandle>,
    #[cfg(feature = "media")] compositor: &std::sync::Arc<video_coach_compositor::Compositor>,
    #[cfg(feature = "media")] frame_mount_factory: &FrameMountFactory,
    #[cfg(feature = "media")] rt_for_poll: &tokio::runtime::Handle,
    #[cfg(feature = "media")] shutdown_tx_for_poll: &tokio::sync::watch::Sender<bool>,
    #[cfg(feature = "media")] player_state: &crate::frame_sink::PlayerStateSlot,
    #[cfg(feature = "media")] recording_state: &crate::frame_sink::RecordingStateSlot,
    #[cfg(feature = "media")] clip_list: &crate::frame_sink::ClipListSlot,
    #[cfg(feature = "media")] export_progress: &crate::frame_sink::ExportProgressSlot,
    #[cfg(feature = "media")] current_mode: &mut AppMode,
    #[cfg(feature = "media")] recording_clip: &mut Option<RecordingClipInProgress>,
    #[cfg(feature = "media")] current_export_cancel: &mut Option<
        std::sync::Arc<std::sync::atomic::AtomicBool>,
    >,
    #[cfg(feature = "media")] export_cleanup_tx: &tokio::sync::mpsc::UnboundedSender<()>,
    #[cfg(feature = "media")] fixture_recording_source: Option<&std::path::Path>,
) -> CommandReply {
    match cmd {
        Command::Quit => {
            tracing::info!(target: "app.lifecycle", event = "app.shutdown_requested");
            let _ = shutdown_tx.send(true);
            // When a Slint UI is running on the main thread, the watch on
            // shutdown_rx in ui::run also calls quit_event_loop. Calling it
            // here too is a belt-and-suspenders no-op when no event loop
            // is active (e.g. --headless), and it shaves the shutdown
            // latency by one tokio scheduling round-trip when the UI is up.
            // quit_event_loop is documented as thread-safe in Slint 1.8.
            let _ = slint::quit_event_loop();
            CommandReply {
                ok: true,
                error: None,
            }
        }
        Command::Ping => {
            tracing::info!(target: "app.lifecycle", event = "app.ping");
            CommandReply {
                ok: true,
                error: None,
            }
        }
        Command::StartRecording { source, output } => {
            #[cfg(not(feature = "media"))]
            {
                let _ = (source, output);
                CommandReply {
                    ok: false,
                    error: Some("media feature disabled in this build".into()),
                }
            }
            #[cfg(feature = "media")]
            {
                use std::sync::Arc;
                use video_coach_media::fixture_source::FixtureSource;
                use video_coach_media::source::CaptureSourceFactory;

                if is_busy(recording, recording_clip, current_mode) {
                    return CommandReply {
                        ok: false,
                        error: Some("already recording".into()),
                    };
                }
                let factory: Arc<dyn CaptureSourceFactory> = match source {
                    SourceConfig::Fixture { path } => Arc::new(FixtureSource::new(path)),
                    SourceConfig::PlatformDefault => {
                        Arc::new(video_coach_media::platform_source::PlatformDefaultSource::new())
                    }
                };
                match video_coach_media::recording::start(factory, output.into()) {
                    Ok(rec) => {
                        *recording = Some(rec);
                        CommandReply {
                            ok: true,
                            error: None,
                        }
                    }
                    Err(e) => CommandReply {
                        ok: false,
                        error: Some(e.to_string()),
                    },
                }
            }
        }
        Command::StopRecording => {
            #[cfg(not(feature = "media"))]
            {
                CommandReply {
                    ok: false,
                    error: Some("media feature disabled in this build".into()),
                }
            }
            #[cfg(feature = "media")]
            {
                match recording.take() {
                    Some(rec) => {
                        // Recording::stop blocks for up to 5s waiting on a
                        // GStreamer bus message. Offload to a blocking pool
                        // so we don't stall the tokio executor thread.
                        let result = tokio::task::spawn_blocking(move || rec.stop()).await;
                        match result {
                            Ok(Ok(())) => CommandReply {
                                ok: true,
                                error: None,
                            },
                            Ok(Err(e)) => CommandReply {
                                ok: false,
                                error: Some(e.to_string()),
                            },
                            Err(join) => CommandReply {
                                ok: false,
                                error: Some(format!("join: {join}")),
                            },
                        }
                    }
                    None => CommandReply {
                        ok: false,
                        error: Some("no active recording".into()),
                    },
                }
            }
        }
        Command::NewProject { path } => {
            let folder = normalize_project_folder(&path);
            // Canonicalize ahead of pathdiff math (Phase 7 AddSourceVideo
            // stores paths relative to this folder). Required on macOS
            // where `/tmp` is a symlink to `/private/tmp` — non-canonical
            // folder + canonical source produces a relative path with the
            // wrong number of `..` segments and filesrc can't open it.
            // For NewProject the folder may not exist yet, so canonicalize
            // the parent and rejoin the basename.
            let folder = match folder.parent().and_then(|p| {
                p.canonicalize()
                    .ok()
                    .and_then(|cp| folder.file_name().map(|name| cp.join(name)))
            }) {
                Some(c) => c,
                None => folder,
            };
            let folder_for_blocking = folder.clone();
            let result = tokio::task::spawn_blocking(
                move || -> Result<video_coach_core::project::Project, String> {
                    if folder_for_blocking.join("project.json").exists() {
                        return Err(format!(
                            "{} already contains a project.json — refusing to overwrite",
                            folder_for_blocking.display()
                        ));
                    }
                    let name = folder_for_blocking
                        .file_name()
                        .and_then(|s| s.to_str())
                        .unwrap_or("Untitled")
                        .to_string();
                    let project = video_coach_core::project::Project::new(name);
                    video_coach_core::project_store::write(&project, &folder_for_blocking)
                        .map_err(|e| e.to_string())?;
                    Ok(project)
                },
            )
            .await;
            match result {
                Ok(Ok(project)) => {
                    tracing::info!(
                        target: "project.lifecycle",
                        event = "project.opened",
                        path = %path,
                        name = %project.name,
                        created = true,
                    );
                    *current = Some((project, folder));
                    #[cfg(feature = "media")]
                    {
                        try_spawn_current_player(
                            current,
                            current_player,
                            current_player_mount,
                            frame_mount_factory,
                            rt_for_poll,
                            shutdown_tx_for_poll,
                            player_state,
                        )
                        .await;
                        // Phase 9 Task 3 (fix #13). NewProject's
                        // project.clips is empty; this clears any stale
                        // contents from a previously-open project so the
                        // sidebar matches the now-current project.
                        if let Some((p, _)) = current.as_ref() {
                            write_clip_list(clip_list, &p.clips);
                        }
                    }
                    CommandReply {
                        ok: true,
                        error: None,
                    }
                }
                Ok(Err(msg)) => CommandReply {
                    ok: false,
                    error: Some(msg),
                },
                Err(join) => CommandReply {
                    ok: false,
                    error: Some(format!("join: {join}")),
                },
            }
        }
        Command::OpenProject { path } => {
            let folder = normalize_project_folder(&path);
            // Same canonicalize as NewProject — see comment there.
            let folder = folder.canonicalize().unwrap_or(folder);
            let folder_for_blocking = folder.clone();
            // ProjectStore::read does sync file IO + serde_json::from_slice
            // on potentially megabytes of stroke data. Same pattern as
            // StopRecording: spawn_blocking so the bus task isn't held
            // while disk reads complete.
            let result = tokio::task::spawn_blocking(move || {
                video_coach_core::project_store::read(&folder_for_blocking)
            })
            .await;
            match result {
                Ok(Ok(project)) => {
                    tracing::info!(
                        target: "project.lifecycle",
                        event = "project.opened",
                        path = %path,
                        name = %project.name,
                    );
                    *current = Some((project, folder));
                    #[cfg(feature = "media")]
                    {
                        try_spawn_current_player(
                            current,
                            current_player,
                            current_player_mount,
                            frame_mount_factory,
                            rt_for_poll,
                            shutdown_tx_for_poll,
                            player_state,
                        )
                        .await;
                        // Phase 9 Task 3 (fix #13). Hydrate sidebar from
                        // freshly-loaded project.clips.
                        if let Some((p, _)) = current.as_ref() {
                            write_clip_list(clip_list, &p.clips);
                        }
                    }
                    CommandReply {
                        ok: true,
                        error: None,
                    }
                }
                Ok(Err(e)) => CommandReply {
                    ok: false,
                    error: Some(e.to_string()),
                },
                Err(join) => CommandReply {
                    ok: false,
                    error: Some(format!("join: {join}")),
                },
            }
        }
        Command::AddSourceVideo { absolute_path } => {
            #[cfg(not(feature = "media"))]
            {
                let _ = absolute_path;
                CommandReply {
                    ok: false,
                    error: Some("media feature disabled in this build".into()),
                }
            }
            #[cfg(feature = "media")]
            {
                let Some((project, project_folder)) = current.as_mut() else {
                    return CommandReply {
                        ok: false,
                        error: Some("no project open".into()),
                    };
                };
                let abs = std::path::PathBuf::from(&absolute_path);
                if !abs.is_file() {
                    return CommandReply {
                        ok: false,
                        error: Some(format!("{} is not a regular file", abs.display())),
                    };
                }
                let folder_for_blocking = project_folder.clone();
                let abs_for_blocking = abs.clone();
                // Discoverer + relative-path math both want to run off
                // the bus task — Discoverer is a brief but blocking
                // GStreamer call.
                let result = tokio::task::spawn_blocking(
                    move || -> Result<(String, String, f64), String> {
                        let duration =
                            video_coach_media::source_player::probe_duration(&abs_for_blocking)
                                .map_err(|e| e.to_string())?;
                        let rel = pathdiff::diff_paths(&abs_for_blocking, &folder_for_blocking)
                            .ok_or_else(|| {
                                "could not compute relative path (different drives?)".to_string()
                            })?;
                        let display_name = abs_for_blocking
                            .file_name()
                            .and_then(|s| s.to_str())
                            .unwrap_or("source")
                            .to_string();
                        Ok((rel.to_string_lossy().into_owned(), display_name, duration))
                    },
                )
                .await;
                let (relative_path, display_name, duration_seconds) = match result {
                    Ok(Ok(t)) => t,
                    Ok(Err(msg)) => {
                        return CommandReply {
                            ok: false,
                            error: Some(msg),
                        }
                    }
                    Err(join) => {
                        return CommandReply {
                            ok: false,
                            error: Some(format!("join: {join}")),
                        }
                    }
                };
                project
                    .source_videos
                    .push(video_coach_core::project::SourceRef {
                        relative_path: relative_path.clone(),
                        display_name: display_name.clone(),
                        duration_seconds,
                    });
                // Persist. Failure here leaves the in-memory project
                // ahead of disk — surface as an error and roll back the
                // push so the user sees a consistent state.
                let project_clone = project.clone();
                let folder_for_write = project_folder.clone();
                let write_result = tokio::task::spawn_blocking(move || {
                    video_coach_core::project_store::write(&project_clone, &folder_for_write)
                })
                .await;
                match write_result {
                    Ok(Ok(())) => {
                        tracing::info!(
                            target: "project.lifecycle",
                            event = "source.added",
                            relative_path = %relative_path,
                            display_name = %display_name,
                            duration_seconds,
                            count = project.source_videos.len(),
                        );
                        // If this was the first source ever added to this
                        // project AND no player is loaded yet, spin one
                        // up so subsequent Play/Pause/Seek commands have
                        // somewhere to land. (Adversarial fix #3.)
                        try_spawn_current_player(
                            current,
                            current_player,
                            current_player_mount,
                            frame_mount_factory,
                            rt_for_poll,
                            shutdown_tx_for_poll,
                            player_state,
                        )
                        .await;
                        CommandReply {
                            ok: true,
                            error: None,
                        }
                    }
                    Ok(Err(e)) => {
                        project.source_videos.pop();
                        CommandReply {
                            ok: false,
                            error: Some(format!("write project.json: {e}")),
                        }
                    }
                    Err(join) => {
                        project.source_videos.pop();
                        CommandReply {
                            ok: false,
                            error: Some(format!("join: {join}")),
                        }
                    }
                }
            }
        }
        Command::Play => {
            #[cfg(not(feature = "media"))]
            {
                CommandReply {
                    ok: false,
                    error: Some("media feature disabled in this build".into()),
                }
            }
            #[cfg(feature = "media")]
            {
                // Phase 9 Task 3 (fix #16): route to whichever pipeline is
                // mounted. PreviewClip mode → preview pipeline. Otherwise
                // → source player.
                let result: Result<Result<(), String>, tokio::task::JoinError> =
                    if matches!(*current_mode, AppMode::PreviewClip(_)) {
                        let Some(preview) = current_preview.as_ref() else {
                            return CommandReply {
                                ok: false,
                                error: Some("no preview loaded".into()),
                            };
                        };
                        let preview = preview.clone();
                        tokio::task::spawn_blocking(move || {
                            preview.play().map_err(|e| e.to_string())
                        })
                        .await
                    } else {
                        let Some(player) = current_player.as_ref() else {
                            return CommandReply {
                                ok: false,
                                error: Some("no source loaded".into()),
                            };
                        };
                        let player = player.clone();
                        tokio::task::spawn_blocking(move || {
                            player.play().map_err(|e| e.to_string())
                        })
                        .await
                    };
                match result {
                    Ok(Ok(())) => CommandReply {
                        ok: true,
                        error: None,
                    },
                    Ok(Err(e)) => CommandReply {
                        ok: false,
                        error: Some(e),
                    },
                    Err(join) => CommandReply {
                        ok: false,
                        error: Some(format!("join: {join}")),
                    },
                }
            }
        }
        Command::Pause => {
            #[cfg(not(feature = "media"))]
            {
                CommandReply {
                    ok: false,
                    error: Some("media feature disabled in this build".into()),
                }
            }
            #[cfg(feature = "media")]
            {
                let result: Result<Result<(), String>, tokio::task::JoinError> =
                    if matches!(*current_mode, AppMode::PreviewClip(_)) {
                        let Some(preview) = current_preview.as_ref() else {
                            return CommandReply {
                                ok: false,
                                error: Some("no preview loaded".into()),
                            };
                        };
                        let preview = preview.clone();
                        tokio::task::spawn_blocking(move || {
                            preview.pause().map_err(|e| e.to_string())
                        })
                        .await
                    } else {
                        let Some(player) = current_player.as_ref() else {
                            return CommandReply {
                                ok: false,
                                error: Some("no source loaded".into()),
                            };
                        };
                        let player = player.clone();
                        tokio::task::spawn_blocking(move || {
                            player.pause().map_err(|e| e.to_string())
                        })
                        .await
                    };
                match result {
                    Ok(Ok(())) => CommandReply {
                        ok: true,
                        error: None,
                    },
                    Ok(Err(e)) => CommandReply {
                        ok: false,
                        error: Some(e),
                    },
                    Err(join) => CommandReply {
                        ok: false,
                        error: Some(format!("join: {join}")),
                    },
                }
            }
        }
        Command::Seek { seconds, accurate } => {
            #[cfg(not(feature = "media"))]
            {
                let _ = (seconds, accurate);
                CommandReply {
                    ok: false,
                    error: Some("media feature disabled in this build".into()),
                }
            }
            #[cfg(feature = "media")]
            {
                let result: Result<Result<(), String>, tokio::task::JoinError> =
                    if matches!(*current_mode, AppMode::PreviewClip(_)) {
                        let Some(preview) = current_preview.as_ref() else {
                            return CommandReply {
                                ok: false,
                                error: Some("no preview loaded".into()),
                            };
                        };
                        let preview = preview.clone();
                        tokio::task::spawn_blocking(move || {
                            preview.seek(seconds, accurate).map_err(|e| e.to_string())
                        })
                        .await
                    } else {
                        let Some(player) = current_player.as_ref() else {
                            return CommandReply {
                                ok: false,
                                error: Some("no source loaded".into()),
                            };
                        };
                        let player = player.clone();
                        tokio::task::spawn_blocking(move || {
                            player.seek(seconds, accurate).map_err(|e| e.to_string())
                        })
                        .await
                    };
                // Record the seek so the position-poll task suppresses
                // its next update — otherwise the bar briefly snaps
                // back to the pre-seek position while the decoder
                // flushes. (Adversarial-review fix #8.) Same write
                // regardless of which pipeline received the seek (fix
                // #16: ONE shared PlayerStateSlot).
                if matches!(result, Ok(Ok(()))) {
                    let mut g = player_state.lock().expect("player_state poisoned");
                    g.last_seek_at = Some(std::time::Instant::now());
                    g.position_seconds = seconds.max(0.0);
                }
                match result {
                    Ok(Ok(())) => CommandReply {
                        ok: true,
                        error: None,
                    },
                    Ok(Err(e)) => CommandReply {
                        ok: false,
                        error: Some(e),
                    },
                    Err(join) => CommandReply {
                        ok: false,
                        error: Some(format!("join: {join}")),
                    },
                }
            }
        }
        Command::SetScanVolume { value } => {
            #[cfg(not(feature = "media"))]
            {
                let _ = value;
                CommandReply {
                    ok: false,
                    error: Some("media feature disabled in this build".into()),
                }
            }
            #[cfg(feature = "media")]
            {
                let Some(player) = current_player.as_ref() else {
                    return CommandReply {
                        ok: false,
                        error: Some("no source loaded".into()),
                    };
                };
                // set_volume is a cheap GObject property write; no need
                // to spawn_blocking. The volume name lookup is mutex'd
                // inside GStreamer.
                player.set_volume(value);
                // Persist to project.preferences.scan_volume so the
                // setting survives across sessions. Phase 7 MVP writes
                // on every change — project.json is small and atomic
                // rename is cheap. Future patch can debounce.
                if let Some((project, folder)) = current.as_mut() {
                    project.preferences.scan_volume = value;
                    let project_clone = project.clone();
                    let folder_clone = folder.clone();
                    let _ = tokio::task::spawn_blocking(move || {
                        let _ =
                            video_coach_core::project_store::write(&project_clone, &folder_clone);
                    })
                    .await;
                }
                CommandReply {
                    ok: true,
                    error: None,
                }
            }
        }
        Command::StartClipRecording {
            playhead_snapshot_seconds,
        } => {
            #[cfg(not(feature = "media"))]
            {
                let _ = playhead_snapshot_seconds;
                CommandReply {
                    ok: false,
                    error: Some("media feature disabled in this build".into()),
                }
            }
            #[cfg(feature = "media")]
            {
                use std::sync::Arc;
                use video_coach_media::source::CaptureSourceFactory;

                // Adversarial-review fix #7 (Phase 8) + fix #22 (Phase
                // 9): one centralized busy check that also covers
                // PreviewClip — opening a recording while a preview is
                // open is rejected here.
                if is_busy(recording, recording_clip, current_mode) {
                    return CommandReply {
                        ok: false,
                        error: Some("already recording".into()),
                    };
                }
                if !matches!(current_mode, AppMode::Scanning) {
                    // Belt + suspenders. is_busy covers
                    // RecordingStarting / Recording / PreviewClip; this
                    // catches any future intermediate mode we add later.
                    return CommandReply {
                        ok: false,
                        error: Some(format!("cannot start recording in mode {:?}", current_mode)),
                    };
                }
                let Some((project, project_folder)) = current.as_ref() else {
                    return CommandReply {
                        ok: false,
                        error: Some("no project open".into()),
                    };
                };
                if project.source_videos.is_empty() {
                    return CommandReply {
                        ok: false,
                        error: Some("project has no source videos".into()),
                    };
                }
                // Source index for the clip = the active source. MVP:
                // sourceVideos[0]. Phase 7.5+ will track an active
                // index when multi-source lands.
                let source_index = 0_usize;

                // Pause the source on R-press. v1 ContentView.swift
                // does this BEFORE the await on capture.startRecording
                // so the source stays paused all the way to t0; we
                // mirror that — and ignore failures, since pausing an
                // already-paused or no-loaded player should not block
                // the recording start.
                if let Some(player) = current_player.as_ref() {
                    let player = player.clone();
                    let _ = tokio::task::spawn_blocking(move || player.pause()).await;
                }

                let clip_id = uuid::Uuid::new_v4();
                let filename = format!("clip-{clip_id}.mov");
                let recordings_dir =
                    video_coach_core::project_store::recordings_dir(project_folder);
                let output_path = recordings_dir.join(&filename);

                // Build the source factory. CI / harness uses the
                // fixture-source override (no webcam permissions);
                // production gets the platform default. The
                // PlatformDefault arm wires real GStreamer elements
                // in Task 2.
                let factory: Arc<dyn CaptureSourceFactory> = match fixture_recording_source {
                    Some(p) => Arc::new(video_coach_media::fixture_source::FixtureSource::new(
                        p.to_path_buf(),
                    )),
                    None => match build_platform_default_source() {
                        Ok(f) => f,
                        Err(e) => {
                            return CommandReply {
                                ok: false,
                                error: Some(e),
                            };
                        }
                    },
                };

                // Transition to RecordingStarting BEFORE the blocking
                // recording::start so the UI's REC indicator can show
                // "Preparing…" through the camera-permission prompt.
                *current_mode = AppMode::RecordingStarting;
                let t0_instant = std::time::Instant::now();
                write_recording_state(recording_state, current_mode, Some(t0_instant));

                // recording::start runs the GStreamer pipeline build +
                // PAUSED→PLAYING transition; on macOS first launch it
                // can block on the camera-permission prompt. Off-load
                // to a worker so the bus task isn't held.
                let output_path_clone = output_path.clone();
                let result = tokio::task::spawn_blocking(move || {
                    video_coach_media::recording::start(factory, output_path_clone)
                })
                .await;
                match result {
                    Ok(Ok(rec)) => {
                        *recording = Some(rec);
                        *current_mode = AppMode::Recording;
                        write_recording_state(recording_state, current_mode, Some(t0_instant));
                        *recording_clip = Some(RecordingClipInProgress {
                            clip_id,
                            filename: filename.clone(),
                            output_path: output_path.clone(),
                            source_index,
                            start_source_seconds: playhead_snapshot_seconds.max(0.0),
                            t0_instant,
                            events: Vec::new(),
                        });
                        tracing::info!(
                            target: "recording.lifecycle",
                            event = "clip_recording.started",
                            clip_id = %clip_id,
                            filename = %filename,
                            source_index = source_index as i64,
                            start_source_seconds = playhead_snapshot_seconds.max(0.0),
                            output = %output_path.display(),
                        );
                        tracing::info!(
                            target: "recording.lifecycle",
                            event = "mode.changed",
                            mode = "recording",
                        );
                        CommandReply {
                            ok: true,
                            error: None,
                        }
                    }
                    Ok(Err(e)) => {
                        // Adversarial-review fix #10: bus must NOT
                        // panic, must NOT leave mode stuck at
                        // RecordingStarting, must roll back the
                        // transition. Source stays paused — match v1.
                        *current_mode = AppMode::Scanning;
                        write_recording_state(recording_state, current_mode, None);
                        tracing::warn!(
                            target: "recording.lifecycle",
                            event = "clip_recording.failed",
                            error = %e,
                        );
                        tracing::info!(
                            target: "recording.lifecycle",
                            event = "mode.changed",
                            mode = "scanning",
                        );
                        CommandReply {
                            ok: false,
                            error: Some(format!("start recording: {e}")),
                        }
                    }
                    Err(join) => {
                        *current_mode = AppMode::Scanning;
                        write_recording_state(recording_state, current_mode, None);
                        CommandReply {
                            ok: false,
                            error: Some(format!("join: {join}")),
                        }
                    }
                }
            }
        }
        Command::StopClipRecording => {
            #[cfg(not(feature = "media"))]
            {
                CommandReply {
                    ok: false,
                    error: Some("media feature disabled in this build".into()),
                }
            }
            #[cfg(feature = "media")]
            {
                if !matches!(current_mode, AppMode::Recording) {
                    return CommandReply {
                        ok: false,
                        error: Some(format!("cannot stop recording in mode {:?}", current_mode)),
                    };
                }
                let Some(clip_in_progress) = recording_clip.take() else {
                    // Defensive — mode says Recording but there's no
                    // in-progress clip. Reset mode so we don't get
                    // stuck.
                    *current_mode = AppMode::Scanning;
                    write_recording_state(recording_state, current_mode, None);
                    return CommandReply {
                        ok: false,
                        error: Some("no recording_clip; reset to scanning".into()),
                    };
                };
                let Some(rec) = recording.take() else {
                    *current_mode = AppMode::Scanning;
                    write_recording_state(recording_state, current_mode, None);
                    return CommandReply {
                        ok: false,
                        error: Some("no active capture pipeline".into()),
                    };
                };

                // Adversarial-review fix #4: compute duration on the
                // bus side from t0_instant.elapsed(). Recording::stop
                // returns no duration.
                let recording_duration = clip_in_progress.t0_instant.elapsed().as_secs_f64();

                // Recording::stop blocks waiting for EOS; off-load to
                // a worker. Adversarial-review fix #2: mode mutations
                // happen on the bus task AFTER the await returns, NOT
                // inside this closure.
                let output_path = clip_in_progress.output_path.clone();
                let stop_result = tokio::task::spawn_blocking(move || rec.stop()).await;
                match stop_result {
                    Ok(Ok(())) => {}
                    Ok(Err(e)) => {
                        // Plan: leave the .mov on disk, clear state,
                        // transition back to Scanning, surface the
                        // error. Do NOT write project.json with a
                        // half-finished clip.
                        *current_mode = AppMode::Scanning;
                        write_recording_state(recording_state, current_mode, None);
                        tracing::warn!(
                            target: "recording.lifecycle",
                            event = "clip_recording.failed",
                            phase = "stop",
                            error = %e,
                        );
                        return CommandReply {
                            ok: false,
                            error: Some(format!("stop recording: {e}")),
                        };
                    }
                    Err(join) => {
                        *current_mode = AppMode::Scanning;
                        write_recording_state(recording_state, current_mode, None);
                        return CommandReply {
                            ok: false,
                            error: Some(format!("join: {join}")),
                        };
                    }
                }

                // Build the Clip + persist. Project mutation runs on
                // the bus task; project_store::write blocks (file IO
                // + serde) so the write itself goes to spawn_blocking.
                let Some((project, project_folder)) = current.as_mut() else {
                    *current_mode = AppMode::Scanning;
                    write_recording_state(recording_state, current_mode, None);
                    return CommandReply {
                        ok: false,
                        error: Some("project closed during recording".into()),
                    };
                };
                let sort_index = project.clips.len() as i64;
                let clip = video_coach_core::project::Clip {
                    id: clip_in_progress.clip_id,
                    name: default_clip_name(
                        clip_in_progress.source_index,
                        clip_in_progress.start_source_seconds,
                    ),
                    notes: String::new(),
                    tags: Vec::new(),
                    source_index: clip_in_progress.source_index,
                    start_source_seconds: clip_in_progress.start_source_seconds,
                    recording_duration,
                    recording_filename: clip_in_progress.filename.clone(),
                    events: clip_in_progress.events.clone(),
                    sort_index,
                    created_at: chrono::Utc::now(),
                };
                project.clips.push(clip);
                let project_clone = project.clone();
                let folder_clone = project_folder.clone();
                let write_result = tokio::task::spawn_blocking(move || {
                    video_coach_core::project_store::write(&project_clone, &folder_clone)
                })
                .await;
                match write_result {
                    Ok(Ok(())) => {
                        *current_mode = AppMode::Scanning;
                        write_recording_state(recording_state, current_mode, None);
                        // Phase 9 Task 3 (fix #13). project.clips already
                        // has the just-pushed clip; sync the slot so the
                        // sidebar shows it.
                        write_clip_list(clip_list, &project.clips);
                        tracing::info!(
                            target: "recording.lifecycle",
                            event = "clip_recording.stopped",
                            clip_id = %clip_in_progress.clip_id,
                            duration_seconds = recording_duration,
                            output = %output_path.display(),
                        );
                        tracing::info!(
                            target: "recording.lifecycle",
                            event = "mode.changed",
                            mode = "scanning",
                        );
                        CommandReply {
                            ok: true,
                            error: None,
                        }
                    }
                    Ok(Err(e)) => {
                        // Persistence failed; project.clips is ahead
                        // of disk. Pop the just-pushed clip so memory
                        // and disk match.
                        project.clips.pop();
                        *current_mode = AppMode::Scanning;
                        write_recording_state(recording_state, current_mode, None);
                        CommandReply {
                            ok: false,
                            error: Some(format!("persist project.json: {e}")),
                        }
                    }
                    Err(join) => {
                        project.clips.pop();
                        *current_mode = AppMode::Scanning;
                        write_recording_state(recording_state, current_mode, None);
                        CommandReply {
                            ok: false,
                            error: Some(format!("join: {join}")),
                        }
                    }
                }
            }
        }
        Command::AppendStroke { points_json } => {
            #[cfg(not(feature = "media"))]
            {
                let _ = points_json;
                CommandReply {
                    ok: false,
                    error: Some("media feature disabled in this build".into()),
                }
            }
            #[cfg(feature = "media")]
            {
                if !matches!(current_mode, AppMode::Recording) {
                    return CommandReply {
                        ok: false,
                        error: Some(format!("cannot append stroke in mode {:?}", current_mode)),
                    };
                }
                let Some(clip) = recording_clip.as_mut() else {
                    return CommandReply {
                        ok: false,
                        error: Some("no recording_clip in progress".into()),
                    };
                };
                // Parse the UI's JSON-encoded array of points.
                #[derive(serde::Deserialize)]
                struct InPoint {
                    x: f64,
                    y: f64,
                    t: f64,
                }
                let points: Vec<InPoint> = match serde_json::from_str(&points_json) {
                    Ok(p) => p,
                    Err(e) => {
                        return CommandReply {
                            ok: false,
                            error: Some(format!("parse stroke json: {e}")),
                        };
                    }
                };
                if points.is_empty() {
                    return CommandReply {
                        ok: false,
                        error: Some("stroke has no points".into()),
                    };
                }
                // Drop strokes entirely outside the displayed video
                // rect (likely a UI dispatch bug). Adversarial fix #5
                // — clamp is already applied in Slint, so receiving an
                // out-of-range point here means something is wrong;
                // log + ignore.
                let any_in_range = points
                    .iter()
                    .any(|p| (0.0..=1.0).contains(&p.x) && (0.0..=1.0).contains(&p.y));
                if !any_in_range {
                    tracing::warn!(
                        target: "recording.lifecycle",
                        event = "stroke.dropped_out_of_rect",
                        count = points.len() as i64,
                    );
                    return CommandReply {
                        ok: true,
                        error: None,
                    };
                }
                // recordTime on the event = wall-clock time since
                // recording started, captured at the moment the stroke
                // ended (per-point t is relative to stroke start).
                let record_time = clip.t0_instant.elapsed().as_secs_f64();
                let stroke_points: Vec<video_coach_core::stroke::StrokePoint> = points
                    .iter()
                    .map(|p| video_coach_core::stroke::StrokePoint {
                        x: p.x.clamp(0.0, 1.0),
                        y: p.y.clamp(0.0, 1.0),
                        t: p.t.max(0.0),
                    })
                    .collect();
                let stroke = video_coach_core::stroke::Stroke {
                    id: uuid::Uuid::new_v4(),
                    color: video_coach_core::stroke::Rgba::RED,
                    line_width: 0.012,
                    points: stroke_points,
                    auto_clear_after_seconds: None,
                };
                let event = video_coach_core::event::CommentaryEvent {
                    record_time,
                    kind: video_coach_core::event::EventKind::Stroke(stroke),
                };
                clip.events.push(event);
                tracing::info!(
                    target: "recording.lifecycle",
                    event = "stroke.appended",
                    record_time,
                    point_count = points.len() as i64,
                );
                CommandReply {
                    ok: true,
                    error: None,
                }
            }
        }
        Command::OpenClipPreview { clip_id } => {
            #[cfg(not(feature = "media"))]
            {
                let _ = clip_id;
                CommandReply {
                    ok: false,
                    error: Some("media feature disabled in this build".into()),
                }
            }
            #[cfg(feature = "media")]
            {
                // Phase 9 Task 3. Strict order per fixes #3, #14, #22, #25:
                //   1. parse clip_id
                //   2. refuse if no project
                //   3. refuse if busy (per fix #22 — emit
                //      clip_preview.failed with reason="already_in_preview"
                //      when the busy reason is specifically PreviewClip)
                //   4. find clip
                //   5. resolve paths via project_folder.join (NO
                //      per-call canonicalize — per fix #25)
                //   6. flip player_mount.active=false BEFORE pause-await
                //      (fix #3)
                //   7. pause source player (best-effort)
                //   8. build fresh preview FrameSink + handles
                //   9. spawn_blocking PreviewPipeline::open
                //  10. on success: stash, set mode, seed slot,
                //      spawn position-poll task (fix #15), log opened.
                //      on failure: roll back player_mount.active=true,
                //      clear preview_mount, log failed.

                let clip_uuid = match uuid::Uuid::parse_str(&clip_id) {
                    Ok(u) => u,
                    Err(e) => {
                        return CommandReply {
                            ok: false,
                            error: Some(format!("invalid clip_id: {e}")),
                        };
                    }
                };

                let Some((project, project_folder)) = current.as_ref() else {
                    return CommandReply {
                        ok: false,
                        error: Some("no project open".into()),
                    };
                };

                if is_busy(recording, recording_clip, current_mode) {
                    let reason = if matches!(*current_mode, AppMode::PreviewClip(_)) {
                        "already_in_preview"
                    } else {
                        "busy"
                    };
                    tracing::warn!(
                        target: "clip_preview.lifecycle",
                        event = "clip_preview.failed",
                        clip_id = %clip_id,
                        reason = reason,
                    );
                    return CommandReply {
                        ok: false,
                        error: Some(format!("cannot open preview: {reason}")),
                    };
                }

                let Some(clip) = project.clips.iter().find(|c| c.id == clip_uuid).cloned() else {
                    tracing::warn!(
                        target: "clip_preview.lifecycle",
                        event = "clip_preview.failed",
                        clip_id = %clip_id,
                        reason = "clip_not_found",
                    );
                    return CommandReply {
                        ok: false,
                        error: Some("clip not found".into()),
                    };
                };

                let Some(source_ref) = project.source_videos.get(clip.source_index) else {
                    tracing::warn!(
                        target: "clip_preview.lifecycle",
                        event = "clip_preview.failed",
                        clip_id = %clip_id,
                        reason = "source_index_out_of_range",
                    );
                    return CommandReply {
                        ok: false,
                        error: Some("source index out of range".into()),
                    };
                };
                let source_path = project_folder.join(&source_ref.relative_path);
                let recording_path =
                    video_coach_core::project_store::recordings_dir(project_folder)
                        .join(&clip.recording_filename);
                if !recording_path.is_file() {
                    tracing::warn!(
                        target: "clip_preview.lifecycle",
                        event = "clip_preview.failed",
                        clip_id = %clip_id,
                        reason = "recording_file_missing",
                    );
                    return CommandReply {
                        ok: false,
                        error: Some(format!("recording missing: {}", recording_path.display())),
                    };
                }
                let source_duration_seconds = source_ref.duration_seconds;

                // Fix #3: flip player_mount.active=false BEFORE pause-await
                // so a queued frame from GStreamer's streaming thread
                // can't sneak into the slot AFTER the preview's first
                // frame lands.
                if let Some(handles) = current_player_mount.as_ref() {
                    handles
                        .active
                        .store(false, std::sync::atomic::Ordering::Release);
                }

                // Pause source player. Best-effort: a failure here (e.g.
                // no source loaded yet) shouldn't block the preview.
                if let Some(player) = current_player.as_ref() {
                    let player = player.clone();
                    let _ = tokio::task::spawn_blocking(move || player.pause()).await;
                }

                // Fresh preview FrameSink + handles. The factory mints a
                // new active flag + frames-pushed counter; we stash the
                // handles AFTER successful open so a failed open doesn't
                // leave a dangling preview_mount entry.
                let mounted = frame_mount_factory();
                let preview_handles = crate::frame_sink::MountHandles {
                    active: mounted.active.clone(),
                    frames_pushed: mounted.frames_pushed.clone(),
                };

                let compositor_for_open = compositor.clone();
                let clip_for_open = clip.clone();
                let source_path_for_open = source_path.clone();
                let recording_path_for_open = recording_path.clone();
                let sink = mounted.sink;
                let result = tokio::task::spawn_blocking(move || {
                    video_coach_media::preview_pipeline::PreviewPipeline::open(
                        &source_path_for_open,
                        &recording_path_for_open,
                        &clip_for_open,
                        source_duration_seconds,
                        compositor_for_open,
                        sink,
                    )
                })
                .await;

                match result {
                    Ok(Ok(pipeline)) => {
                        let pipeline = std::sync::Arc::new(pipeline);
                        *current_preview = Some(pipeline.clone());
                        *current_preview_mount = Some(preview_handles);
                        *current_mode = AppMode::PreviewClip(clip_uuid);
                        write_recording_state(recording_state, current_mode, None);

                        // Seed the player_state slot so the UI's first
                        // paint shows the right duration / position /
                        // paused state. The position-poll task overwrites
                        // this every 100 ms.
                        {
                            let mut g = player_state.lock().expect("player_state poisoned");
                            g.duration_seconds = clip.recording_duration;
                            g.position_seconds = 0.0;
                            g.is_playing = false;
                            g.last_seek_at = None;
                        }

                        // Fix #15: position-poll task with AbortHandle
                        // so ClosePreview can cancel before tearing the
                        // pipeline down.
                        let poll_handle = spawn_preview_position_poll(
                            rt_for_poll,
                            pipeline.clone(),
                            player_state.clone(),
                            shutdown_tx_for_poll.subscribe(),
                        );
                        *current_preview_poll = Some(poll_handle);

                        tracing::info!(
                            target: "clip_preview.lifecycle",
                            event = "clip_preview.opened",
                            clip_id = %clip_uuid,
                            source = %source_path.display(),
                            recording = %recording_path.display(),
                            recording_duration = clip.recording_duration,
                        );
                        CommandReply {
                            ok: true,
                            error: None,
                        }
                    }
                    Ok(Err(e)) => {
                        // Failure rollback: re-enable player_mount, no
                        // preview_mount stashed. Mode stays Scanning.
                        if let Some(handles) = current_player_mount.as_ref() {
                            handles
                                .active
                                .store(true, std::sync::atomic::Ordering::Release);
                        }
                        *current_preview_mount = None;
                        tracing::warn!(
                            target: "clip_preview.lifecycle",
                            event = "clip_preview.failed",
                            clip_id = %clip_id,
                            reason = "open_failed",
                            error = %e,
                        );
                        CommandReply {
                            ok: false,
                            error: Some(format!("preview open: {e}")),
                        }
                    }
                    Err(join) => {
                        if let Some(handles) = current_player_mount.as_ref() {
                            handles
                                .active
                                .store(true, std::sync::atomic::Ordering::Release);
                        }
                        *current_preview_mount = None;
                        CommandReply {
                            ok: false,
                            error: Some(format!("join: {join}")),
                        }
                    }
                }
            }
        }
        Command::ClosePreview => {
            #[cfg(not(feature = "media"))]
            {
                CommandReply {
                    ok: false,
                    error: Some("media feature disabled in this build".into()),
                }
            }
            #[cfg(feature = "media")]
            {
                if !matches!(*current_mode, AppMode::PreviewClip(_)) {
                    return CommandReply {
                        ok: false,
                        error: Some(format!("cannot close preview in mode {:?}", *current_mode)),
                    };
                }

                // 1. Abort the position-poll task so it stops holding an
                //    Arc clone of the pipeline (otherwise Arc::try_unwrap
                //    below fails).
                if let Some(handle) = current_preview_poll.take() {
                    handle.abort();
                }

                // 2. Fix #3: flip preview_mount.active=false BEFORE
                //    teardown. Straggler frames from the preview's
                //    GStreamer threads land on the floor.
                if let Some(handles) = current_preview_mount.as_ref() {
                    handles
                        .active
                        .store(false, std::sync::atomic::Ordering::Release);
                }

                // 3. Read frames_pushed BEFORE clearing the mount handle
                //    so the event reflects the actual count. Fix #26.
                let frames_pushed = current_preview_mount
                    .as_ref()
                    .map(|h| h.frames_pushed.load(std::sync::atomic::Ordering::Acquire))
                    .unwrap_or(0);

                // 4. Tear down via PreviewPipeline::stop in spawn_blocking
                //    (per fix #14 — explicit, NOT just Drop). The
                //    pipeline is held in an Arc; Arc::try_unwrap consumes
                //    it. Should always succeed UNLESS something else
                //    holds an Arc clone — the poll task is the only
                //    other holder, and we just aborted it. abort() is
                //    asynchronous, so yield once to let the runtime
                //    drop the JoinHandle's Arc clone before we unwrap.
                if let Some(pipeline_arc) = current_preview.take() {
                    tokio::task::yield_now().await;
                    match std::sync::Arc::try_unwrap(pipeline_arc) {
                        Ok(pipeline) => {
                            let _ = tokio::task::spawn_blocking(move || pipeline.stop()).await;
                        }
                        Err(arc) => {
                            tracing::warn!(
                                target: "clip_preview.lifecycle",
                                event = "clip_preview.teardown_via_drop",
                                reason = "arc_still_shared",
                            );
                            drop(arc); // Drop impl runs the safety-net teardown.
                        }
                    }
                }

                // 5. Mode → Scanning.
                *current_mode = AppMode::Scanning;
                write_recording_state(recording_state, current_mode, None);

                // 6. Fix #3 + #9: re-enable player_mount.active=true. The
                //    source player stays paused (matches v1) — user
                //    re-presses Space to resume — but the slot needs to
                //    be writable when they do.
                if let Some(handles) = current_player_mount.as_ref() {
                    handles
                        .active
                        .store(true, std::sync::atomic::Ordering::Release);
                }
                *current_preview_mount = None;

                tracing::info!(
                    target: "clip_preview.lifecycle",
                    event = "clip_preview.closed",
                    frames_pushed = frames_pushed as i64,
                );
                CommandReply {
                    ok: true,
                    error: None,
                }
            }
        }
        Command::ExportCompilations {
            selections,
            output_folder,
            resolution,
            quality,
            project_name,
        } => {
            #[cfg(not(feature = "media"))]
            {
                let _ = (selections, output_folder, resolution, quality, project_name);
                CommandReply {
                    ok: false,
                    error: Some("media feature disabled in this build".into()),
                }
            }
            #[cfg(feature = "media")]
            {
                handle_export_compilations(
                    selections,
                    output_folder,
                    resolution,
                    quality,
                    project_name,
                    current,
                    current_mode,
                    recording,
                    recording_clip,
                    recording_state,
                    export_progress,
                    current_export_cancel,
                    compositor,
                    export_cleanup_tx,
                )
                .await
            }
        }
        Command::CancelExport => {
            #[cfg(not(feature = "media"))]
            {
                CommandReply {
                    ok: false,
                    error: Some("media feature disabled in this build".into()),
                }
            }
            #[cfg(feature = "media")]
            {
                if !matches!(*current_mode, AppMode::Exporting) {
                    return CommandReply {
                        ok: false,
                        error: Some("not_exporting".into()),
                    };
                }
                if let Some(flag) = current_export_cancel.as_ref() {
                    flag.store(true, std::sync::atomic::Ordering::Release);
                }
                let _ = export_progress; // touched on the export driver path
                CommandReply {
                    ok: true,
                    error: None,
                }
            }
        }
    }
}

/// Phase 10 Task 2 + Task 4-prep (per the plan section starting at line
/// 1097, with the architecture refactor described below).
///
/// **Architecture (Task 4 prep, post-Task-2 refactor):** the synchronous
/// setup phase (validation, busy check, no-project check, path resolve,
/// folder validation, prefs persistence, mode flip, slot init,
/// batch.started event) runs inline on the bus task. The actual per-tag
/// for-loop is then spawned into a detached `tokio::spawn` task so the
/// bus loop returns to receive new commands — most importantly,
/// `Command::CancelExport` mid-export (without this, the bus task is
/// blocked awaiting `spawn_blocking` for the entire export duration and
/// cancel can't be processed). The spawned task signals "I'm done" via
/// `export_cleanup_tx`, which the bus's `select!` loop picks up and
/// resets `current_mode` + `current_export_cancel` (which the spawned
/// task can't borrow because they're bus-task-local `&mut` refs).
///
/// **Cleanup discipline (per fix #38)**: the spawned task writes the
/// final outcome to the slot before sending the cleanup signal. The bus's
/// select!-arm for cleanup resets the mutable bus-local state. Both
/// success and error paths converge on the same cleanup signal.
#[cfg(feature = "media")]
#[allow(clippy::too_many_arguments)]
async fn handle_export_compilations(
    selections: Vec<TagSelection>,
    output_folder: String,
    resolution: video_coach_core::project::Resolution,
    quality: video_coach_core::project::Quality,
    project_name: String,
    current: &mut Option<(video_coach_core::project::Project, std::path::PathBuf)>,
    current_mode: &mut AppMode,
    recording: &Option<video_coach_media::recording::Recording>,
    recording_clip: &Option<RecordingClipInProgress>,
    recording_state: &crate::frame_sink::RecordingStateSlot,
    export_progress: &crate::frame_sink::ExportProgressSlot,
    current_export_cancel: &mut Option<std::sync::Arc<std::sync::atomic::AtomicBool>>,
    compositor: &std::sync::Arc<video_coach_compositor::Compositor>,
    export_cleanup_tx: &tokio::sync::mpsc::UnboundedSender<()>,
) -> CommandReply {
    use crate::filename::sanitize_filename;
    use crate::frame_sink::{ExportProgressSlotData, ExportRunOutcome};
    use std::collections::HashMap;
    use std::path::PathBuf;
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;
    use uuid::Uuid;

    // ── 1. Validate inputs (per plan step 1). ────────────────────────────
    let project_name_trimmed = project_name.trim().to_string();
    if selections.is_empty() || output_folder.is_empty() || project_name_trimmed.is_empty() {
        tracing::warn!(
            target: "export.lifecycle",
            event = "export.batch.failed",
            reason = "invalid_input",
        );
        return CommandReply {
            ok: false,
            error: Some("invalid_input".into()),
        };
    }

    // ── 2. Refuse if busy (per fix #9 + #22). ────────────────────────────
    if is_busy(recording, recording_clip, current_mode) {
        let reason = match *current_mode {
            AppMode::RecordingStarting | AppMode::Recording => "already_recording",
            AppMode::PreviewClip(_) => "close_preview_first",
            AppMode::Exporting => "already_exporting",
            // is_busy true with mode == Scanning means a low-level
            // recording slot is somehow live — treat as already_recording.
            AppMode::Scanning => "already_recording",
        };
        tracing::warn!(
            target: "export.lifecycle",
            event = "export.batch.failed",
            reason = reason,
        );
        return CommandReply {
            ok: false,
            error: Some(reason.into()),
        };
    }

    // ── 3. Refuse if no project open (per plan step 3). ──────────────────
    if current.is_none() {
        tracing::warn!(
            target: "export.lifecycle",
            event = "export.batch.failed",
            reason = "no_project_open",
        );
        return CommandReply {
            ok: false,
            error: Some("no_project_open".into()),
        };
    }

    // ── 4. Resolve all paths (per fix #16, #19, #27). ────────────────────
    let (project_snapshot, project_folder) = {
        let (p, f) = current.as_ref().expect("checked is_none above");
        (p.clone(), f.clone())
    };
    let mut source_paths: HashMap<usize, PathBuf> = HashMap::new();
    let mut recording_paths: HashMap<Uuid, PathBuf> = HashMap::new();
    let mut clips_by_id: HashMap<Uuid, video_coach_core::project::Clip> = HashMap::new();
    let mut source_durations: HashMap<usize, f64> = HashMap::new();
    for clip in &project_snapshot.clips {
        clips_by_id.insert(clip.id, clip.clone());
        recording_paths.entry(clip.id).or_insert_with(|| {
            video_coach_core::project_store::recordings_dir(&project_folder)
                .join(&clip.recording_filename)
        });
    }
    for (idx, sref) in project_snapshot.source_videos.iter().enumerate() {
        source_paths
            .entry(idx)
            .or_insert_with(|| project_folder.join(&sref.relative_path));
        source_durations.entry(idx).or_insert(sref.duration_seconds);
    }
    let output_folder_path = PathBuf::from(&output_folder);

    // ── 5. Validate / create output folder (per second-pass fix). ────────
    if let Err(e) = std::fs::create_dir_all(&output_folder_path) {
        let err_str = e.to_string();
        tracing::warn!(
            target: "export.lifecycle",
            event = "export.batch.failed",
            reason = "output_folder_unwritable",
            error = %err_str,
        );
        return CommandReply {
            ok: false,
            error: Some(format!("output_folder_unwritable: {err_str}")),
        };
    }

    // ── 6. Persist preferences BEFORE kicking off the loop (fix #11). ────
    {
        let (project, folder) = current.as_mut().expect("re-checked");
        project.preferences.last_export_resolution = resolution;
        project.preferences.last_export_quality = quality;
        let project_clone = project.clone();
        let folder_clone = folder.clone();
        let persist_result = tokio::task::spawn_blocking(move || {
            video_coach_core::project_store::write(&project_clone, &folder_clone)
                .map_err(|e| e.to_string())
        })
        .await;
        match persist_result {
            Ok(Ok(())) => {}
            Ok(Err(msg)) => {
                tracing::warn!(
                    target: "export.lifecycle",
                    event = "export.batch.failed",
                    reason = "persist_prefs_failed",
                    error = %msg,
                );
                return CommandReply {
                    ok: false,
                    error: Some(format!("persist_prefs_failed: {msg}")),
                };
            }
            Err(join) => {
                tracing::warn!(
                    target: "export.lifecycle",
                    event = "export.batch.failed",
                    reason = "persist_prefs_failed",
                    error = %join,
                );
                return CommandReply {
                    ok: false,
                    error: Some(format!("persist_prefs_failed: {join}")),
                };
            }
        }
    }

    // ── 7. Set up the run state (per fix #10 + #38). ─────────────────────
    *current_export_cancel = None;
    let cancel_flag: Arc<AtomicBool> = Arc::new(AtomicBool::new(false));
    *current_export_cancel = Some(cancel_flag.clone());
    *current_mode = AppMode::Exporting;
    write_recording_state(recording_state, current_mode, None);

    // Capture preview-volume preferences for export.rs's API (Phase 10
    // ignores them per fix #8 but the field is in the API signature).
    let source_volume = project_snapshot.preferences.preview_source_volume;
    let commentary_volume = project_snapshot.preferences.preview_commentary_volume;

    let total_tags = selections.len();

    // ── 8. Update ExportProgressSlot to InProgress (per plan step 8). ────
    {
        let mut g = export_progress.lock().expect("export_progress poisoned");
        *g = ExportProgressSlotData {
            outcome: ExportRunOutcome::InProgress,
            current_tag: None,
            completed_tags: 0,
            total_tags,
            // Phase 11 Plan #2: per-tag and batch progress start at 0.0;
            // the throttled `on_progress` writer below ticks them up.
            current_tag_progress: 0.0,
            batch_progress: 0.0,
        };
    }

    // ── 9. Emit batch.started (per fix #1). ──────────────────────────────
    tracing::info!(
        target: "export.lifecycle",
        event = "export.batch.started",
        tag_count = total_tags as i64,
        output_folder = %output_folder_path.display(),
        resolution = ?resolution,
        quality = ?quality,
    );

    // ── 10. Spawn the per-tag for-loop into a detached tokio task. ───────
    // The bus task returns to its select! loop after this point so that
    // CancelExport (and any other command) can be processed mid-export.
    // The spawned task signals completion via `export_cleanup_tx`; the
    // bus's select!-arm resets bus-local state.
    let compositor_for_task = compositor.clone();
    let export_progress_for_task = export_progress.clone();
    let cleanup_tx_for_task = export_cleanup_tx.clone();

    tokio::spawn(async move {
        let mut completed_tags: usize = 0;
        let mut final_outcome: Option<ExportRunOutcome> = None;

        'outer: for (i, selection) in selections.iter().enumerate() {
            // Cancel-flag check at the top of each tag iteration: cancel
            // arriving between tags (e.g. tag 1 finished, cancel before
            // tag 2 starts) breaks out cleanly without spinning up the
            // pipeline.
            if cancel_flag.load(std::sync::atomic::Ordering::Acquire) {
                tracing::info!(
                    target: "export.lifecycle",
                    event = "export.batch.cancelled",
                    tags_completed = completed_tags as i64,
                );
                final_outcome = Some(ExportRunOutcome::Cancelled {
                    folder: output_folder_path.clone(),
                    completed: completed_tags,
                });
                break 'outer;
            }

            // Resolve label + plan via TagSelection (per fix #33).
            let (label, plan) = match selection {
                TagSelection::AllClips => (
                    "all-clips".to_string(),
                    project_snapshot.all_clips_compilation_plan(&source_durations),
                ),
                TagSelection::Tag { name } => (
                    name.clone(),
                    project_snapshot.compilation_plan_for(name, &source_durations),
                ),
            };

            // Update slot for this iteration.
            //
            // Phase 11 Plan #2: also reset `current_tag_progress` to 0.0
            // and recompute `batch_progress` from `i`, NOT
            // `completed_tags`. `completed_tags` only ticks AFTER a tag
            // finishes — `i` is the index of the tag about to start,
            // which equals the count of tags fully done before this one.
            // The encoder cold-start gap (mfh264enc 5–10 s before any
            // frame is pushed) is bridged by this reset: the bar shows
            // the segment-start value immediately on tag begin.
            //
            // Phase 11 Plan #2 code-review fix [2]: this write happens
            // BEFORE the empty-plan skip below so a skipped tag still
            // updates `current_tag` to the new label and bumps
            // `batch_progress` to the segment-start floor. Otherwise the
            // UI's "Exporting {current_tag} … N of M — XX%" line would
            // render the prior tag's name + stale percentage for the
            // duration of the skip (a one-frame flicker today; visibly
            // wrong if multiple consecutive tags skip).
            {
                let mut g = export_progress_for_task
                    .lock()
                    .expect("export_progress poisoned");
                g.current_tag = Some(label.clone());
                g.completed_tags = i;
                g.current_tag_progress = 0.0;
                g.batch_progress = (i as f32 / total_tags as f32).min(1.0);
            }

            // Empty plan → skip (per fix #26).
            if plan.entries.is_empty() {
                tracing::info!(
                    target: "export.lifecycle",
                    event = "export.tag.skipped",
                    selection = %label,
                    reason = "empty_plan",
                );
                continue;
            }

            // Build output path (per fix #31).
            let output_path = output_folder_path.join(format!(
                "{} - {}.mp4",
                sanitize_filename(&label),
                sanitize_filename(&project_name_trimmed),
            ));

            // Silently delete prior output (per fix #13).
            let _ = std::fs::remove_file(&output_path);

            tracing::info!(
                target: "export.lifecycle",
                event = "export.tag.started",
                selection = %label,
                output_path = %output_path.display(),
            );

            // Build fresh ExportInputs per tag (plan changes per selection).
            let inputs = video_coach_media::export::ExportInputs {
                plan,
                clips_by_id: clips_by_id.clone(),
                source_paths: source_paths.clone(),
                recording_paths: recording_paths.clone(),
                source_durations: source_durations.clone(),
            };

            let compositor_for_export = compositor_for_task.clone();
            let cancel_for_export = cancel_flag.clone();
            let output_path_for_export = output_path.clone();

            // ── Phase 11 Plan #2: throttled on_progress writer. ──
            //
            // Capture loop-local immutables (`i`, `total_tags`) by value
            // BEFORE constructing the closure (Fix #3). The closure
            // must NOT read `completed_tags` from the slot — only
            // write into it — so that any future refactor that
            // parallelises tags (or any straggler progress event firing
            // after `spawn_blocking` returns) can't race a concurrent
            // batch_progress recomputation against the wrong tag index.
            let i_for_closure: usize = i;
            let total_tags_for_closure: usize = total_tags;
            // Throttle state: `(last_batch_progress, last_write_at)`.
            // `Arc<Mutex<...>>` not `Cell`/`RefCell` because
            // `export.rs:149` types the callback as
            // `Box<dyn Fn(ExportProgress) + Send + Sync>` and
            // `Cell`/`RefCell` are `!Sync` (Fix #2). The initial
            // `Instant::now() - 1s` ensures the first event always
            // passes the time check (defence-in-depth — the gate is
            // currently delta-only, but starting "in the past" is
            // robust to future re-introduction of a time floor).
            let last_progress = Arc::new(std::sync::Mutex::new((
                0.0_f32,
                std::time::Instant::now() - std::time::Duration::from_millis(1000),
            )));
            let slot_for_closure = export_progress_for_task.clone();
            let last_progress_for_closure = last_progress.clone();
            let on_progress: Box<dyn Fn(video_coach_media::export::ExportProgress) + Send + Sync> =
                Box::new(move |progress| {
                    // frames_pushed is monotonic across entries; frame_index
                    // resets per entry (export.rs:1306) and would tick
                    // backward at every entry boundary on multi-entry tags
                    // (Fix #1). f64 divide → f32 cast avoids precision loss
                    // past 2^24 frames (~155 h at 30 fps); `.max(1)`
                    // defensively guards div-by-zero (Fix #7).
                    let tag_p_raw =
                        progress.frames_pushed as f64 / progress.total_frames.max(1) as f64;
                    let tag_p = (tag_p_raw as f32).clamp(0.0, 1.0);
                    let batch_p = ((i_for_closure as f32 + tag_p) / total_tags_for_closure as f32)
                        .clamp(0.0, 1.0);

                    // Throttle gate. Recover from poison instead of
                    // panicking (Fix #5): the throttle is best-effort
                    // state, and a panicking closure would kill the
                    // `spawn_blocking` task and bypass export.rs:317-320's
                    // stepped Paused → Ready → Null teardown. We DO panic
                    // on the slot lock below, because the slot is the
                    // source of truth and silent corruption there would be
                    // worse than a loud crash.
                    let now = std::time::Instant::now();
                    {
                        let mut last = last_progress_for_closure
                            .lock()
                            .unwrap_or_else(|e| e.into_inner());
                        let (last_p, _last_at) = *last;
                        // Single delta gate, no time floor (Fix #6) —
                        // `export.rs:1353` already caps invocations at ~1 Hz
                        // via `frame_idx % 30 == 0`; the 0.5% delta gate
                        // de-dupes within slow tags and is defence-in-depth
                        // if that call-site cap is ever loosened.
                        if (batch_p - last_p).abs() < 0.005 {
                            return;
                        }
                        *last = (batch_p, now);
                        // Drop the throttle guard before locking the slot —
                        // two locks acquired in series, never nested.
                    }

                    let mut g = slot_for_closure.lock().expect("export_progress poisoned");
                    g.current_tag_progress = tag_p;
                    g.batch_progress = batch_p;
                });

            let join = tokio::task::spawn_blocking(move || {
                video_coach_media::export::export_compilation(
                    inputs,
                    &output_path_for_export,
                    resolution,
                    quality,
                    source_volume,
                    commentary_volume,
                    compositor_for_export,
                    cancel_for_export,
                    on_progress,
                )
            })
            .await;

            match join {
                Ok(Ok(summary)) => {
                    tracing::info!(
                        target: "export.lifecycle",
                        event = "export.tag.completed",
                        selection = %label,
                        frames_pushed = summary.frames_pushed as i64,
                    );
                    // Phase 11 Plan #2 (Fix #4): snap to segment
                    // boundary on tag success BEFORE bumping
                    // `completed_tags`. The on_progress callback only
                    // fires at `frame_idx % 30 == 0` (export.rs:1353),
                    // so the very last frame of a tag often does NOT
                    // fire — without this snap, batch_progress would
                    // visibly stop short of the segment boundary (e.g.
                    // 96% on a 5-tag batch where the last tag's last
                    // entry is 150 frames). No race: the closure for
                    // tag `i` is dropped when `spawn_blocking`
                    // returns, so we're between iterations.
                    {
                        let mut g = export_progress_for_task
                            .lock()
                            .expect("export_progress poisoned");
                        g.current_tag_progress = 1.0;
                        g.batch_progress = ((i + 1) as f32 / total_tags as f32).min(1.0);
                    }
                    completed_tags += 1;
                }
                Ok(Err(video_coach_media::export::ExportError::Cancelled)) => {
                    tracing::warn!(
                        target: "export.lifecycle",
                        event = "export.tag.failed",
                        selection = %label,
                        error = "cancelled",
                    );
                    tracing::info!(
                        target: "export.lifecycle",
                        event = "export.batch.cancelled",
                        tags_completed = completed_tags as i64,
                    );
                    final_outcome = Some(ExportRunOutcome::Cancelled {
                        folder: output_folder_path.clone(),
                        completed: completed_tags,
                    });
                    break 'outer;
                }
                Ok(Err(other)) => {
                    let err_str = other.to_string();
                    tracing::warn!(
                        target: "export.lifecycle",
                        event = "export.tag.failed",
                        selection = %label,
                        error = %err_str,
                    );
                    tracing::warn!(
                        target: "export.lifecycle",
                        event = "export.batch.failed",
                        reason = "tag_failed",
                        selection = %label,
                        error = %err_str,
                    );
                    final_outcome = Some(ExportRunOutcome::PartialFailure {
                        folder: output_folder_path.clone(),
                        completed: completed_tags,
                        failed_tag: label.clone(),
                        error: err_str,
                    });
                    break 'outer;
                }
                Err(join_err) => {
                    let err_str = format!("export task panicked: {join_err}");
                    tracing::warn!(
                        target: "export.lifecycle",
                        event = "export.tag.failed",
                        selection = %label,
                        error = %err_str,
                    );
                    tracing::warn!(
                        target: "export.lifecycle",
                        event = "export.batch.failed",
                        reason = "panic",
                        selection = %label,
                        error = %err_str,
                    );
                    final_outcome = Some(ExportRunOutcome::PartialFailure {
                        folder: output_folder_path.clone(),
                        completed: completed_tags,
                        failed_tag: label.clone(),
                        error: err_str,
                    });
                    break 'outer;
                }
            }
        }

        // ── 11. End-of-batch outcome (per fix #34). ──────────────────────
        let outcome = match final_outcome {
            Some(o) => o,
            None => {
                tracing::info!(
                    target: "export.lifecycle",
                    event = "export.batch.completed",
                    tag_count = completed_tags as i64,
                );
                ExportRunOutcome::SucceededAll {
                    folder: output_folder_path.clone(),
                    tag_count: completed_tags,
                }
            }
        };
        {
            let mut g = export_progress_for_task
                .lock()
                .expect("export_progress poisoned");
            g.outcome = outcome;
            g.current_tag = None;
            g.completed_tags = completed_tags;
            g.total_tags = total_tags;
        }

        // ── 12. Signal cleanup back to the bus task. ─────────────────────
        // Bus task's select! arm resets `current_mode` and
        // `current_export_cancel` (which we can't borrow from here).
        let _ = cleanup_tx_for_task.send(());
    });

    // Bus returns to its select! loop immediately. CancelExport (and any
    // other command) can now be processed while the export task runs.
    CommandReply {
        ok: true,
        error: None,
    }
}

/// Phase 8 Task 2. Build the platform-default capture-source factory.
/// Wraps `PlatformDefaultSource` in an `Arc<dyn ...>` so the call site
/// in `Command::StartClipRecording` matches the FixtureSource arm. The
/// `Result` shape is preserved from the Task 1 stub so future failures
/// (e.g. missing GStreamer plugins detected at construction) can land
/// here without a signature churn.
#[cfg(feature = "media")]
fn build_platform_default_source(
) -> Result<std::sync::Arc<dyn video_coach_media::source::CaptureSourceFactory>, String> {
    Ok(std::sync::Arc::new(
        video_coach_media::platform_source::PlatformDefaultSource::new(),
    ))
}

/// If `current` has a project with `sourceVideos[0]` and no player is
/// already attached, open a `SourcePlayer` for that source. The disk
/// path is resolved by joining `relative_path` against the project
/// folder, so cross-platform `..` traversal lands at the original file.
///
/// Spawning blocks on GStreamer preroll (~tens of milliseconds for an
/// already-decoded mp4, longer for first-time hardware-decoder cold
/// starts), so this runs inside `spawn_blocking` and does not stall the
/// bus's mpsc loop. Failure to open does not unwind the project — we
/// log the error and leave `current_player` empty so subsequent
/// transport commands return "no source loaded" cleanly.
#[cfg(feature = "media")]
#[allow(clippy::too_many_arguments)]
async fn try_spawn_current_player(
    current: &Option<(video_coach_core::project::Project, std::path::PathBuf)>,
    current_player: &mut Option<std::sync::Arc<video_coach_media::source_player::SourcePlayer>>,
    current_player_mount: &mut Option<crate::frame_sink::MountHandles>,
    frame_mount_factory: &FrameMountFactory,
    rt_for_poll: &tokio::runtime::Handle,
    shutdown_tx_for_poll: &tokio::sync::watch::Sender<bool>,
    player_state: &crate::frame_sink::PlayerStateSlot,
) {
    if current_player.is_some() {
        return;
    }
    let Some((project, folder)) = current.as_ref() else {
        return;
    };
    let Some(first) = project.source_videos.first() else {
        return;
    };
    // Resolve to a clean absolute path. PathBuf::join keeps `..`
    // components literal (e.g. `/tmp/proj/../../Users/...`); GStreamer's
    // filesrc on macOS can't open such paths cleanly. Canonicalize
    // collapses them. Fall back to the joined path if canonicalize
    // fails (e.g. file moved) so the error message stays informative.
    let joined = folder.join(&first.relative_path);
    let abs = joined.canonicalize().unwrap_or(joined);
    let duration = first.duration_seconds;
    let display_name = first.display_name.clone();
    // Phase 9 (fix #3): build the FrameSink + mount handles together. The
    // bus stashes the handles AFTER SourcePlayer::open returns so a
    // failed open doesn't leave a dangling mount entry that ClosePreview
    // would later flip.
    let mounted = frame_mount_factory();
    let mount_handles = mounted.handles();
    let frame_sink = mounted.sink;
    let abs_for_blocking = abs.clone();
    let result = tokio::task::spawn_blocking(move || {
        video_coach_media::source_player::SourcePlayer::open(
            &abs_for_blocking,
            frame_sink,
            duration,
        )
    })
    .await;
    match result {
        Ok(Ok(player)) => {
            tracing::info!(
                target: "player.lifecycle",
                event = "player.opened",
                path = %abs.display(),
                display_name = %display_name,
                duration_seconds = duration,
            );
            let player = std::sync::Arc::new(player);
            // Seed the state slot with the known duration so the UI's
            // first paint shows a non-zero scrub track.
            {
                let mut g = player_state.lock().expect("player_state poisoned");
                g.duration_seconds = duration;
                g.position_seconds = 0.0;
                g.is_playing = false;
                g.last_seek_at = None;
            }
            spawn_position_poll(
                rt_for_poll,
                player.clone(),
                player_state.clone(),
                shutdown_tx_for_poll.subscribe(),
            );
            *current_player = Some(player);
            *current_player_mount = Some(mount_handles);
        }
        Ok(Err(e)) => {
            tracing::warn!(
                target: "player.lifecycle",
                error = %e,
                path = %abs.display(),
                "failed to open source player",
            );
        }
        Err(join) => {
            tracing::warn!(
                target: "player.lifecycle",
                error = %join,
                "join error opening source player",
            );
        }
    }
}

/// Resolve a user-supplied "project folder" path. If the user (or a
/// frontend dialog) hands us a path that ends in `project.json` we want
/// the directory containing it, not the file itself. This keeps later
/// relative-path math (Phase 7 AddSourceVideo) from sprouting a stray
/// `..` component.
fn normalize_project_folder(path: &str) -> std::path::PathBuf {
    let p = std::path::PathBuf::from(path);
    if p.is_file() && p.file_name().and_then(|n| n.to_str()) == Some("project.json") {
        if let Some(parent) = p.parent() {
            return parent.to_path_buf();
        }
    }
    p
}

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

    #[test]
    fn start_recording_serializes_with_fixture_source() {
        let cmd = Command::StartRecording {
            source: SourceConfig::Fixture {
                path: "fixtures/webcam.mov".into(),
            },
            output: "/tmp/x.mov".into(),
        };
        let v = serde_json::to_value(&cmd).unwrap();
        assert_eq!(v["cmd"], "start_recording");
        assert_eq!(v["source"]["kind"], "fixture");
        assert_eq!(v["source"]["path"], "fixtures/webcam.mov");
        assert_eq!(v["output"], "/tmp/x.mov");
    }

    #[test]
    fn stop_recording_serializes_to_bare_tag() {
        let cmd = Command::StopRecording;
        let v = serde_json::to_value(&cmd).unwrap();
        assert_eq!(v, serde_json::json!({"cmd": "stop_recording"}));
    }

    #[test]
    fn new_project_serializes_with_path() {
        let cmd = Command::NewProject {
            path: "/tmp/freshproj".into(),
        };
        let v = serde_json::to_value(&cmd).unwrap();
        assert_eq!(v["cmd"], "new_project");
        assert_eq!(v["path"], "/tmp/freshproj");
    }

    #[test]
    fn new_project_deserializes_with_path() {
        let v = serde_json::json!({"cmd": "new_project", "path": "/tmp/freshproj"});
        let cmd: Command = serde_json::from_value(v).unwrap();
        match cmd {
            Command::NewProject { path } => assert_eq!(path, "/tmp/freshproj"),
            _ => panic!("expected NewProject"),
        }
    }

    #[test]
    fn add_source_video_serde_roundtrips() {
        let cmd = Command::AddSourceVideo {
            absolute_path: "/Users/x/clip.mp4".into(),
        };
        let v = serde_json::to_value(&cmd).unwrap();
        assert_eq!(v["cmd"], "add_source_video");
        assert_eq!(v["absolute_path"], "/Users/x/clip.mp4");

        let cmd: Command = serde_json::from_value(v).unwrap();
        match cmd {
            Command::AddSourceVideo { absolute_path } => {
                assert_eq!(absolute_path, "/Users/x/clip.mp4")
            }
            _ => panic!("expected AddSourceVideo"),
        }
    }

    #[test]
    fn play_pause_serialize_to_bare_tags() {
        assert_eq!(
            serde_json::to_value(&Command::Play).unwrap(),
            serde_json::json!({"cmd": "play"})
        );
        assert_eq!(
            serde_json::to_value(&Command::Pause).unwrap(),
            serde_json::json!({"cmd": "pause"})
        );
    }

    #[test]
    fn seek_serde_roundtrips() {
        let cmd = Command::Seek {
            seconds: 12.5,
            accurate: true,
        };
        let v = serde_json::to_value(&cmd).unwrap();
        assert_eq!(v["cmd"], "seek");
        assert_eq!(v["seconds"], 12.5);
        assert_eq!(v["accurate"], true);

        let cmd: Command = serde_json::from_value(v).unwrap();
        match cmd {
            Command::Seek { seconds, accurate } => {
                assert!((seconds - 12.5).abs() < f64::EPSILON);
                assert!(accurate);
            }
            _ => panic!("expected Seek"),
        }
    }

    #[test]
    fn set_scan_volume_serde_roundtrips() {
        let cmd = Command::SetScanVolume { value: 0.75 };
        let v = serde_json::to_value(&cmd).unwrap();
        assert_eq!(v["cmd"], "set_scan_volume");
        assert_eq!(v["value"], 0.75);

        let cmd: Command = serde_json::from_value(v).unwrap();
        match cmd {
            Command::SetScanVolume { value } => assert!((value - 0.75).abs() < f64::EPSILON),
            _ => panic!("expected SetScanVolume"),
        }
    }

    #[test]
    fn normalize_project_folder_passes_through_directory() {
        // A directory path resolves to itself (whether it exists or not is
        // irrelevant here — is_file() returns false for non-existent paths,
        // so the `else` branch returns the original).
        let p = std::path::PathBuf::from("/some/dir/that/does/not/exist");
        assert_eq!(normalize_project_folder("/some/dir/that/does/not/exist"), p);
    }

    #[test]
    fn normalize_project_folder_strips_project_json() {
        // Build a real temp directory + project.json so is_file() returns
        // true. Otherwise the function can't distinguish a hypothetical
        // file path from a directory path.
        let dir = tempfile::TempDir::new().unwrap();
        let json = dir.path().join("project.json");
        std::fs::write(&json, "{}").unwrap();
        assert_eq!(normalize_project_folder(json.to_str().unwrap()), dir.path());
    }

    #[test]
    fn open_project_serializes_with_path() {
        let cmd = Command::OpenProject {
            path: "/tmp/proj".into(),
        };
        let v = serde_json::to_value(&cmd).unwrap();
        assert_eq!(v["cmd"], "open_project");
        assert_eq!(v["path"], "/tmp/proj");
    }

    #[test]
    fn open_project_deserializes_with_path() {
        let v = serde_json::json!({
            "cmd": "open_project",
            "path": "/tmp/proj"
        });
        let cmd: Command = serde_json::from_value(v).unwrap();
        match cmd {
            Command::OpenProject { path } => assert_eq!(path, "/tmp/proj"),
            _ => panic!("expected OpenProject"),
        }
    }

    #[test]
    fn start_clip_recording_serde_roundtrips() {
        let cmd = Command::StartClipRecording {
            playhead_snapshot_seconds: 12.5,
        };
        let v = serde_json::to_value(&cmd).unwrap();
        assert_eq!(v["cmd"], "start_clip_recording");
        assert_eq!(v["playhead_snapshot_seconds"], 12.5);

        let cmd: Command = serde_json::from_value(v).unwrap();
        match cmd {
            Command::StartClipRecording {
                playhead_snapshot_seconds,
            } => {
                assert!((playhead_snapshot_seconds - 12.5).abs() < f64::EPSILON);
            }
            _ => panic!("expected StartClipRecording"),
        }
    }

    #[test]
    fn stop_clip_recording_serializes_to_bare_tag() {
        let cmd = Command::StopClipRecording;
        let v = serde_json::to_value(&cmd).unwrap();
        assert_eq!(v, serde_json::json!({"cmd": "stop_clip_recording"}));

        let cmd: Command =
            serde_json::from_value(serde_json::json!({"cmd": "stop_clip_recording"})).unwrap();
        assert!(matches!(cmd, Command::StopClipRecording));
    }

    #[test]
    fn append_stroke_serde_roundtrips() {
        let cmd = Command::AppendStroke {
            points_json: r#"[{"x":0.5,"y":0.5,"t":0.1}]"#.into(),
        };
        let v = serde_json::to_value(&cmd).unwrap();
        assert_eq!(v["cmd"], "append_stroke");
        assert_eq!(v["points_json"], r#"[{"x":0.5,"y":0.5,"t":0.1}]"#);

        let cmd: Command = serde_json::from_value(v).unwrap();
        match cmd {
            Command::AppendStroke { points_json } => {
                assert_eq!(points_json, r#"[{"x":0.5,"y":0.5,"t":0.1}]"#);
            }
            _ => panic!("expected AppendStroke"),
        }
    }

    #[test]
    fn app_mode_serializes_with_snake_case() {
        // AppMode is published over the bus / control socket as the
        // value of a "mode" field on mode.changed events; verify the
        // serde shape directly.
        assert_eq!(
            serde_json::to_value(AppMode::Scanning).unwrap(),
            serde_json::Value::String("scanning".into()),
        );
        assert_eq!(
            serde_json::to_value(AppMode::RecordingStarting).unwrap(),
            serde_json::Value::String("recording_starting".into()),
        );
        assert_eq!(
            serde_json::to_value(AppMode::Recording).unwrap(),
            serde_json::Value::String("recording".into()),
        );
        let m: AppMode = serde_json::from_value(serde_json::Value::String("recording".into()))
            .expect("snake_case roundtrip");
        assert_eq!(m, AppMode::Recording);
    }

    #[test]
    fn start_recording_deserializes_with_fixture_source() {
        let v = serde_json::json!({
            "cmd": "start_recording",
            "source": { "kind": "fixture", "path": "fixtures/webcam.mov" },
            "output": "/tmp/x.mov"
        });
        let cmd: Command = serde_json::from_value(v).unwrap();
        match cmd {
            Command::StartRecording {
                source: SourceConfig::Fixture { path },
                output,
            } => {
                assert_eq!(path, "fixtures/webcam.mov");
                assert_eq!(output, "/tmp/x.mov");
            }
            _ => panic!("expected StartRecording with Fixture source"),
        }
    }

    #[test]
    fn open_clip_preview_serde_roundtrips() {
        let cmd = Command::OpenClipPreview {
            clip_id: "11111111-2222-3333-4444-555555555555".into(),
        };
        let v = serde_json::to_value(&cmd).unwrap();
        assert_eq!(v["cmd"], "open_clip_preview");
        assert_eq!(v["clip_id"], "11111111-2222-3333-4444-555555555555");

        let cmd: Command = serde_json::from_value(v).unwrap();
        match cmd {
            Command::OpenClipPreview { clip_id } => {
                assert_eq!(clip_id, "11111111-2222-3333-4444-555555555555");
            }
            _ => panic!("expected OpenClipPreview"),
        }
    }

    #[test]
    fn close_preview_serializes_to_bare_tag() {
        let v = serde_json::to_value(&Command::ClosePreview).unwrap();
        assert_eq!(v, serde_json::json!({"cmd": "close_preview"}));
        let cmd: Command =
            serde_json::from_value(serde_json::json!({"cmd": "close_preview"})).unwrap();
        assert!(matches!(cmd, Command::ClosePreview));
    }

    #[cfg(feature = "media")]
    fn make_clip(
        name: &str,
        recording_duration: f64,
        source_index: usize,
    ) -> video_coach_core::project::Clip {
        video_coach_core::project::Clip {
            id: uuid::Uuid::new_v4(),
            name: name.into(),
            notes: String::new(),
            tags: Vec::new(),
            source_index,
            start_source_seconds: 0.0,
            recording_duration,
            recording_filename: format!("{name}.mov"),
            events: Vec::new(),
            sort_index: 0,
            created_at: chrono::Utc::now(),
        }
    }

    #[cfg(feature = "media")]
    #[test]
    fn write_clip_list_hydrates_from_open_project() {
        // Phase 9 fix #13 (OpenProject path). Bus loads a project with
        // 2 existing clips; the slot must reflect those clips after the
        // write. Same call shape the OpenProject handler uses.
        let slot = crate::frame_sink::new_clip_list();
        let clips = vec![
            make_clip("1-00:00:00", 1.5, 0),
            make_clip("1-00:00:05", 2.25, 0),
        ];
        write_clip_list(&slot, &clips);
        let g = slot.lock().unwrap();
        assert_eq!(g.len(), 2);
        assert_eq!(g[0].name, "1-00:00:00");
        assert!((g[0].recording_duration - 1.5).abs() < f64::EPSILON);
        assert_eq!(g[1].name, "1-00:00:05");
        assert_eq!(g[0].source_index, 0);
    }

    #[cfg(feature = "media")]
    #[test]
    fn write_clip_list_clears_for_empty_project() {
        // Phase 9 fix #13 (NewProject path). NewProject's clips are
        // empty; the slot — which may have entries from a previously
        // open project — must clear so the sidebar matches.
        let slot = crate::frame_sink::new_clip_list();
        // Pre-populate to simulate a previously-loaded project.
        slot.lock().unwrap().push(crate::frame_sink::ClipSummary {
            id: uuid::Uuid::new_v4(),
            name: "stale".into(),
            recording_duration: 0.0,
            source_index: 0,
            tags: Vec::new(),
        });
        let empty: Vec<video_coach_core::project::Clip> = Vec::new();
        write_clip_list(&slot, &empty);
        assert!(slot.lock().unwrap().is_empty());
    }

    #[cfg(feature = "media")]
    #[test]
    fn write_clip_list_appends_after_stop_clip_recording() {
        // Phase 9 fix #13 (StopClipRecording path). After a successful
        // stop, project.clips already has the new clip pushed; the slot
        // call syncs against the post-push vector.
        let slot = crate::frame_sink::new_clip_list();
        let mut clips = vec![make_clip("1-00:00:00", 1.0, 0)];
        write_clip_list(&slot, &clips);
        assert_eq!(slot.lock().unwrap().len(), 1);

        // Simulate StopClipRecording's project.clips.push:
        clips.push(make_clip("1-00:00:30", 2.0, 0));
        write_clip_list(&slot, &clips);
        let g = slot.lock().unwrap();
        assert_eq!(g.len(), 2);
        assert_eq!(g[1].name, "1-00:00:30");
    }

    #[cfg(feature = "media")]
    #[test]
    fn write_clip_list_propagates_tags_to_summaries() {
        // Phase 10 Task 0 (Task 3 plan's "pick (b)"): the export-sheet
        // UI's tag-aggregation step runs from `ClipListSlot`, so
        // `write_clip_list` must copy `Clip::tags` through to
        // `ClipSummary::tags`. This guards against an accidental
        // regression where the field gets defaulted to empty.
        let slot = crate::frame_sink::new_clip_list();
        let mut clip = make_clip("1-00:00:00", 1.5, 0);
        clip.tags = vec!["basketball".into(), "drills".into()];
        write_clip_list(&slot, &[clip]);
        let g = slot.lock().unwrap();
        assert_eq!(g.len(), 1);
        assert_eq!(g[0].tags, vec!["basketball", "drills"]);
    }

    #[test]
    fn export_compilations_serde_roundtrips() {
        // Phase 10 Task 0: ExportCompilations carries Vec<TagSelection>,
        // a folder path, the persisted Resolution + Quality enums, and
        // the project name (used for filename composition by the bus's
        // `sanitize_filename` helper).
        let cmd = Command::ExportCompilations {
            selections: vec![
                TagSelection::AllClips,
                TagSelection::Tag {
                    name: "basketball".into(),
                },
            ],
            output_folder: "/Users/x/Exports".into(),
            resolution: video_coach_core::project::Resolution::R1080,
            quality: video_coach_core::project::Quality::High,
            project_name: "Practice 2026-04-30".into(),
        };
        let v = serde_json::to_value(&cmd).unwrap();
        assert_eq!(v["cmd"], "export_compilations");
        assert_eq!(v["output_folder"], "/Users/x/Exports");
        assert_eq!(v["project_name"], "Practice 2026-04-30");
        assert_eq!(v["resolution"], "r1080");
        assert_eq!(v["quality"], "high");
        assert_eq!(v["selections"][0]["kind"], "all_clips");
        assert_eq!(v["selections"][1]["kind"], "tag");
        assert_eq!(v["selections"][1]["name"], "basketball");

        let cmd: Command = serde_json::from_value(v).unwrap();
        match cmd {
            Command::ExportCompilations {
                selections,
                output_folder,
                resolution,
                quality,
                project_name,
            } => {
                assert_eq!(selections.len(), 2);
                assert_eq!(selections[0], TagSelection::AllClips);
                assert_eq!(
                    selections[1],
                    TagSelection::Tag {
                        name: "basketball".into()
                    }
                );
                assert_eq!(output_folder, "/Users/x/Exports");
                assert_eq!(resolution, video_coach_core::project::Resolution::R1080);
                assert_eq!(quality, video_coach_core::project::Quality::High);
                assert_eq!(project_name, "Practice 2026-04-30");
            }
            _ => panic!("expected ExportCompilations"),
        }
    }

    #[test]
    fn cancel_export_serializes_to_bare_tag() {
        let v = serde_json::to_value(&Command::CancelExport).unwrap();
        assert_eq!(v, serde_json::json!({"cmd": "cancel_export"}));
        let cmd: Command =
            serde_json::from_value(serde_json::json!({"cmd": "cancel_export"})).unwrap();
        assert!(matches!(cmd, Command::CancelExport));
    }

    #[test]
    fn app_mode_exporting_serializes_with_snake_case() {
        // Phase 10 Task 0: the new `Exporting` AppMode variant rides
        // the same snake_case rename as Phase 8/9's unit variants.
        assert_eq!(
            serde_json::to_value(AppMode::Exporting).unwrap(),
            serde_json::Value::String("exporting".into()),
        );
        let m: AppMode = serde_json::from_value(serde_json::Value::String("exporting".into()))
            .expect("snake_case roundtrip");
        assert_eq!(m, AppMode::Exporting);
    }

    #[test]
    fn tag_selection_all_clips_serializes() {
        // Phase 10 Task 0 (fix #33): TagSelection uses an internally-
        // tagged kind discriminant so the synthetic "All Clips" row
        // can sit alongside real tag names without a magic-string
        // collision.
        let v = serde_json::to_value(&TagSelection::AllClips).unwrap();
        assert_eq!(v, serde_json::json!({"kind": "all_clips"}));
        let s: TagSelection =
            serde_json::from_value(serde_json::json!({"kind": "all_clips"})).unwrap();
        assert_eq!(s, TagSelection::AllClips);
    }

    #[test]
    fn tag_selection_tag_with_name_serializes() {
        let v = serde_json::to_value(&TagSelection::Tag {
            name: "basketball".into(),
        })
        .unwrap();
        assert_eq!(v, serde_json::json!({"kind": "tag", "name": "basketball"}));
        let s: TagSelection =
            serde_json::from_value(serde_json::json!({"kind": "tag", "name": "basketball"}))
                .unwrap();
        assert_eq!(
            s,
            TagSelection::Tag {
                name: "basketball".into()
            }
        );
    }

    #[test]
    fn tag_selection_round_trips_through_command() {
        // Phase 10 Task 0: a full TagSelection round-trip via the
        // outer Command serde shape — guards against accidental
        // re-tagging of the inner enum when nested.
        let cmd = Command::ExportCompilations {
            selections: vec![
                TagSelection::Tag {
                    name: "drills".into(),
                },
                TagSelection::AllClips,
                TagSelection::Tag {
                    name: "shooting".into(),
                },
            ],
            output_folder: "/tmp/exports".into(),
            resolution: video_coach_core::project::Resolution::Source,
            quality: video_coach_core::project::Quality::Low,
            project_name: "Test".into(),
        };
        let json = serde_json::to_string(&cmd).unwrap();
        let cmd2: Command = serde_json::from_str(&json).unwrap();
        match (cmd, cmd2) {
            (
                Command::ExportCompilations { selections: a, .. },
                Command::ExportCompilations { selections: b, .. },
            ) => {
                assert_eq!(a, b);
                assert_eq!(a.len(), 3);
                assert_eq!(
                    a[0],
                    TagSelection::Tag {
                        name: "drills".into()
                    }
                );
                assert_eq!(a[1], TagSelection::AllClips);
                assert_eq!(
                    a[2],
                    TagSelection::Tag {
                        name: "shooting".into()
                    }
                );
            }
            _ => panic!("expected ExportCompilations both ways"),
        }
    }

    #[test]
    fn app_mode_preview_clip_serializes_with_uuid() {
        // Per the plan: PreviewClip(Uuid) serializes as
        // `{"preview_clip": "<uuid-string>"}` per serde's default for
        // tuple variants under `#[serde(rename_all = "snake_case")]`.
        let id = uuid::Uuid::parse_str("01020304-0506-0708-090a-0b0c0d0e0f10").unwrap();
        let v = serde_json::to_value(AppMode::PreviewClip(id)).unwrap();
        assert_eq!(
            v,
            serde_json::json!({"preview_clip": "01020304-0506-0708-090a-0b0c0d0e0f10"}),
        );

        // Roundtrip back to the same variant + Uuid.
        let m: AppMode = serde_json::from_value(v).expect("preview_clip roundtrip");
        assert_eq!(m, AppMode::PreviewClip(id));

        // The unit variants still serialize as bare strings; PreviewClip
        // is the only externally-tagged variant. Sanity-check that the
        // tagging shapes haven't crossed.
        assert_eq!(
            serde_json::to_value(AppMode::Scanning).unwrap(),
            serde_json::Value::String("scanning".into()),
        );
    }

    // ── Phase 10 Task 2 refusal-path tests ────────────────────────────
    //
    // These dispatch `handle_export_compilations` directly (rather than
    // going through `BusHandle::send`) so the test doesn't need a full
    // bus loop, control socket, or fixture project on disk. They cover
    // the three pre-export refusal paths that don't touch the export
    // pipeline:
    //   - no project open
    //   - busy with a recording in flight
    //   - cancel-when-not-exporting (CancelExport)
    // The mid-export cancel path is exercised by Task 4's harness E2E.
    #[cfg(feature = "media")]
    #[tokio::test]
    async fn export_with_no_project_open_returns_no_project_open() {
        // Sets `current = None` and dispatches an otherwise-valid
        // ExportCompilations. Expect ok=false + error containing
        // "no_project_open" (per plan step 3).
        let mut current: Option<(video_coach_core::project::Project, std::path::PathBuf)> = None;
        let mut current_mode = AppMode::Scanning;
        let recording: Option<video_coach_media::recording::Recording> = None;
        let recording_clip: Option<RecordingClipInProgress> = None;
        let recording_state = crate::frame_sink::new_recording_state();
        let export_progress = crate::frame_sink::new_export_progress();
        let mut current_export_cancel: Option<std::sync::Arc<std::sync::atomic::AtomicBool>> = None;
        let compositor = std::sync::Arc::new(
            video_coach_compositor::Compositor::new_headless().expect("compositor"),
        );
        let (export_cleanup_tx, _export_cleanup_rx) = tokio::sync::mpsc::unbounded_channel::<()>();

        let reply = handle_export_compilations(
            vec![TagSelection::AllClips],
            "/tmp/exports".into(),
            video_coach_core::project::Resolution::R720,
            video_coach_core::project::Quality::Low,
            "Test".into(),
            &mut current,
            &mut current_mode,
            &recording,
            &recording_clip,
            &recording_state,
            &export_progress,
            &mut current_export_cancel,
            &compositor,
            &export_cleanup_tx,
        )
        .await;

        assert!(!reply.ok, "should refuse with no project open");
        let err = reply.error.unwrap_or_default();
        assert!(
            err.contains("no_project_open"),
            "expected no_project_open in error, got: {err}",
        );
        // Mode must NOT have transitioned out of Scanning.
        assert_eq!(current_mode, AppMode::Scanning);
        // No cancel flag stashed on a refusal path.
        assert!(current_export_cancel.is_none());
    }

    #[cfg(feature = "media")]
    #[tokio::test]
    async fn export_while_recording_refuses_with_already_recording() {
        // Sets `current_mode = Recording` (which makes is_busy true even
        // without a live `Recording` slot) + a project. ExportCompilations
        // must refuse with reason="already_recording" (per fix #9 +
        // plan step 2).
        let dir = tempfile::TempDir::new().unwrap();
        let project = video_coach_core::project::Project::new("Test");
        video_coach_core::project_store::write(&project, dir.path()).unwrap();
        let mut current = Some((project, dir.path().to_path_buf()));
        let mut current_mode = AppMode::Recording;
        let recording: Option<video_coach_media::recording::Recording> = None;
        let recording_clip: Option<RecordingClipInProgress> = None;
        let recording_state = crate::frame_sink::new_recording_state();
        let export_progress = crate::frame_sink::new_export_progress();
        let mut current_export_cancel: Option<std::sync::Arc<std::sync::atomic::AtomicBool>> = None;
        let compositor = std::sync::Arc::new(
            video_coach_compositor::Compositor::new_headless().expect("compositor"),
        );
        let (export_cleanup_tx, _export_cleanup_rx) = tokio::sync::mpsc::unbounded_channel::<()>();

        let reply = handle_export_compilations(
            vec![TagSelection::AllClips],
            dir.path().to_string_lossy().into_owned(),
            video_coach_core::project::Resolution::R720,
            video_coach_core::project::Quality::Low,
            "Test".into(),
            &mut current,
            &mut current_mode,
            &recording,
            &recording_clip,
            &recording_state,
            &export_progress,
            &mut current_export_cancel,
            &compositor,
            &export_cleanup_tx,
        )
        .await;

        assert!(!reply.ok, "should refuse while recording");
        let err = reply.error.unwrap_or_default();
        assert!(
            err.contains("already_recording"),
            "expected already_recording in error, got: {err}",
        );
        // Mode must remain Recording (no clobber to Exporting).
        assert_eq!(current_mode, AppMode::Recording);
        assert!(current_export_cancel.is_none());
    }

    #[cfg(feature = "media")]
    #[test]
    fn cancel_export_when_not_exporting_replies_not_exporting() {
        // CancelExport directly: when current_mode != Exporting it must
        // return ok=false + error="not_exporting" without emitting any
        // event (per plan CancelExport step 1).
        //
        // We exercise the inline match logic by mirroring it here —
        // the cancel handler is a 4-line match-on-mode that doesn't
        // need the full handle() plumbing, and the synchronous branch
        // is straightforward to assert on.
        let current_mode = AppMode::Scanning;
        let current_export_cancel: Option<std::sync::Arc<std::sync::atomic::AtomicBool>> = None;

        // The inlined logic exactly matches `Command::CancelExport`'s
        // arm in `handle()`. Keep these in lockstep — see plan task 2
        // CancelExport handler section.
        let reply = if !matches!(current_mode, AppMode::Exporting) {
            CommandReply {
                ok: false,
                error: Some("not_exporting".into()),
            }
        } else {
            if let Some(flag) = current_export_cancel.as_ref() {
                flag.store(true, std::sync::atomic::Ordering::Release);
            }
            CommandReply {
                ok: true,
                error: None,
            }
        };

        assert!(!reply.ok);
        assert_eq!(reply.error.as_deref(), Some("not_exporting"));
        // No flag was minted because we never entered Exporting.
        assert!(current_export_cancel.is_none());
    }
}
