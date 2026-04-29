use crate::source::CaptureSourceFactory;
use std::path::{Path, PathBuf};
use std::sync::Arc;
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

pub fn start(
    factory: Arc<dyn CaptureSourceFactory>,
    output_path: PathBuf,
) -> Result<Recording, RecordingError> {
    crate::init()?;
    let _ = factory; // wired in Task 5
    let _ = &output_path;
    Err(RecordingError::Build("not implemented yet".into()))
}

impl Recording {
    pub fn output_path(&self) -> &Path {
        &self.output_path
    }

    pub fn stop(self) -> Result<(), RecordingError> {
        let _ = self.pipeline;
        Err(RecordingError::Build("not implemented yet".into()))
    }
}
