//! The panel's HTTP surface.
//!
//! Everything is mounted under `--base-path`, because the daemon forwards that
//! subtree verbatim and strips nothing. The panel therefore sees the same paths
//! a browser asked for, and builds its own links from configuration rather than
//! from whatever the request happened to carry.

pub mod api;
pub mod auth;
pub mod session;

use std::sync::Arc;

use axum::Router;
use axum::routing::{get, post};

use crate::assets::PanelAssets;
use crate::config::PanelConfig;
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
        Ok(Self {
            config: Arc::new(config),
            store,
            github: Arc::new(github),
            assets: Arc::new(assets),
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

    Router::new()
        .route(&format!("{base}/healthz"), get(api::healthz))
        .route(&format!("{base}/api/me"), get(api::me))
        .route(&format!("{base}/api/accounts"), get(api::accounts))
        .route(&format!("{base}/auth/github/start"), get(auth::start))
        .route(&format!("{base}/auth/github/callback"), get(auth::callback))
        .route(&format!("{base}/auth/signout"), post(auth::signout))
        .route(&base, get(api::index))
        .route(&format!("{base}/"), get(api::index))
        // Anything else under the mount point is either a bundled file or a
        // route the single-page app owns, and only the app can tell which.
        .route(&format!("{base}/{{*asset}}"), get(api::asset_or_index))
        .with_state(state)
}

#[cfg(test)]
mod tests;
