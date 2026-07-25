//! The panel's HTTP surface.
//!
//! Everything is mounted under `--base-path`, because the daemon forwards that
//! subtree verbatim and strips nothing. The panel therefore sees the same paths
//! a browser asked for, and builds its own links from configuration rather than
//! from whatever the request happened to carry.

pub mod api;
pub mod auth;
pub mod pair_links;
pub mod session;

use std::sync::Arc;

use axum::Router;
use axum::extract::{Request, State};
use axum::http::{HeaderValue, StatusCode, header};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};

use crate::assets::PanelAssets;
use crate::config::daemon::DaemonConfig;
use crate::config::{CompanionAuthDigest, PanelConfig};
use crate::daemon_client::DaemonClient;
use crate::error::PanelError;
use crate::github::GitHubClient;
use crate::store::Store;

/// Everything a handler needs, cheap to clone per request.
#[derive(Debug, Clone)]
pub struct PanelState {
    pub config: Arc<PanelConfig>,
    pub store: Store,
    pub github: Arc<GitHubClient>,
    pub assets: Arc<PanelAssets>,
    pub daemon: Arc<DaemonRuntime>,
}

/// The daemon connection, kept together so a handler cannot reach for a client
/// built from one configuration and settings from another.
#[derive(Debug)]
pub struct DaemonRuntime {
    pub client: DaemonClient,
    pub config: DaemonConfig,
}

impl PanelState {
    /// Assemble the shared state from a resolved configuration.
    ///
    /// # Errors
    /// Returns [`PanelError`] when the embedded bundle or the GitHub client
    /// cannot be prepared.
    pub fn new(config: PanelConfig, store: Store) -> Result<Self, PanelError> {
        let assets = PanelAssets::new(&config.base_path)?;
        let github = GitHubClient::new(config.github.clone(), config.callback_url())?;
        let daemon = DaemonRuntime {
            client: DaemonClient::new(&config.daemon)?,
            config: config.daemon.clone(),
        };
        Ok(Self {
            config: Arc::new(config),
            store,
            github: Arc::new(github),
            assets: Arc::new(assets),
            daemon: Arc::new(daemon),
        })
    }
}

/// Build the panel router, mounted under the configured base path.
///
/// The paths are spelled out in full rather than nested, because the daemon
/// forwards the prefix verbatim and the panel answers on exactly the paths a
/// browser asked for. Nesting would also leave `{base}` and `{base}/` as two
/// different routes, only one of which is reachable.
pub fn router(state: PanelState) -> Router {
    let base = state.config.base_path.clone();
    let companion_auth = state.config.companion_auth.clone();

    Router::new()
        .route(&format!("{base}/healthz"), get(api::healthz))
        .route(&format!("{base}/api/me"), get(api::me))
        .route(&format!("{base}/api/accounts"), get(api::accounts))
        .route(
            &format!("{base}/api/accounts/{{id}}/approve"),
            post(api::approve),
        )
        .route(
            &format!("{base}/api/accounts/{{id}}/revoke"),
            post(api::revoke),
        )
        .route(&format!("{base}/auth/github/start"), get(auth::start))
        .route(&format!("{base}/auth/github/callback"), get(auth::callback))
        .route(&format!("{base}/auth/signout"), post(auth::signout))
        .route(&format!("{base}/api/pair-links"), post(pair_links::create))
        .route(&base, get(api::index))
        .route(&format!("{base}/"), get(api::index))
        // Anything else under the mount point is either a bundled file or a
        // route the single-page app owns, and only the app can tell which.
        .route(&format!("{base}/{{*asset}}"), get(api::asset_or_index))
        .with_state(state)
        .layer(middleware::from_fn_with_state(
            companion_auth,
            require_companion_auth,
        ))
}

async fn require_companion_auth(
    State(expected): State<CompanionAuthDigest>,
    request: Request,
    next: Next,
) -> Response {
    let mut values = request.headers().get_all(header::AUTHORIZATION).iter();
    let presented = values.next().map(HeaderValue::as_bytes);
    let exactly_one = values.next().is_none();
    let valid = presented
        .and_then(|value| value.strip_prefix(b"Bearer "))
        .is_some_and(|token| exactly_one && expected.matches(token));

    if !valid {
        return (
            StatusCode::UNAUTHORIZED,
            [(header::WWW_AUTHENTICATE, "Bearer")],
        )
            .into_response();
    }

    next.run(request).await
}

#[cfg(test)]
mod tests;
