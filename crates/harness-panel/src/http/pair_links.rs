//! Generating a pairing link for the person asking for it.

use axum::Json;
use axum::extract::State;
use axum::http::{HeaderMap, header};
use axum::response::{IntoResponse, Response};
use chrono::{Duration, Utc};
use serde::Serialize;
use uuid::Uuid;

use super::PanelState;
use super::session::require_viewer;
use crate::daemon_client::{DaemonCredential, MintedLink};
use crate::error::ApiError;
use crate::store::accounts::Account;
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

    let credential = state
        .store
        .daemon_credential()
        .await?
        .ok_or(ApiError::Unavailable(
            "the panel has not paired with the daemon yet",
        ))?;

    // The slot is taken before the daemon is asked, not after it answers.
    // Counting first and inserting afterwards leaves the whole daemon round
    // trip between the two, so a burst of requests would every one of them see
    // the same free slot and every one of them mint.
    let reservation = reservation_for(&viewer.account.id, &state);
    if !state
        .store
        .reserve_pair_link(&reservation, MAX_LIVE_LINKS_PER_ACCOUNT, Utc::now())
        .await?
    {
        return Err(ApiError::Forbidden(
            "this account already holds as many unexpired pairing links as the panel allows; \
             use one or wait for it to expire",
        ));
    }

    let minted = mint_against(&state, &credential, &viewer.account, &reservation.id).await?;
    finalize(&state, &viewer.account, &reservation.id, &minted).await;

    Ok((
        [(header::CACHE_CONTROL, "no-store")],
        Json(PairLinkBody { link: minted }),
    )
        .into_response())
}

/// Ask the daemon for the link this reservation stands for.
///
/// A refusal gives the slot back, because nothing was issued and holding it
/// would cost the account a link it never got. Failing to give it back costs
/// the account that slot only until the reservation lapses, which is why it is
/// recorded rather than allowed to mask the daemon's own failure.
async fn mint_against(
    state: &PanelState,
    credential: &DaemonCredential,
    account: &Account,
    reservation_id: &str,
) -> Result<MintedLink, ApiError> {
    let minted = state
        .daemon
        .client
        .mint(
            credential,
            account,
            &state.daemon.config.link_role,
            state.daemon.config.link_ttl_seconds,
        )
        .await;

    match minted {
        Ok(minted) => Ok(minted),
        Err(error) => {
            if let Err(release) = state.store.release_pair_link(reservation_id).await {
                record_unreleased(reservation_id, &release);
            }
            Err(error.into())
        }
    }
}

/// Write what the daemon issued over the reservation that stood for it.
///
/// The daemon has already minted, so the link is live whatever happens here.
/// Failing the response would leave a claimable one-time code that nobody has
/// seen, which is worse than a row that still reads as a reservation: that row
/// keeps counting against the cap either way, so only the detail is lost, and
/// it is recorded loudly enough to reconcile against the daemon.
async fn finalize(
    state: &PanelState,
    account: &Account,
    reservation_id: &str,
    minted: &MintedLink,
) {
    let recorded = state
        .store
        .finalize_pair_link(
            reservation_id,
            &PairLinkRecord {
                id: minted.pairing_id.clone(),
                account_id: account.id.clone(),
                role: minted.role.clone(),
                created_at: Utc::now(),
                expires_at: minted.expires_at,
            },
        )
        .await;

    if let Err(error) = recorded {
        record_unrecorded(&account.login, minted, &error);
    } else {
        record_mint(&account.login, minted);
    }
}

/// A slot claimed for a link the daemon has not issued yet.
///
/// The id is deliberately not shaped like a daemon pairing id, so a row left
/// behind by a crash reads as what it is rather than as a pairing the daemon
/// has never heard of. It expires on the lifetime the panel is about to ask
/// for, which is the same lifetime the finished link would have carried.
fn reservation_for(account_id: &str, state: &PanelState) -> PairLinkRecord {
    let now = Utc::now();
    // The configuration refuses a TTL above a day, so this never saturates.
    let ttl = i64::try_from(state.daemon.config.link_ttl_seconds).unwrap_or(i64::MAX);
    PairLinkRecord {
        id: format!("reservation:{}", Uuid::new_v4()),
        account_id: account_id.to_owned(),
        role: state.daemon.config.link_role.clone(),
        created_at: now,
        expires_at: now + Duration::seconds(ttl),
    }
}

/// A slot held for a link that was never issued.
///
/// Only costs the account one link until the reservation lapses, so this is
/// recorded rather than raised over the daemon failure that caused it.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn record_unreleased(reservation_id: &str, error: &sqlx::Error) {
    tracing::warn!(
        reservation_id = %reservation_id,
        %error,
        "panel could not release a pairing link reservation; it lapses on its own"
    );
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
