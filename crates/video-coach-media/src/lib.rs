// Modules added in subsequent tasks.

#[cfg(feature = "media")]
pub mod compose;
pub mod fixture_source;
pub mod recording;
pub mod source;

/// Initialize GStreamer once per process. Idempotent — safe to call from
/// every entry point. Required before any pipeline construction.
pub fn init() -> Result<(), gstreamer::glib::Error> {
    gstreamer::init()
}

#[cfg(test)]
mod tests {
    #[test]
    fn gstreamer_init_succeeds() {
        super::init().unwrap();
    }
}
