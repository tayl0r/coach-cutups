use clap::Parser;

#[derive(Debug, Parser)]
#[command(name = "video-coach", about = "Video tagging and export tool")]
pub struct Args {
    /// Emit logs as JSON-lines on stdout instead of human-readable on stderr.
    /// Required for the harness to parse lifecycle events.
    #[arg(long)]
    pub json_logs: bool,

    /// Bind a TCP control socket on 127.0.0.1 at the given port (0 = OS-chosen).
    /// Compiled out in release builds.
    #[cfg(feature = "control-socket")]
    #[arg(long)]
    pub control_socket: Option<u16>,

    /// Skip Slint UI initialization. Independent of `--control-socket`:
    /// the socket can drive a real GUI app for debugging, or a headless
    /// app for tests. Tests pass `--headless` plus `--control-socket`.
    #[arg(long)]
    pub headless: bool,
}
