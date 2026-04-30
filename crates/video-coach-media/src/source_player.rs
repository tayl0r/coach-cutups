//! Phase 7. A GStreamer-backed source-video player.
//!
//! Pipeline shape:
//!
//! ```text
//! filesrc → decodebin
//!   ├─[video/*]→ queue → videoconvert → capsfilter(RGBA) → appsink (FrameSink::push_frame)
//!   └─[audio/*]→ queue → audioconvert → audioresample → volume(scan_volume) → osxaudiosink|wasapisink|pulsesink
//! ```
//!
//! Threading: every public method on `SourcePlayer` is `&self`-only and
//! safe to call from any thread (the bus task in our case). All
//! GStreamer interactions go through the pipeline's GObject which is
//! internally mutex-locked. Frame callbacks fire on GStreamer's
//! streaming thread; the supplied `FrameSink::push_frame` is called
//! there and must be non-blocking.
//!
//! Adversarial-review compliance:
//!   - Audio sink is platform-specific (osx/wasapi/pulse) so macOS
//!     doesn't trigger a microphone-permission dialog from autoaudiosink
//!     device probing.
//!   - Duration is supplied by the caller (SourceRef.duration_seconds)
//!     rather than re-probed via Discoverer; avoids the double-open
//!     race that bit Phase 5's VT decoders.

#![allow(clippy::duplicated_attributes)] // intentional with `pub mod source_player` cfg
#![cfg(feature = "media")]

use gstreamer::prelude::*;
use gstreamer_app::AppSink;
use std::path::Path;
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum SourcePlayerError {
    #[error("element factory `{0}` not available — check your gstreamer plugins install")]
    MissingElement(String),
    #[error("pipeline state change: {0}")]
    StateChange(String),
    #[error("pipeline construction: {0}")]
    Construction(String),
    #[error("seek failed")]
    Seek,
    #[error("invalid path (non-utf8)")]
    InvalidPath,
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}

/// Receives decoded RGBA video frames from a [`SourcePlayer`].
///
/// Implementations run on the GStreamer streaming thread. They MUST be
/// non-blocking and MUST drop any previously-pushed frame that has not
/// yet been displayed (no queueing). The supplied `data` slice is
/// borrowed from GStreamer's buffer pool and may be reused after the
/// call returns; implementations that need the data longer should
/// copy.
pub trait FrameSink: Send + Sync + 'static {
    fn push_frame(&self, width: u32, height: u32, data: &[u8]);
}

/// Drops every frame. Used by headless tests and by the bus task while
/// no UI consumer is attached.
#[derive(Default)]
pub struct NullFrameSink;

impl FrameSink for NullFrameSink {
    fn push_frame(&self, _w: u32, _h: u32, _data: &[u8]) {}
}

#[derive(Debug, Clone)]
pub struct PlayerSnapshot {
    pub position_seconds: f64,
    pub duration_seconds: f64,
    pub is_playing: bool,
}

pub struct SourcePlayer {
    pipeline: gstreamer::Pipeline,
    duration_seconds: f64,
    is_playing: Arc<AtomicBool>,
}

