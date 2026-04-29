mod bus;
mod cli;
mod logging;
mod protocol;

use clap::Parser;
use cli::Args;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    logging::init(args.json_logs);
    tracing::info!(target: "app.lifecycle", event = "app.launched", version = env!("CARGO_PKG_VERSION"));

    let (shutdown_tx, mut shutdown_rx) = tokio::sync::watch::channel(false);
    let _bus = bus::spawn(shutdown_tx.clone());

    // For now: wait for shutdown signal (Ctrl-C, or future Quit command).
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {
            tracing::info!(target: "app.lifecycle", event = "app.shutdown_requested", source = "signal");
        }
        _ = shutdown_rx.changed() => {
            // shutdown_tx was triggered (Quit command).
        }
    }

    tracing::info!(target: "app.lifecycle", event = "app.shutdown");
    Ok(())
}
