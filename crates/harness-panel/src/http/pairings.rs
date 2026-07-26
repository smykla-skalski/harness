//! What the links became, and withdrawing one.
//!
//! The daemon is the authority on state: a pairing revoked on the host reads as
//! revoked here because this asks the daemon rather than reporting what the
//! panel wrote down when it minted. The panel's own table contributes the one
//! fact the daemon does not hold, which is the account each link was minted
//! for, and that is what decides whose rows a person sees and what they may
//! withdraw.

use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;
use serde::Serialize;

use super::PanelState;
use super::api::private_json;
use super::auth::origin_matches;
use super::session::{Viewer, require_viewer};
use crate::daemon_client::DaemonCredential;
use crate::daemon_client::pairings::{DaemonPairing, DaemonRevoke, RevokeError};
use crate::error::ApiError;

/// One pairing as the page receives it.
///
/// The daemon's own fields are flattened through rather than restated, so a
/// state or a device field it grows arrives without the panel having to learn
/// about it first.
#[derive(Debug, Serialize)]
struct PanelPairing {
    #[serde(flatten)]
    pairing: DaemonPairing,
    /// The account this link was minted for. Absent for one the panel has no
    /// record of, which only the owner is shown at all.
    #[serde(skip_serializing_if = "Option::is_none")]
    account_id: Option<String>,
}

#[derive(Debug, Serialize)]
struct PairingsBody {
    pairings: Vec<PanelPairing>,
}

/// The pairings this person is entitled to see: their own, or everyone's for
/// the owner.
///
/// # Errors
/// Returns [`ApiError::Unauthenticated`] when signed out,
/// [`ApiError::Unavailable`] when the panel has no daemon credential yet, and
/// [`ApiError::Internal`] when the daemon cannot be reached.
pub async fn list(
    State(state): State<PanelState>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let viewer = require_viewer(&state, &headers).await?;
    let credential = require_credential(&state).await?;

    // The daemon narrows by client, and the panel is one client for everybody
    // who signs in, so it answers with every link the panel ever minted however
    // little of it this person may see. Asking it to narrow further is not on
    // offer: it has never been told which account any of them belongs to.
    let pairings = state.daemon.client.pairings(&credential).await?;
    let accounts = state.store.pair_link_accounts().await?;

    let pairings = pairings
        .into_iter()
        .map(|pairing| {
            let account_id = accounts.get(&pairing.pairing_id).cloned();
            PanelPairing {
                pairing,
                account_id,
            }
        })
        .filter(|entry| visible_to(&viewer, entry))
        .collect();

    Ok(private_json(&PairingsBody { pairings }))
}

/// Whether this person may see this row.
///
/// A pairing the panel has no record of has no account to compare against, so
/// only the owner sees it. That is the safe direction and the only honest one:
/// the panel does not know who it was minted for, and showing it to whoever
/// asks would put one person's device on another's page.
fn visible_to(viewer: &Viewer, entry: &PanelPairing) -> bool {
    viewer.is_owner || entry.account_id.as_deref() == Some(viewer.account.id.as_str())
}

/// Cut off a device, or withdraw a link nobody claimed.
///
/// # Errors
/// Returns [`ApiError::Forbidden`] when the request did not come from the panel
/// origin or the pairing is not this person's to withdraw,
/// [`ApiError::Unavailable`] when the panel has no daemon credential yet, and
/// [`ApiError::Internal`] when the daemon cannot be reached.
pub async fn revoke(
    State(state): State<PanelState>,
    headers: HeaderMap,
    Path(pairing_id): Path<String>,
) -> Result<Response, ApiError> {
    // `SameSite` cookies cross between sibling origins, so a state-changing
    // request must also prove it came from this panel.
    if !origin_matches(&headers, &state.config.public_origin) {
        return Err(ApiError::Forbidden(
            "unpair requests must come from the panel origin",
        ));
    }
    let viewer = require_viewer(&state, &headers).await?;
    require_may_revoke(&state, &viewer, &pairing_id).await?;

    let credential = require_credential(&state).await?;
    let revoked = state
        .daemon
        .client
        .revoke_pairing(&credential, &pairing_id)
        .await
        .map_err(|error| match error {
            // The daemon reached the same conclusion the panel just did, from
            // its own records. It is not a new fact for the caller, so it gets
            // the same answer as an id the panel could not place.
            RevokeError::NotAvailable => NOT_AVAILABLE,
            RevokeError::Failed(error) => ApiError::Internal(error),
        })?;

    record_revoke(&viewer, &revoked);
    Ok(private_json(&revoked))
}

/// One answer for a pairing that is somebody else's and for one that does not
/// exist.
///
/// Telling them apart would let any approved account walk the id space and
/// learn which pairings the panel has issued. The wording asserts neither.
const NOT_AVAILABLE: ApiError =
    ApiError::Forbidden("no pairing with that id is available to this account");

/// Refuse a pairing that is not this person's.
///
/// The check is the panel's alone. The daemon sees one broker credential for
/// the whole panel and cannot tell one signed-in account from another, so
/// leaving this to the daemon would let any approved account withdraw anybody
/// else's device.
async fn require_may_revoke(
    state: &PanelState,
    viewer: &Viewer,
    pairing_id: &str,
) -> Result<(), ApiError> {
    if viewer.is_owner {
        return Ok(());
    }
    let account_id = state.store.pair_link_account(pairing_id).await?;
    if account_id.as_deref() == Some(viewer.account.id.as_str()) {
        return Ok(());
    }
    Err(NOT_AVAILABLE)
}

async fn require_credential(state: &PanelState) -> Result<DaemonCredential, ApiError> {
    state
        .store
        .daemon_credential()
        .await?
        .ok_or(ApiError::Unavailable(
            "the panel has not paired with the daemon yet",
        ))
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn record_revoke(viewer: &Viewer, revoked: &DaemonRevoke) {
    tracing::info!(
        login = %viewer.account.login,
        pairing_id = %revoked.pairing_id,
        outcome = %revoked.outcome,
        "panel revoked a pairing"
    );
}
