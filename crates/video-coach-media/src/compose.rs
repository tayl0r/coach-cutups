// crates/video-coach-media/src/compose.rs
//
// The compose pipeline pulls in video-coach-compositor + wgpu, both of which
// are feature-gated via `media`. Gate the entire module so non-media builds
// don't try to import a crate that isn't a dep.
#![allow(clippy::duplicated_attributes)] // intentional belt-and-suspenders with `pub mod compose` cfg
#![cfg(feature = "media")]

use crate::recording::RecordingError;
use std::path::PathBuf;
use thiserror::Error;

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

/// Compose two input video files (source + webcam) into a single output .mov.
/// Phase 5 ignores audio and produces silent video. Output codec: H.264.
pub fn compose_two_files(
    _source: PathBuf,
    _webcam: PathBuf,
    _output: PathBuf,
) -> Result<(), ComposeError> {
    // Real implementation lands in Tasks 3 and 4.
    Err(ComposeError::AppFlow("not implemented yet".into()))
}
