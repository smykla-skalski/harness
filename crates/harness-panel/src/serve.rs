//! Running the panel.

use std::time::Duration;

use chrono::Utc;
use tokio::net::TcpListener;
use tokio::signal;
use tokio::time::interval;

use crate::config::PanelConfig;
use crate::error::PanelError;
use crate::http::{PanelState, router};
use crate::store::Store;

/// How often expired sessions and unfinished sign-ins are reclaimed. Expiry is
/// enforced on every read, so this only frees rows and can be lazy.
const PRUNE_INTERVAL: Duration = Duration::from_mins(15);

/// Open the store, bind the listener, and serve until shutdown.
///
/// # Errors
/// Returns [`PanelError`] when the store cannot be opened, the address cannot
/// be bound, or the server stops with an error.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
pub async fn run(config: PanelConfig) -> Result<(), PanelError> {
    let store = Store::open(&config.state_dir).await?;
    let listen = config.listen;
    let state = PanelState::new(config, store.clone())?;

    if state.assets.is_placeholder() {
        tracing::warn!(
            "this binary was built without the panel's web assets and will serve a placeholder page"
        );
    }

    let listener = TcpListener::bind(listen)
        .await
        .map_err(|source| PanelError::Bind {
            address: listen.to_string(),
            source,
        })?;
    let bound = listener.local_addr().map_err(|source| PanelError::Bind {
        address: listen.to_string(),
        source,
    })?;
    tracing::info!(
        address = %bound,
        base_path = %state.config.base_path,
        public_origin = %state.config.public_origin,
        "panel listening"
    );

    tokio::spawn(prune_loop(store));

    axum::serve(listener, router(state))
        .with_graceful_shutdown(shutdown_signal())
        .await
        .map_err(|source| PanelError::Bind {
            address: bound.to_string(),
            source,
        })
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
async fn prune_loop(store: Store) {
    let mut ticker = interval(PRUNE_INTERVAL);
    // The first tick fires immediately, which clears whatever a previous run
    // left behind before the panel starts adding to it.
    loop {
        ticker.tick().await;
        match store.prune_expired(Utc::now()).await {
            Ok(0) => {}
            Ok(removed) => tracing::debug!(removed, "pruned expired panel rows"),
            Err(error) => tracing::warn!(%error, "pruning expired panel rows failed"),
        }
    }
}

/// Stop on the signals systemd sends, so a restart is not a kill.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
async fn shutdown_signal() {
    let interrupt = async {
        signal::ctrl_c().await.ok();
    };

    #[cfg(unix)]
    let terminate = async {
        let mut stream = match signal::unix::signal(signal::unix::SignalKind::terminate()) {
            Ok(stream) => stream,
            Err(error) => {
                tracing::warn!(%error, "cannot listen for SIGTERM");
                return;
            }
        };
        stream.recv().await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        () = interrupt => {}
        () = terminate => {}
    }
    tracing::info!("panel shutting down");
}