impl SourcePlayer {
    /// Open the source at `path` and preroll the pipeline (PAUSED at
    /// t=0). Frames flow to `frame_sink` once `play()` is called; audio
    /// plays through the OS default sink. `duration_seconds` should be
    /// the known length from `SourceRef.duration_seconds`.
    pub fn open(
        path: &Path,
        frame_sink: Box<dyn FrameSink>,
        duration_seconds: f64,
    ) -> Result<Self, SourcePlayerError> {
        crate::init().map_err(|e| SourcePlayerError::Construction(e.to_string()))?;

        let pipeline = gstreamer::Pipeline::new();

        let filesrc = gstreamer::ElementFactory::make("filesrc")
            .property(
                "location",
                path.to_str().ok_or(SourcePlayerError::InvalidPath)?,
            )
            .build()
            .map_err(|_| SourcePlayerError::MissingElement("filesrc".into()))?;
        let decodebin = make_or("decodebin")?;

        // Pre-built video chain: queue → videoconvert → capsfilter(RGBA) → appsink.
        // Decodebin's video pad is linked to `video_queue.sink` in pad_added.
        let video_queue = make_or("queue")?;
        let videoconvert = make_or("videoconvert")?;
        let rgba_caps = gstreamer::Caps::from_str("video/x-raw,format=RGBA")
            .map_err(|e| SourcePlayerError::Construction(format!("rgba caps: {e}")))?;
        let video_capsfilter = gstreamer::ElementFactory::make("capsfilter")
            .property("caps", &rgba_caps)
            .build()
            .map_err(|_| SourcePlayerError::MissingElement("capsfilter".into()))?;
        let video_appsink: AppSink = AppSink::builder().caps(&rgba_caps).sync(true).build();

        // Wire FrameSink into the appsink callbacks.
        {
            let frame_sink: Arc<dyn FrameSink> = Arc::from(frame_sink);
            let frame_sink_for_preroll = frame_sink.clone();
            video_appsink.set_callbacks(
                gstreamer_app::AppSinkCallbacks::builder()
                    // Preroll fires once during PAUSED; we still drain it
                    // and forward as a frame so the UI sees t=0 even
                    // before play() is called.
                    .new_preroll(move |sink| {
                        if let Ok(sample) = sink.pull_preroll() {
                            push_sample_to_frame_sink(&frame_sink_for_preroll, &sample);
                        }
                        Ok(gstreamer::FlowSuccess::Ok)
                    })
                    .new_sample(move |sink| {
                        let sample = sink.pull_sample().map_err(|_| gstreamer::FlowError::Eos)?;
                        push_sample_to_frame_sink(&frame_sink, &sample);
                        Ok(gstreamer::FlowSuccess::Ok)
                    })
                    .build(),
            );
        }

        pipeline
            .add_many([
                &filesrc,
                &decodebin,
                &video_queue,
                &videoconvert,
                &video_capsfilter,
                video_appsink.upcast_ref::<gstreamer::Element>(),
            ])
            .map_err(|e| SourcePlayerError::Construction(format!("add video chain: {e}")))?;
        gstreamer::Element::link(&filesrc, &decodebin)
            .map_err(|e| SourcePlayerError::Construction(format!("link filesrc: {e}")))?;
        gstreamer::Element::link_many([
            &video_queue,
            &videoconvert,
            &video_capsfilter,
            video_appsink.upcast_ref::<gstreamer::Element>(),
        ])
        .map_err(|e| SourcePlayerError::Construction(format!("link video chain: {e}")))?;

        // Audio chain is added dynamically on pad_added if an audio pad
        // is detected. Sources without audio (rare but possible) are
        // tolerated by simply never adding the audio chain.
        let video_queue_sink = video_queue
            .static_pad("sink")
            .ok_or_else(|| SourcePlayerError::Construction("video_queue has no sink pad".into()))?;
        let pipeline_weak = pipeline.downgrade();
        decodebin.connect_pad_added(move |_dbin, pad| {
            let Some(caps) = pad.current_caps() else {
                return;
            };
            let Some(structure) = caps.structure(0) else {
                return;
            };
            let media = structure.name().to_string();
            if media.starts_with("video/") {
                if let Err(e) = pad.link(&video_queue_sink) {
                    tracing::warn!(
                        target: "player.lifecycle",
                        error = ?e,
                        "failed to link decoded video pad",
                    );
                }
                return;
            }
            if media.starts_with("audio/") {
                let Some(pipeline) = pipeline_weak.upgrade() else {
                    return;
                };
                if let Err(e) = build_and_link_audio_chain(&pipeline, pad) {
                    tracing::warn!(
                        target: "player.lifecycle",
                        error = %e,
                        "failed to wire audio chain (audio will be silent)",
                    );
                }
            }
        });

        // Preroll. Sets state to PAUSED and waits for the pipeline to
        // settle (decodebin negotiates streams, sinks preroll). Failure
        // here typically means the file format is unsupported by the
        // installed plugins.
        pipeline
            .set_state(gstreamer::State::Paused)
            .map_err(|e| SourcePlayerError::StateChange(format!("preroll: {e:?}")))?;

        // Block briefly until preroll completes — without this, the
        // first set_state(Playing) can race the decodebin pad_added
        // and fail to start.
        let (_, _, _) = pipeline.state(gstreamer::ClockTime::from_seconds(5));

        Ok(Self {
            pipeline,
            duration_seconds,
            is_playing: Arc::new(AtomicBool::new(false)),
        })
    }

