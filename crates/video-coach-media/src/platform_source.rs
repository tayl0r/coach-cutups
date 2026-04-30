//! Phase 8 Task 2. Platform-default capture source for `Recording`.
//!
//! `PlatformDefaultSource` wires the OS-native GStreamer capture
//! elements (camera + microphone) into a `Bin` whose ghost pads
//! (`video-src`, `audio-src`) match the contract `recording.rs` expects.
//! Selected by `cfg(target_os)` at compile time:
//!
//! | Platform | Video src       | Audio src                                |
//! |----------|-----------------|------------------------------------------|
//! | macOS    | `avfvideosrc`   | `osxaudiosrc` (or `audiotestsrc`)        |
//! | Windows  | `mfvideosrc`    | `wasapisrc` (or `audiotestsrc`)          |
//! | Linux    | `v4l2src`       | `pulsesrc` (or `audiotestsrc`)           |
//!
//! Adversarial-review compliance:
//!
//! - **`VIDEO_COACH_NO_AUDIO=1` substitutes `audiotestsrc` for the
//!   platform audio element.** Mirrors `source_player.rs::
//!   platform_audio_sink_name`'s sink-side switch. CI runners on Linux
//!   have no PulseAudio daemon; without this the `pulsesrc` build would
//!   succeed but the PAUSED→PLAYING transition would fail with a
//!   StateChangeError, hanging the harness E2E. (Phase 7 hit the same
//!   issue with `pulsesink`; this is the source-side cure.)
//!
//! - **macOS `avfvideosrc` blocks on the camera-permission prompt the
//!   first time it's constructed in a freshly-installed binary.** That
//!   blocking happens during `Bin::build()`; the `bus.rs` recording
//!   handler is already off-loaded to `spawn_blocking` so the bus task
//!   isn't held. On Deny, `recording::start` returns Err and the bus
//!   rolls back to Scanning (adversarial fix #10).

#![allow(clippy::duplicated_attributes)] // intentional with `pub mod platform_source` cfg
#![cfg(feature = "media")]

use crate::source::CaptureSourceFactory;
use gstreamer::prelude::*;
use gstreamer::{Bin, GhostPad};

/// Default platform camera + microphone, wired into a `Bin` exposing
/// `video-src` and `audio-src` ghost pads. The `recording.rs` pipeline
/// links those pads via `videoconvert`/`audioconvert` (canonical raw
/// formats), so the precise element flavor varies by OS but the
/// downstream contract is identical.
pub struct PlatformDefaultSource {
    name: String,
}

impl PlatformDefaultSource {
    pub fn new() -> Self {
        Self {
            name: format!(
                "platform-default[{}+{}]",
                platform_video_src_name(),
                platform_audio_src_name(),
            ),
        }
    }
}

impl Default for PlatformDefaultSource {
    fn default() -> Self {
        Self::new()
    }
}

impl CaptureSourceFactory for PlatformDefaultSource {
    fn name(&self) -> &str {
        &self.name
    }

    fn build(&self) -> Result<Bin, gstreamer::glib::BoolError> {
        let bin = Bin::new();

        // Video chain: <platform-src> → videoconvert → ghost(video-src).
        let video_src_factory = platform_video_src_name();
        let video_src = make_video_src(video_src_factory)?;
        let videoconvert = make_or("videoconvert")?;

        bin.add_many([&video_src, &videoconvert])?;
        gstreamer::Element::link_many([&video_src, &videoconvert])?;

        let video_src_pad = videoconvert
            .static_pad("src")
            .ok_or_else(|| gstreamer::glib::bool_error!("videoconvert has no src pad"))?;
        let video_ghost = GhostPad::builder_with_target(&video_src_pad)?
            .name("video-src")
            .build();
        video_ghost.set_active(true)?;
        bin.add_pad(&video_ghost)?;

        // Audio chain: <platform-src or audiotestsrc> → audioconvert →
        // ghost(audio-src). `audiotestsrc` produces a silent (volume=0)
        // tone so the mux still finalizes a valid audio track when the
        // env var is set; without `is-live=true` it'd push buffers as
        // fast as the encoder consumed them and run far ahead of the
        // video clock.
        let audio_src_factory = platform_audio_src_name();
        let audio_src = make_audio_src(audio_src_factory)?;
        let audioconvert = make_or("audioconvert")?;

        bin.add_many([&audio_src, &audioconvert])?;
        gstreamer::Element::link_many([&audio_src, &audioconvert])?;

        let audio_src_pad = audioconvert
            .static_pad("src")
            .ok_or_else(|| gstreamer::glib::bool_error!("audioconvert has no src pad"))?;
        let audio_ghost = GhostPad::builder_with_target(&audio_src_pad)?
            .name("audio-src")
            .build();
        audio_ghost.set_active(true)?;
        bin.add_pad(&audio_ghost)?;

        Ok(bin)
    }
}

