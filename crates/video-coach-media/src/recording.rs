use crate::source::CaptureSourceFactory;
use gstreamer::prelude::*;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum RecordingError {
    #[error("gstreamer init failed: {0}")]
    Init(#[from] gstreamer::glib::Error),
    #[error("element factory `{0}` not available — check your gstreamer plugins install")]
    MissingElement(String),
    #[error("pipeline construction: {0}")]
    Build(String),
    #[error("pipeline state change: {0}")]
    StateChange(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("source factory: {0}")]
    Source(#[from] gstreamer::glib::BoolError),
}

/// In-flight recording. `start()` transitions the pipeline to PLAYING; `stop()`
/// sends EOS, waits for it to flush, then transitions to NULL.
pub struct Recording {
    pipeline: gstreamer::Pipeline,
    output_path: PathBuf,
}

fn make_or(name: &str) -> Result<gstreamer::Element, RecordingError> {
    gstreamer::ElementFactory::make(name)
        .build()
        .map_err(|_| RecordingError::MissingElement(name.into()))
}

fn pick_video_encoder() -> Result<gstreamer::Element, RecordingError> {
    // Prefer hardware H.264 if available; fall back to x264enc.
    for name in [
        "vtenc_h264",
        "mfh264enc",
        "vaapih264enc",
        "nvh264enc",
        "x264enc",
    ] {
        if let Ok(elem) = make_or(name) {
            tracing::info!(target: "recording", event = "recording.encoder_picked", encoder = name);
            return Ok(elem);
        }
    }
    Err(RecordingError::MissingElement("h264 encoder (any)".into()))
}

fn pick_audio_encoder() -> Result<gstreamer::Element, RecordingError> {
    // fdkaacenc may not ship in stock Ubuntu (FDK license); avenc_aac (libav)
    // and voaacenc (plugins-bad) are the practical fallbacks.
    for name in ["fdkaacenc", "avenc_aac", "voaacenc"] {
        if let Ok(elem) = make_or(name) {
            tracing::info!(target: "recording", event = "recording.audio_encoder_picked", encoder = name);
            return Ok(elem);
        }
    }
    Err(RecordingError::MissingElement("aac encoder (any)".into()))
}

pub fn start(
    factory: Arc<dyn CaptureSourceFactory>,
    output_path: PathBuf,
) -> Result<Recording, RecordingError> {
    crate::init()?;

    if let Some(parent) = output_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let pipeline = gstreamer::Pipeline::new();
    let source_bin = factory.build()?;

    let videoconvert = make_or("videoconvert")?;
    let video_enc = pick_video_encoder()?;
    let h264parse = make_or("h264parse")?;

    let audioconvert = make_or("audioconvert")?;
    let audioresample = make_or("audioresample")?;
    let audio_enc = pick_audio_encoder()?;

    let qtmux = make_or("qtmux")?;
    let filesink = gstreamer::ElementFactory::make("filesink")
        .property("location", output_path.to_str().expect("utf8 path"))
        .build()
        .map_err(|_| RecordingError::MissingElement("filesink".into()))?;

    pipeline
        .add(&source_bin)
        .map_err(|e| RecordingError::Build(format!("add source: {e}")))?;
    pipeline
        .add_many([
            &videoconvert,
            &video_enc,
            &h264parse,
            &audioconvert,
            &audioresample,
            &audio_enc,
            &qtmux,
            &filesink,
        ])
        .map_err(|e| RecordingError::Build(format!("add chain: {e}")))?;

    // Static links downstream of the source bin (whose pads are dynamic).
    gstreamer::Element::link_many([&videoconvert, &video_enc, &h264parse])
        .map_err(|e| RecordingError::Build(format!("link video chain: {e}")))?;
    gstreamer::Element::link_many([&audioconvert, &audioresample, &audio_enc])
        .map_err(|e| RecordingError::Build(format!("link audio chain: {e}")))?;
    h264parse
        .link(&qtmux)
        .map_err(|e| RecordingError::Build(format!("link h264parse → qtmux: {e}")))?;
    audio_enc
        .link(&qtmux)
        .map_err(|e| RecordingError::Build(format!("link audio_enc → qtmux: {e}")))?;
    qtmux
        .link(&filesink)
        .map_err(|e| RecordingError::Build(format!("link qtmux → filesink: {e}")))?;

    // Source bin → convert chains. Two cases to handle:
    //   1. PlatformDefaultSource: ghost pads exist at construction.
    //      `connect_pad_added` would never fire for them (the signal
    //      only fires on FUTURE pad-add events), so link them
    //      synchronously now.
    //   2. FixtureSource: pads appear dynamically when its internal
    //      decodebin demuxes the file. Link them via `pad-added`.
    // Failing to handle case 1 leaves the platform sources unlinked —
    // they error out with "not-linked" the moment the pipeline goes
    // PLAYING, the bus fills with errors no one's reading, and the
    // app sits in a phantom Recording state until stop tears down a
    // pipeline that never produced data.
    let videoconvert_sink = videoconvert.static_pad("sink").expect("videoconvert sink");
    let audioconvert_sink = audioconvert.static_pad("sink").expect("audioconvert sink");
    for (pad_name, target_sink) in [
        ("video-src", &videoconvert_sink),
        ("audio-src", &audioconvert_sink),
    ] {
        if let Some(pad) = source_bin.static_pad(pad_name) {
            pad.link(target_sink)
                .map_err(|e| RecordingError::Build(format!("link {pad_name}: {e:?}")))?;
        }
    }
    source_bin.connect_pad_added(move |_bin, pad| {
        let pad_name = pad.name();
        let target_sink = if pad_name == "video-src" {
            &videoconvert_sink
        } else if pad_name == "audio-src" {
            &audioconvert_sink
        } else {
            return;
        };
        if pad.is_linked() {
            return;
        }
        if let Err(e) = pad.link(target_sink) {
            tracing::warn!(
                target: "recording",
                pad = %pad_name,
                error = ?e,
                "failed to link source pad to converter",
            );
        }
    });

    pipeline
        .set_state(gstreamer::State::Playing)
        .map_err(|e| RecordingError::StateChange(format!("PLAYING: {e:?}")))?;

    tracing::info!(
        target: "recording",
        event = "recording.started",
        source = factory.name(),
        output = %output_path.display(),
    );

    Ok(Recording {
        pipeline,
        output_path,
    })
}

impl Recording {
    pub fn output_path(&self) -> &Path {
        &self.output_path
    }

    pub fn stop(self) -> Result<(), RecordingError> {
        // Send EOS so qtmux flushes its moov atom; without this the .mov is
        // unplayable (no index).
        let bus = self.pipeline.bus().expect("pipeline bus");
        self.pipeline.send_event(gstreamer::event::Eos::new());

        // Wait for EOS, capturing any error WITHOUT returning early. The
        // teardown below MUST run on every path: leaving the pipeline in
        // PLAYING and dropping it triggers gst-plugins-good's
        // `osxaudiosrc` to race CoreAudio's HAL IO callback against
        // element disposal, crashing in `gst_osx_audio_src_io_proc`.
        let eos_outcome = wait_for_eos(&bus, Duration::from_secs(5));

        // Step state down through Paused → Ready before Null, with a sync
        // wait per transition. Per-state waits force the pipeline to
        // fully settle at each level before tearing the AudioUnit down,
        // serializing `gst_core_audio_close()` against the rest of
        // teardown.
        for intermediate in [gstreamer::State::Paused, gstreamer::State::Ready] {
            if let Err(e) = self.pipeline.set_state(intermediate) {
                tracing::warn!(
                    target: "recording",
                    state = ?intermediate,
                    error = ?e,
                    "intermediate set_state failed; continuing teardown",
                );
                continue;
            }
            let (res, _, _) = self
                .pipeline
                .state(Some(gstreamer::ClockTime::from_seconds(2)));
            if let Err(e) = res {
                tracing::warn!(
                    target: "recording",
                    state = ?intermediate,
                    error = ?e,
                    "intermediate state wait failed; continuing teardown",
                );
            }
        }
        let null_result = self
            .pipeline
            .set_state(gstreamer::State::Null)
            .map_err(|e| RecordingError::StateChange(format!("NULL: {e:?}")));

        tracing::info!(
            target: "recording",
            event = "recording.stopped",
            output = %self.output_path.display(),
        );

        // Surface the first failure: a busted EOS means the .mov may be
        // truncated; a busted NULL transition is catastrophic. Either
        // way, teardown ran.
        eos_outcome?;
        null_result?;
        Ok(())
    }
}

fn wait_for_eos(bus: &gstreamer::Bus, timeout: Duration) -> Result<(), RecordingError> {
    let deadline = std::time::Instant::now() + timeout;
    loop {
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        if remaining.is_zero() {
            tracing::warn!(target: "recording", "EOS timeout — file may be truncated");
            return Ok(());
        }
        match bus.timed_pop_filtered(
            gstreamer::ClockTime::from_nseconds(remaining.as_nanos() as u64),
            &[gstreamer::MessageType::Eos, gstreamer::MessageType::Error],
        ) {
            None => return Ok(()),
            Some(msg) => match msg.view() {
                gstreamer::MessageView::Eos(_) => return Ok(()),
                gstreamer::MessageView::Error(err) => {
                    return Err(RecordingError::Build(format!("eos wait: {err}")));
                }
                _ => continue,
            },
        }
    }
}
