use tracing_subscriber::{fmt, prelude::*, EnvFilter};

use crate::event_layer::ForwardLayer;

pub fn init(json: bool, forward: Option<ForwardLayer>) {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    let registry = tracing_subscriber::registry().with(filter).with(forward);
    if json {
        // JSON-lines on stdout — what the harness consumes.
        registry
            .with(fmt::layer().json().with_writer(std::io::stdout))
            .init();
    } else {
        // Human-readable on stderr for dev runs.
        registry
            .with(fmt::layer().with_writer(std::io::stderr))
            .init();
    }
}