    pub fn play(&self) -> Result<(), SourcePlayerError> {
        self.pipeline
            .set_state(gstreamer::State::Playing)
            .map_err(|e| SourcePlayerError::StateChange(format!("play: {e:?}")))?;
        self.is_playing.store(true, Ordering::SeqCst);
        tracing::info!(target: "player.state", event = "player.playing");
        Ok(())
    }

    pub fn pause(&self) -> Result<(), SourcePlayerError> {
        self.pipeline
            .set_state(gstreamer::State::Paused)
            .map_err(|e| SourcePlayerError::StateChange(format!("pause: {e:?}")))?;
        self.is_playing.store(false, Ordering::SeqCst);
        tracing::info!(target: "player.state", event = "player.paused");
        Ok(())
    }

    pub fn seek(&self, seconds: f64, accurate: bool) -> Result<(), SourcePlayerError> {
        let clamped = seconds.max(0.0);
        let position =
            gstreamer::ClockTime::from_nseconds((clamped * 1_000_000_000.0).round() as u64);
        let mut flags = gstreamer::SeekFlags::FLUSH;
        if accurate {
            flags |= gstreamer::SeekFlags::ACCURATE;
        } else {
            flags |= gstreamer::SeekFlags::KEY_UNIT;
        }
        self.pipeline
            .seek_simple(flags, position)
            .map_err(|_| SourcePlayerError::Seek)?;
        tracing::info!(
            target: "player.state",
            event = "player.seeked",
            seconds = clamped,
            accurate,
        );
        Ok(())
    }

    pub fn snapshot(&self) -> PlayerSnapshot {
        let position = self
            .pipeline
            .query_position::<gstreamer::ClockTime>()
            .map(|t| t.nseconds() as f64 / 1_000_000_000.0)
            .unwrap_or(0.0);
        PlayerSnapshot {
            position_seconds: position,
            duration_seconds: self.duration_seconds,
            is_playing: self.is_playing.load(Ordering::SeqCst),
        }
    }

    /// Set scan volume (0.0..=1.0). Looks the volume element up by
    /// name; no-op if the audio chain wasn't added (silent source).
    pub fn set_volume(&self, value: f64) {
        let v = value.clamp(0.0, 1.0);
        if let Some(volume) = self.pipeline.by_name("scan_volume") {
            volume.set_property("volume", v);
        }
    }
}

impl Drop for SourcePlayer {
    fn drop(&mut self) {
        let _ = self.pipeline.set_state(gstreamer::State::Null);
    }
}

fn make_or(name: &str) -> Result<gstreamer::Element, SourcePlayerError> {
    gstreamer::ElementFactory::make(name)
        .build()
        .map_err(|_| SourcePlayerError::MissingElement(name.into()))
}

fn push_sample_to_frame_sink(sink: &Arc<dyn FrameSink>, sample: &gstreamer::Sample) {
    let Some(buffer) = sample.buffer() else {
        return;
    };
    let Some(caps) = sample.caps() else {
        return;
    };
    let Some(structure) = caps.structure(0) else {
        return;
    };
    let Ok(width) = structure.get::<i32>("width") else {
        return;
    };
    let Ok(height) = structure.get::<i32>("height") else {
        return;
    };
    let Ok(map) = buffer.map_readable() else {
        return;
    };
    sink.push_frame(width as u32, height as u32, &map);
}

