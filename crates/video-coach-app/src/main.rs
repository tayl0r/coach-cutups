mod cli;
mod logging;

use clap::Parser;
use cli::Args;

fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    logging::init(args.json_logs);
    tracing::info!(target: "app.lifecycle", event = "app.launched", version = env!("CARGO_PKG_VERSION"));
    Ok(())
}
