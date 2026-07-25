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

/// How many unexpired links one account may hold.
///
/// A revoke cannot reach a link already minted, so without a cap an approved
/// account, or whoever stole its session, could loop the button and leave the
/// owner with a pile of live credentials to hunt down one at a time. Generous
/// enough for a person pairing several devices, small enough to bound the
/// damage.
const MAX_LIVE_LINKS_PER_ACCOUNT: i64 = 5;

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

    if state
        .store
        .live_pair_link_count(&viewer.account.id, Utc::now())
        .await?
        >= MAX_LIVE_LINKS_PER_ACCOUNT
    {
        return Err(ApiError::Forbidden(
            "this account already holds as many unexpired pairing links as the panel allows; \
             use one or wait for it to expire",
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

    // The daemon has already minted, so the link is live whatever happens next.
    // Failing the response here would leave a claimable one-time code that
    // nobody has seen and the panel has no record of: worse than either problem
    // alone. The record is best-effort and its loss is logged loudly enough for
    // an operator to reconcile against the daemon.
    let recorded = state
        .store
        .record_pair_link(&PairLinkRecord {
            id: minted.pairing_id.clone(),
            account_id: viewer.account.id.clone(),
            role: minted.role.clone(),
            created_at: Utc::now(),
            expires_at: minted.expires_at,
        })
        .await;
    if let Err(error) = recorded {
        record_unrecorded(&viewer.account.login, &minted, &error);
    } else {
        record_mint(&viewer.account.login, &minted);
    }

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

/// A link the daemon issued that the panel could not write down.
///
/// Logged at error level with the pairing id, which is the only handle an
/// operator has for reconciling it against the daemon afterwards.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn record_unrecorded(login: &str, minted: &MintedLink, error: &sqlx::Error) {
    tracing::error!(
        login = %login,
        pairing_id = %minted.pairing_id,
        %error,
        "panel minted a pairing link but could not record it; reconcile against the daemon"
    );
}
