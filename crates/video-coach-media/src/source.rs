use gstreamer::Bin;

/// Builds a GStreamer source bin that produces a video pad and an audio pad.
///
/// The bin's `video-src` ghost pad emits raw video; `audio-src` emits raw audio.
/// Downstream the recording pipeline links to these pads via `videoconvert` /
/// `audioconvert` so encoders see canonical raw formats regardless of the
/// concrete source element.
pub trait CaptureSourceFactory: Send + Sync {
    /// Construct a fresh source bin. Called once per recording.
    fn build(&self) -> Result<Bin, gstreamer::glib::BoolError>;

    /// Human-readable name for tracing events.
    fn name(&self) -> &str;
}
