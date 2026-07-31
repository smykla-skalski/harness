use std::process::ExitCode;

use clap::Parser;
use harness_sybra::cli::Cli;
use harness_sybra::{SybraBrowserToken, SybraGateway, SybraGatewayConfig, sybra_routes};
use tokio::net::TcpListener;
use tracing_subscriber::EnvFilter;

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
    let browser_token = SybraBrowserToken::from_private_file(&cli.browser_token_file)?;
    config.reject_matching_browser_token(&browser_token)?;
    let listener = TcpListener::bind(cli.listen).await?;
    validate_bound_listener(&config, &listener)?;
    let address = listener.local_addr()?;
    let router = sybra_routes(SybraGateway::new(config), browser_token);
    tracing::info!(%address, "Sybra gateway listening");
    axum::serve(listener, router).await?;
    Ok(())
}

fn validate_bound_listener(
    config: &SybraGatewayConfig,
    listener: &TcpListener,
) -> Result<(), Box<dyn std::error::Error>> {
    config.reject_listener_loop(listener.local_addr()?)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt as _;

    use super::*;

    const TOKEN: &str = "standalone-upstream-token-for-main-test";

    #[tokio::test]
    async fn loop_check_uses_the_actual_bound_address() {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("listener");
        let address = listener.local_addr().expect("bound address");
        let directory = tempfile::tempdir().expect("directory");
        let token_path = directory.path().join("upstream-token");
        fs::write(&token_path, TOKEN).expect("write token");
        #[cfg(unix)]
        fs::set_permissions(&token_path, fs::Permissions::from_mode(0o600))
            .expect("token permissions");
        let config =
            SybraGatewayConfig::from_private_token_file(&format!("http://{address}"), &token_path)
                .expect("config");

        let error = validate_bound_listener(&config, &listener).expect_err("loop rejected");
        assert!(!error.to_string().contains(TOKEN));
    }
}