fn build_and_link_audio_chain(
    pipeline: &gstreamer::Pipeline,
    src_pad: &gstreamer::Pad,
) -> Result<(), SourcePlayerError> {
    let queue = make_or("queue")?;
    let convert = make_or("audioconvert")?;
    let resample = make_or("audioresample")?;
    let volume = gstreamer::ElementFactory::make("volume")
        .name("scan_volume")
        .property("volume", 1.0_f64)
        .build()
        .map_err(|_| SourcePlayerError::MissingElement("volume".into()))?;
    let audiosink = if platform_audio_sink_name() == "fakesink" {
        // Emulate a real audio sink's clock by syncing fakesink to the
        // pipeline clock — without sync=true the fake sink consumes
        // buffers as fast as decode produces them, sending the pipeline
        // way past real-time.
        gstreamer::ElementFactory::make("fakesink")
            .property("sync", true)
            .build()
            .map_err(|_| SourcePlayerError::MissingElement("fakesink".into()))?
    } else {
        make_or(platform_audio_sink_name())?
    };

    pipeline
        .add_many([&queue, &convert, &resample, &volume, &audiosink])
        .map_err(|e| SourcePlayerError::Construction(format!("add audio chain: {e}")))?;
    gstreamer::Element::link_many([&queue, &convert, &resample, &volume, &audiosink])
        .map_err(|e| SourcePlayerError::Construction(format!("link audio chain: {e}")))?;
    for e in [&queue, &convert, &resample, &volume, &audiosink] {
        e.sync_state_with_parent()
            .map_err(|e| SourcePlayerError::Construction(format!("sync state: {e}")))?;
    }
    let queue_sink = queue
        .static_pad("sink")
        .ok_or_else(|| SourcePlayerError::Construction("audio queue has no sink pad".into()))?;
    src_pad
        .link(&queue_sink)
        .map_err(|e| SourcePlayerError::Construction(format!("link audio pad: {e}")))?;
    Ok(())
}

/// Per the adversarial review: `autoaudiosink` probes audio devices on
/// macOS, which on a clean install fires a microphone-permission dialog
/// even though we're only playing back. Naming the platform sink
/// directly skips the probe.
///
/// `VIDEO_COACH_NO_AUDIO=1` forces `fakesink sync=true` instead. Used by
/// CI runners where no audio daemon is reachable — without it, the
/// real platform sink builds successfully but fails the
/// PAUSED→PLAYING transition with a StateChangeError.
fn platform_audio_sink_name() -> &'static str {
    if std::env::var("VIDEO_COACH_NO_AUDIO").is_ok() {
        return "fakesink";
    }
    if cfg!(target_os = "macos") {
        "osxaudiosink"
    } else if cfg!(target_os = "windows") {
        "wasapisink"
    } else {
        "pulsesink"
    }
}

/// Probe a media file's duration without opening a play pipeline. Used
/// by the AddSourceVideo bus handler to populate
/// `SourceRef.duration_seconds`. Backed by GStreamer's Discoverer,
/// which is a brief preroll-only inspection — much cheaper than
/// opening a full SourcePlayer.
///
/// Sequenced *before* any subsequent SourcePlayer::open on the same
/// file (in the same process) so the two never race on platform
/// hardware decoders.
pub fn probe_duration(path: &Path) -> Result<f64, SourcePlayerError> {
    crate::init().map_err(|e| SourcePlayerError::Construction(e.to_string()))?;

    let timeout = gstreamer::ClockTime::from_seconds(10);
    let discoverer = gstreamer_pbutils::Discoverer::new(timeout)
        .map_err(|e| SourcePlayerError::Construction(format!("discoverer: {e}")))?;

    let abs = path.canonicalize().map_err(SourcePlayerError::Io)?;
    let uri = format!(
        "file://{}",
        abs.to_str().ok_or(SourcePlayerError::InvalidPath)?
    );
    let info = discoverer
        .discover_uri(&uri)
        .map_err(|e| SourcePlayerError::Construction(format!("discover {uri}: {e}")))?;

    let duration = info.duration().ok_or_else(|| {
        SourcePlayerError::Construction("no duration on discovered stream".into())
    })?;
    Ok(duration.nseconds() as f64 / 1_000_000_000.0)
}
