//! Generating a pairing link for the person asking for it.

use axum::Json;
use axum::extract::State;
use axum::http::{HeaderMap, header};
use axum::response::{IntoResponse, Response};
use chrono::Utc;
use serde::Serialize;

use super::PanelState;
use super::session::require_viewer;
use crate::daemon_client::MintedLink;
use crate::error::ApiError;
use crate::store::pair_links::PairLinkRecord;

#[derive(Debug, Serialize)]
pub struct PairLinkBody {
    /// Shown once. The panel keeps no copy, because it carries a one-time code.
    #[serde(flatten)]
    link: MintedLink,
}

/// Mint a link for the signed-in account.
///
/// The role, scopes, and lifetime come from the panel's configuration, never
/// from the request. A request that could choose them would let any approved
/// account issue itself a credential the owner never agreed to.
///
/// # Errors
/// Returns [`ApiError::Unauthenticated`] when signed out,
/// [`ApiError::Forbidden`] when the account has not been approved,
/// [`ApiError::Unavailable`] when the panel has no daemon credential yet, and
/// [`ApiError::Internal`] when the daemon refuses or cannot be reached.
pub async fn create(
    State(state): State<PanelState>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let viewer = require_viewer(&state, &headers).await?;

    // Read from the account rather than from anything the request carried, and
    // read it now rather than trusting what the session said when it was
    // issued: a revoke that landed a moment ago has to take effect here.
    if !viewer.account.can_pair {
        return Err(ApiError::Forbidden(
            "the panel owner has not allowed this account to generate pairing links",
        ));
    }

    let credential = state
        .store
        .daemon_credential()
        .await?
        .ok_or(ApiError::Unavailable(
            "the panel has not paired with the daemon yet",
        ))?;

    let minted = state
        .daemon
        .client
        .mint(
            &credential,
            &viewer.account,
            &state.daemon.config.link_role,
            state.daemon.config.link_ttl_seconds,
        )
        .await?;

    let now = Utc::now();
    state
        .store
        .record_pair_link(&PairLinkRecord {
            id: minted.pairing_id.clone(),
            account_id: viewer.account.id.clone(),
            role: minted.role.clone(),
            created_at: now,
            expires_at: minted.expires_at,
        })
        .await?;
    record_mint(&viewer.account.login, &minted);

    Ok((
        [(header::CACHE_CONTROL, "no-store")],
        Json(PairLinkBody { link: minted }),
    )
        .into_response())
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn record_mint(login: &str, minted: &MintedLink) {
    // The link itself is never logged: it carries the one-time code, and a log
    // line is the one place it would outlive the response it was shown in.
    tracing::info!(
        login = %login,
        pairing_id = %minted.pairing_id,
        role = %minted.role,
        "panel minted a pairing link"
    );
}