fn make_or(name: &str) -> Result<gstreamer::Element, gstreamer::glib::BoolError> {
    gstreamer::ElementFactory::make(name)
        .build()
        .map_err(|_| gstreamer::glib::bool_error!("missing element factory: {}", name))
}

/// Build the platform video source. Linux's `v4l2src` needs a `device`
/// property; macOS/Windows pick the system default automatically.
fn make_video_src(name: &str) -> Result<gstreamer::Element, gstreamer::glib::BoolError> {
    if cfg!(target_os = "linux") && name == "v4l2src" {
        return gstreamer::ElementFactory::make(name)
            .property("device", "/dev/video0")
            .build()
            .map_err(|_| gstreamer::glib::bool_error!("missing element factory: {}", name));
    }
    make_or(name)
}

/// Build the platform audio source. `audiotestsrc` (the no-audio fallback)
/// needs `is-live=true`; without it the source produces buffers without
/// real-time pacing and the encoder backs up.
fn make_audio_src(name: &str) -> Result<gstreamer::Element, gstreamer::glib::BoolError> {
    if name == "audiotestsrc" {
        return gstreamer::ElementFactory::make(name)
            .property("is-live", true)
            // volume=0 — silent track but still produces buffers so the
            // mux finalizes both pads. Real silence is what the test
            // wants; not a hum.
            .property("volume", 0.0_f64)
            .build()
            .map_err(|_| gstreamer::glib::bool_error!("missing element factory: {}", name));
    }
    make_or(name)
}

fn platform_video_src_name() -> &'static str {
    if cfg!(target_os = "macos") {
        "avfvideosrc"
    } else if cfg!(target_os = "windows") {
        "mfvideosrc"
    } else {
        "v4l2src"
    }
}

/// Mirror of `source_player::platform_audio_sink_name` for the source
/// side. Adversarial-review fix #3: `VIDEO_COACH_NO_AUDIO=1` swaps in
/// `audiotestsrc` so the Linux CI runner doesn't hang on a missing
/// PulseAudio daemon.
fn platform_audio_src_name() -> &'static str {
    if std::env::var("VIDEO_COACH_NO_AUDIO").is_ok() {
        return "audiotestsrc";
    }
    if cfg!(target_os = "macos") {
        "osxaudiosrc"
    } else if cfg!(target_os = "windows") {
        "wasapisrc"
    } else {
        "pulsesrc"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn platform_audio_src_with_no_audio_env_returns_audiotestsrc() {
        // SAFETY: tests in the same crate run sequentially by default
        // (cargo test isn't multi-threaded across #[test]s in the same
        // process unless we explicitly opt out), and we restore the
        // var before returning.
        let prev = std::env::var("VIDEO_COACH_NO_AUDIO").ok();
        // SAFETY: env mutation in tests; single-threaded test runner.
        unsafe {
            std::env::set_var("VIDEO_COACH_NO_AUDIO", "1");
        }
        assert_eq!(platform_audio_src_name(), "audiotestsrc");
        // SAFETY: see above.
        unsafe {
            match prev {
                Some(v) => std::env::set_var("VIDEO_COACH_NO_AUDIO", v),
                None => std::env::remove_var("VIDEO_COACH_NO_AUDIO"),
            }
        }
    }

    #[test]
    fn platform_video_src_name_is_known() {
        // Compile-time exhaustive: just verify the static returns a
        // recognizable name for the current target.
        let name = platform_video_src_name();
        assert!(matches!(name, "avfvideosrc" | "mfvideosrc" | "v4l2src"));
    }
}
