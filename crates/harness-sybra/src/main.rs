use std::net::SocketAddr;
use std::path::PathBuf;
use std::process::ExitCode;

use clap::Parser;
use harness_sybra::{SybraBrowserToken, SybraGateway, SybraGatewayConfig, sybra_routes};
use tokio::net::TcpListener;
use tracing_subscriber::EnvFilter;

#[derive(Debug, Parser)]
#[command(name = "harness-sybra", version, about = "Local Harness Sybra gateway")]
struct Cli {
    /// Numeric loopback listener. Port zero selects an ephemeral port.
    #[arg(long, default_value = "127.0.0.1:0")]
    listen: SocketAddr,
    /// Numeric loopback HTTP origin of the private Sybra backend.
    #[arg(long)]
    upstream: String,
    /// Private bearer token presented only to the Sybra backend.
    #[arg(long)]
    upstream_token_file: PathBuf,
    /// Private bearer token accepted from the local browser.
    #[arg(long)]
    browser_token_file: PathBuf,
}

#[tokio::main]
async fn main() -> ExitCode {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .try_init();
    let cli = Cli::parse();
    match run(cli).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            tracing::error!(%error, "Sybra gateway stopped");
            ExitCode::FAILURE
        }
    }
}

async fn run(cli: Cli) -> Result<(), Box<dyn std::error::Error>> {
    if !cli.listen.ip().is_loopback() {
        return Err("Sybra listener must use a numeric loopback address".into());
    }
    let config =
        SybraGatewayConfig::from_private_token_file(&cli.upstream, &cli.upstream_token_file)?;
    config.reject_listener_loop(cli.listen)?;
    let browser_token = SybraBrowserToken::from_private_file(&cli.browser_token_file)?;
    let listener = TcpListener::bind(cli.listen).await?;
    let address = listener.local_addr()?;
    let router = sybra_routes(SybraGateway::new(config), browser_token);
    tracing::info!(%address, "Sybra gateway listening");
    axum::serve(listener, router).await?;
    Ok(())
}
