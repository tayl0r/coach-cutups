// crates/video-coach-media/src/compose.rs
//
// The compose pipeline pulls in video-coach-compositor + wgpu, both of which
// are feature-gated via `media`. Gate the entire module so non-media builds
// don't try to import a crate that isn't a dep.
#![allow(clippy::duplicated_attributes)] // intentional belt-and-suspenders with `pub mod compose` cfg
#![cfg(feature = "media")]

use crate::recording::RecordingError;
use gstreamer::prelude::*;
use gstreamer_app::{AppSink, AppSrc};
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use thiserror::Error;

// All of these support `passthrough_one_file` (a Phase-5 stepping-stone that
// lives only in tests for now) and the eventual real `compose_two_files`
// in Task 4. clippy's dead-code lint doesn't see through `#[cfg(test)]`.
#[allow(dead_code)]
const RGBA_CAPS: &str = "video/x-raw,format=RGBA";

#[derive(Debug, Error)]
pub enum ComposeError {
    #[error("compositor: {0}")]
    Compositor(#[from] video_coach_compositor::CompositorError),
    #[error("recording layer: {0}")]
    Recording(#[from] RecordingError),
    #[error("element factory `{0}` not available — check your gstreamer plugins install")]
    MissingElement(String),
    #[error("pipeline state change: {0}")]
    StateChange(String),
    #[error("appsink/appsrc: {0}")]
    AppFlow(String),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("source factory: {0}")]
    Source(#[from] gstreamer::glib::BoolError),
}

#[allow(dead_code)]
fn make_or(name: &str) -> Result<gstreamer::Element, ComposeError> {
    gstreamer::ElementFactory::make(name)
        .build()
        .map_err(|_| ComposeError::MissingElement(name.into()))
}

#[allow(dead_code)]
fn pick_h264_encoder() -> Result<gstreamer::Element, ComposeError> {
    for name in [
        "vtenc_h264",
        "mfh264enc",
        "vaapih264enc",
        "nvh264enc",
        "x264enc",
    ] {
        if let Ok(elem) = make_or(name) {
            return Ok(elem);
        }
    }
    Err(ComposeError::MissingElement("h264 encoder (any)".into()))
}

/// Compose two input video files (source + webcam) into a single output .mov.
/// Phase 5 ignores audio and produces silent video. Output codec: H.264.
pub fn compose_two_files(
    _source: PathBuf,
    _webcam: PathBuf,
    _output: PathBuf,
) -> Result<(), ComposeError> {
    // Real implementation lands in Task 4.
    Err(ComposeError::AppFlow("not implemented yet".into()))
}

/// Single-input passthrough: source video → RGBA appsink → RGBA appsrc → encode → file.
/// Used as a stepping stone before the dual-input compose.
#[allow(dead_code)]
pub(crate) fn passthrough_one_file(source: &Path, output: &Path) -> Result<(), ComposeError> {
    crate::init().map_err(|e| ComposeError::Recording(e.into()))?;

    if let Some(parent) = output.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let pipeline = gstreamer::Pipeline::new();

    // INPUT: filesrc → decodebin → videoconvert → caps RGBA → appsink
    let filesrc = gstreamer::ElementFactory::make("filesrc")
        .property("location", source.to_str().expect("utf8 path"))
        .build()
        .map_err(|_| ComposeError::MissingElement("filesrc".into()))?;
    let decodebin = make_or("decodebin")?;
    // CRITICAL: a `queue` between decodebin's dynamic src pad and any
    // downstream element is required. Without it, decodebin's internal
    // multiqueue stalls because the streaming thread can't switch to drive
    // the consumer chain — the pipeline reaches PLAYING but no buffers
    // ever flow downstream. This is documented in the canonical
    // gstreamer-rs decodebin example.
    let queue_in = make_or("queue")?;
    let videoconvert_in = make_or("videoconvert")?;
    let capsfilter_in = gstreamer::ElementFactory::make("capsfilter")
        .property("caps", gstreamer::Caps::from_str(RGBA_CAPS).unwrap())
        .build()
        .map_err(|_| ComposeError::MissingElement("capsfilter".into()))?;
    // Don't set caps on appsink — capsfilter_in already forces RGBA. Adding
    // format-only caps here can fail negotiation when upstream offers more
    // specific caps (incl. framerate/colorimetry) that can't subset cleanly.
    // Construct via ElementFactory + downcast to match gstreamer-rs canonical
    // examples exactly. Builder + .build() also works in theory but observed
    // a case where builder-built appsink had buffers reach the sink pad but
    // new_sample callback never fired.
    let appsink_elem = make_or("appsink")?;
    let appsink = appsink_elem
        .clone()
        .dynamic_cast::<AppSink>()
        .map_err(|_| ComposeError::AppFlow("appsink downcast failed".into()))?;
    appsink.set_property("sync", false);

    // OUTPUT: appsrc → videoconvert → encoder → h264parse → qtmux → filesink
    //
    // CRITICAL: appsrc caps MUST include width/height/framerate at construction
    // time. Without them, downstream elements call gst_util_fraction_*() on a
    // zero denominator and the pipeline silently stalls (GStreamer-CRITICAL
    // assertion failure with no propagated error). Use generic placeholders
    // here; the first sample's caps overwrite via set_caps() in new_sample.
    let appsrc_caps =
        gstreamer::Caps::from_str("video/x-raw,format=RGBA,width=1920,height=1080,framerate=30/1")
            .unwrap();
    let appsrc = AppSrc::builder()
        .caps(&appsrc_caps)
        .format(gstreamer::Format::Time)
        .is_live(false)
        .build();
    let videoconvert_out = make_or("videoconvert")?;
    // H.264 encoders (vtenc_h264, x264enc, etc.) don't accept RGBA input —
    // force a YUV format the encoder negotiates to. NV12 is the broadest
    // common format; videoconvert handles RGBA → NV12 transparently.
    let capsfilter_yuv = gstreamer::ElementFactory::make("capsfilter")
        .property(
            "caps",
            gstreamer::Caps::from_str("video/x-raw,format=NV12").unwrap(),
        )
        .build()
        .map_err(|_| ComposeError::MissingElement("capsfilter".into()))?;
    let video_enc = pick_h264_encoder()?;
    let h264parse = make_or("h264parse")?;
    let qtmux = make_or("qtmux")?;
    // CRITICAL: async=false. Default sinks block the pipeline state
    // transition on preroll. With appsrc upstream (which has nothing to push
    // until input chain delivers), filesink can't preroll, pipeline never
    // reaches PLAYING, and input chain stops after one buffer (the preroll).
    // async=false lets the pipeline transition to PLAYING without waiting
    // for filesink preroll.
    let filesink = gstreamer::ElementFactory::make("filesink")
        .property("location", output.to_str().expect("utf8 path"))
        .property("async", false)
        .build()
        .map_err(|_| ComposeError::MissingElement("filesink".into()))?;

    pipeline
        .add_many([
            &filesrc,
            &decodebin,
            &queue_in,
            &videoconvert_in,
            &capsfilter_in,
            appsink.upcast_ref::<gstreamer::Element>(),
            appsrc.upcast_ref::<gstreamer::Element>(),
            &videoconvert_out,
            &capsfilter_yuv,
            &video_enc,
            &h264parse,
            &qtmux,
            &filesink,
        ])
        .map_err(|e| ComposeError::AppFlow(format!("add: {e}")))?;

    // Static links upstream of decodebin's dynamic pads.
    filesrc
        .link(&decodebin)
        .map_err(|e| ComposeError::AppFlow(format!("filesrc→decodebin: {e}")))?;
    gstreamer::Element::link_many([&queue_in, &videoconvert_in, &capsfilter_in]).map_err(|e| {
        ComposeError::AppFlow(format!("link queue_in→videoconvert_in→capsfilter: {e}"))
    })?;
    capsfilter_in
        .link(&appsink)
        .map_err(|e| ComposeError::AppFlow(format!("link capsfilter→appsink: {e}")))?;

    // Static links downstream of appsrc.
    gstreamer::Element::link_many([
        appsrc.upcast_ref::<gstreamer::Element>(),
        &videoconvert_out,
        &capsfilter_yuv,
        &video_enc,
        &h264parse,
        &qtmux,
        &filesink,
    ])
    .map_err(|e| ComposeError::AppFlow(format!("link out chain: {e}")))?;

    // Dynamic decodebin → queue_in (video) or fakesink (audio).
    // Audio pads with no downstream sink are FATAL — GStreamer aborts the
    // pipeline with "Internal data flow error". Always attach a fakesink.
    let queue_in_sink = queue_in
        .static_pad("sink")
        .ok_or_else(|| ComposeError::AppFlow("queue_in has no sink pad".into()))?;
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
            if pad.link(&queue_in_sink).is_err() {
                tracing::warn!(target: "compose", "failed to link decoded video pad");
            }
        } else {
            // Audio (or anything else) — drain into a fakesink so the
            // pipeline doesn't stall with "Internal data flow error".
            let Some(pipeline) = pipeline_weak.upgrade() else {
                return;
            };
            let fakesink = match gstreamer::ElementFactory::make("fakesink")
                .property("sync", false)
                .property("async", false)
                .build()
            {
                Ok(f) => f,
                Err(e) => {
                    tracing::warn!(target: "compose", error = %e, "failed to create fakesink");
                    return;
                }
            };
            if pipeline.add(&fakesink).is_err() {
                return;
            }
            if fakesink.sync_state_with_parent().is_err() {
                return;
            }
            let Some(sink_pad) = fakesink.static_pad("sink") else {
                return;
            };
            if pad.link(&sink_pad).is_err() {
                tracing::warn!(target: "compose", media = %media, "failed to drain non-video pad");
            }
        }
    });

    // Frame loop: pull RGBA frame from appsink, push to appsrc, repeat until EOS.
    // CLONE appsrc separately for each closure — single shared variable would
    // be moved by `new_sample` and `eos` couldn't capture it.
    let appsrc_drive = appsrc.clone();
    let appsrc_eos = appsrc.clone();
    let pts_state = Arc::new(Mutex::new(0_u64));
    // Default 30fps; replaced on first frame from negotiated source caps.
    let frame_duration_state = Arc::new(Mutex::new(33_333_333_u64));
    let frame_duration_set = frame_duration_state.clone();
    let frame_duration_read = frame_duration_state.clone();
    // Track whether we've forwarded the source's caps to appsrc yet. Without
    // explicit width/height/framerate on appsrc, downstream videoconvert →
    // encoder can't negotiate and the pipeline stalls before a single frame
    // reaches filesink (manifests as a "timeout waiting for filesink EOS").
    let caps_forwarded = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let caps_forwarded_set = caps_forwarded.clone();

    appsink.set_callbacks(
        gstreamer_app::AppSinkCallbacks::builder()
            .new_preroll(|sink| {
                // Drain the preroll sample so appsink can transition past
                // preroll into PLAYING. Without this, the first buffer is
                // held as preroll and new_sample never fires.
                let _ = sink.pull_preroll();
                Ok(gstreamer::FlowSuccess::Ok)
            })
            .new_sample(move |sink| {
                let sample = sink.pull_sample().map_err(|_| gstreamer::FlowError::Eos)?;

                // Read framerate from the negotiated sample caps on the FIRST
                // frame. The capsfilter forces RGBA but width/height/framerate
                // come from upstream caps negotiation. Hardcoding 30fps would
                // produce a 2x-slow output for a 60fps source.
                if let Some(caps) = sample.caps() {
                    if let Some(structure) = caps.structure(0) {
                        if let Ok(fr) = structure.get::<gstreamer::Fraction>("framerate") {
                            let num = fr.numer() as u64;
                            let den = fr.denom() as u64;
                            if num > 0 {
                                let dur = 1_000_000_000_u64 * den / num;
                                *frame_duration_set.lock().expect("fd lock") = dur;
                            }
                        }
                    }

                    // Forward the FULL caps (incl. width/height/framerate)
                    // to appsrc once, on the first frame. This lets downstream
                    // negotiate; without it the pipeline stalls.
                    if !caps_forwarded_set.load(std::sync::atomic::Ordering::SeqCst) {
                        let owned = caps.to_owned();
                        appsrc_drive.set_caps(Some(&owned));
                        caps_forwarded_set.store(true, std::sync::atomic::Ordering::SeqCst);
                    }
                }

                let buffer = sample.buffer().ok_or(gstreamer::FlowError::Error)?;
                let in_map = buffer
                    .map_readable()
                    .map_err(|_| gstreamer::FlowError::Error)?;

                let mut out_buf = gstreamer::Buffer::with_size(in_map.size())
                    .map_err(|_| gstreamer::FlowError::Error)?;
                {
                    let buf_mut = out_buf.get_mut().ok_or(gstreamer::FlowError::Error)?;
                    let mut out_map = buf_mut
                        .map_writable()
                        .map_err(|_| gstreamer::FlowError::Error)?;
                    out_map.copy_from_slice(&in_map);
                    drop(out_map);
                    let frame_duration_ns = *frame_duration_read.lock().expect("fd read lock");
                    let mut pts = pts_state.lock().expect("pts state lock");
                    buf_mut.set_pts(gstreamer::ClockTime::from_nseconds(*pts));
                    buf_mut.set_duration(gstreamer::ClockTime::from_nseconds(frame_duration_ns));
                    *pts += frame_duration_ns;
                }

                appsrc_drive
                    .push_buffer(out_buf)
                    .map_err(|_| gstreamer::FlowError::Error)?;
                Ok(gstreamer::FlowSuccess::Ok)
            })
            .eos(move |_sink| {
                let _ = appsrc_eos.end_of_stream();
            })
            .build(),
    );

    pipeline
        .set_state(gstreamer::State::Playing)
        .map_err(|e| ComposeError::StateChange(format!("PLAYING: {e:?}")))?;

    // Wait for the FILESINK to receive EOS (i.e. the muxed file is fully
    // written).
    let bus = pipeline.bus().expect("pipeline bus");
    let deadline = std::time::Instant::now() + Duration::from_secs(180);
    loop {
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        if remaining.is_zero() {
            pipeline.set_state(gstreamer::State::Null).ok();
            return Err(ComposeError::AppFlow(
                "timeout waiting for filesink EOS".into(),
            ));
        }
        if let Some(msg) = bus.timed_pop_filtered(
            gstreamer::ClockTime::from_seconds(1),
            &[gstreamer::MessageType::Eos, gstreamer::MessageType::Error],
        ) {
            match msg.view() {
                // GStreamer aggregates per-element EOS into a single pipeline-
                // level EOS once all sinks finish. That's our cue.
                gstreamer::MessageView::Eos(_) => break,
                gstreamer::MessageView::Error(err) => {
                    pipeline.set_state(gstreamer::State::Null).ok();
                    return Err(ComposeError::AppFlow(format!("pipeline error: {err}")));
                }
                _ => continue,
            }
        }
    }

    pipeline
        .set_state(gstreamer::State::Null)
        .map_err(|e| ComposeError::StateChange(format!("NULL: {e:?}")))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn fixture(name: &str) -> PathBuf {
        let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        p.push("../../fixtures");
        p.push(name);
        p
    }

    #[test]
    fn passthrough_source_to_mov() {
        // Disable macOS VideoToolbox plugins for tests. vtdec_hw / vtenc_h264
        // require a Cocoa NSApplication runloop on the main thread, which
        // cargo's test harness does NOT provide.
        std::env::set_var(
            "GST_PLUGIN_FEATURE_RANK",
            "vtdec_hw:NONE,vtenc_h264:NONE,vtenc_h264_hw:NONE",
        );
        let tmp_dir = tempfile::tempdir().unwrap();
        let out = tmp_dir.path().join("passthrough.mov");
        passthrough_one_file(&fixture("source-1080p.mp4"), &out).unwrap();
        let metadata = std::fs::metadata(&out).unwrap();
        assert!(
            metadata.len() > 100_000,
            "output too small: {} bytes",
            metadata.len()
        );
    }

    /// HYPOTHESIS TEST: prove that the input chain alone (no output appsrc/encoder)
    /// produces buffers freely. If `new_sample` fires for many frames here but
    /// only fires once in `passthrough_source_to_mov`, the bottleneck is the
    /// output chain blocking the input chain (chicken-and-egg via appsrc).
    #[test]
    fn input_chain_only_streams_freely() {
        std::env::set_var(
            "GST_PLUGIN_FEATURE_RANK",
            "vtdec_hw:NONE,vtenc_h264:NONE,vtenc_h264_hw:NONE",
        );
        crate::init().unwrap();

        let pipeline = gstreamer::Pipeline::new();
        let filesrc = gstreamer::ElementFactory::make("filesrc")
            .property("location", fixture("source-1080p.mp4").to_str().unwrap())
            .build()
            .unwrap();
        let decodebin = make_or("decodebin").unwrap();
        let queue_in = make_or("queue").unwrap();
        let videoconvert = make_or("videoconvert").unwrap();
        let capsfilter = gstreamer::ElementFactory::make("capsfilter")
            .property(
                "caps",
                gstreamer::Caps::from_str("video/x-raw,format=RGBA").unwrap(),
            )
            .build()
            .unwrap();
        let appsink = AppSink::builder().sync(false).build();

        pipeline
            .add_many([
                &filesrc,
                &decodebin,
                &queue_in,
                &videoconvert,
                &capsfilter,
                appsink.upcast_ref::<gstreamer::Element>(),
            ])
            .unwrap();
        filesrc.link(&decodebin).unwrap();
        gstreamer::Element::link_many([&queue_in, &videoconvert, &capsfilter]).unwrap();
        capsfilter.link(&appsink).unwrap();

        let queue_sink_pad = queue_in.static_pad("sink").unwrap();
        let pipeline_weak = pipeline.downgrade();
        decodebin.connect_pad_added(move |_dbin, pad| {
            let Some(caps) = pad.current_caps() else {
                return;
            };
            let Some(structure) = caps.structure(0) else {
                return;
            };
            if structure.name().to_string().starts_with("video/") {
                let _ = pad.link(&queue_sink_pad);
            } else {
                let Some(pipeline) = pipeline_weak.upgrade() else {
                    return;
                };
                let fakesink = gstreamer::ElementFactory::make("fakesink")
                    .property("sync", false)
                    .property("async", false)
                    .build()
                    .unwrap();
                pipeline.add(&fakesink).unwrap();
                fakesink.sync_state_with_parent().unwrap();
                let _ = pad.link(&fakesink.static_pad("sink").unwrap());
            }
        });

        let count = Arc::new(std::sync::atomic::AtomicU64::new(0));
        let count_cb = count.clone();
        appsink.set_callbacks(
            gstreamer_app::AppSinkCallbacks::builder()
                .new_preroll(|sink| {
                    let _ = sink.pull_preroll();
                    Ok(gstreamer::FlowSuccess::Ok)
                })
                .new_sample(move |sink| {
                    let _ = sink.pull_sample().map_err(|_| gstreamer::FlowError::Eos)?;
                    count_cb.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    Ok(gstreamer::FlowSuccess::Ok)
                })
                .build(),
        );

        pipeline.set_state(gstreamer::State::Playing).unwrap();
        let bus = pipeline.bus().unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(15);
        loop {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero() {
                break;
            }
            if let Some(msg) = bus.timed_pop_filtered(
                gstreamer::ClockTime::from_seconds(1),
                &[gstreamer::MessageType::Eos, gstreamer::MessageType::Error],
            ) {
                match msg.view() {
                    gstreamer::MessageView::Eos(_) => break,
                    gstreamer::MessageView::Error(e) => panic!("pipeline error: {e}"),
                    _ => continue,
                }
            }
        }
        pipeline.set_state(gstreamer::State::Null).unwrap();
        let n = count.load(std::sync::atomic::Ordering::SeqCst);
        eprintln!("input-chain-only buffers received: {n}");
        assert!(
            n > 100,
            "expected hundreds of buffers from a 60s 30fps video; got {n}"
        );
    }
}
