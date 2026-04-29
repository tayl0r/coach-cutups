use crate::source::CaptureSourceFactory;
use gstreamer::prelude::*;
use gstreamer::{Bin, GhostPad};
use std::path::PathBuf;

/// File-backed source for tests. Reads a single mov/mp4, decodes it, and
/// re-publishes raw video + audio pads named `video-src` and `audio-src`.
pub struct FixtureSource {
    pub path: PathBuf,
    pub name: String,
}

impl FixtureSource {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        let path = path.into();
        let name = format!("fixture:{}", path.display());
        Self { path, name }
    }
}

impl CaptureSourceFactory for FixtureSource {
    fn name(&self) -> &str {
        &self.name
    }

    fn build(&self) -> Result<Bin, gstreamer::glib::BoolError> {
        let bin = Bin::new();

        let filesrc = gstreamer::ElementFactory::make("filesrc")
            .property("location", self.path.to_str().expect("utf8 path"))
            .build()
            .expect("filesrc");
        let decodebin = gstreamer::ElementFactory::make("decodebin")
            .build()
            .expect("decodebin");

        bin.add_many([&filesrc, &decodebin])?;
        filesrc.link(&decodebin)?;

        let bin_weak = bin.downgrade();
        decodebin.connect_pad_added(move |_dbin, pad| {
            let Some(bin) = bin_weak.upgrade() else {
                return;
            };
            let Some(caps) = pad.current_caps() else {
                return;
            };
            let Some(structure) = caps.structure(0) else {
                return;
            };
            let media_type = structure.name().to_string();

            let (convert_factory, ghost_name) = if media_type.starts_with("video/") {
                ("videoconvert", "video-src")
            } else if media_type.starts_with("audio/") {
                ("audioconvert", "audio-src")
            } else {
                return;
            };

            let convert = gstreamer::ElementFactory::make(convert_factory)
                .build()
                .expect("convert factory");
            bin.add(&convert).expect("add convert");
            convert.sync_state_with_parent().expect("sync state");

            let sink_pad = convert.static_pad("sink").expect("convert sink pad");
            pad.link(&sink_pad).expect("link decoded pad");

            // CRITICAL: name the ghost pad explicitly. `GhostPad::with_target`
            // takes the target pad's name (always `"src"` here), so without an
            // override both video and audio ghost pads would collide and the
            // recording pipeline's pad_added handler (which dispatches by
            // ghost-pad name) would fail to link, yielding an empty .mov.
            let src_pad = convert.static_pad("src").expect("convert src pad");
            let ghost = GhostPad::builder_with_target(&src_pad)
                .expect("ghost builder")
                .name(ghost_name)
                .build();
            ghost.set_active(true).expect("set ghost active");
            bin.add_pad(&ghost).expect("add ghost pad");
        });

        Ok(bin)
    }
}

#[cfg(test)]
#[cfg(feature = "media")]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn fixtures_dir() -> PathBuf {
        let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        p.push("../../fixtures");
        p
    }

    #[test]
    fn build_succeeds_against_real_fixture() {
        crate::init().unwrap();
        let src = FixtureSource::new(fixtures_dir().join("webcam.mov"));
        let _bin = src.build().unwrap();
    }
}
