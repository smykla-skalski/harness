//! Generating a pairing link for the person asking for it.

use axum::Json;
use axum::extract::State;
use axum::http::{HeaderMap, header};
use axum::response::{IntoResponse, Response};
use chrono::{Duration, Utc};
use serde::Serialize;
use uuid::Uuid;

use super::PanelState;
use super::auth::origin_matches;
use super::session::require_viewer;
use crate::daemon_client::pairings::RevokeError;
use crate::daemon_client::{DaemonCredential, MintError, MintedLink};
use crate::error::{ApiError, PanelError};
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
    require_panel_origin(&state, &headers)?;

    let viewer = require_viewer(&state, &headers).await?;
    let pairing_lock = state.pairing_lock(&viewer.account.id);
    let _pairing_guard = pairing_lock.lock().await;
    create_under_lock(&state, &headers).await
}

async fn create_under_lock(state: &PanelState, headers: &HeaderMap) -> Result<Response, ApiError> {
    // Re-read under the same account lock a revoke uses. If the request waited
    // behind a revoke, the first lookup is already stale.
    let viewer = require_viewer(state, headers).await?;
    require_pairing_approval(&viewer.account)?;

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
    let reservation = reservation_for(&viewer.account.id, state);
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

    let minted = mint_against(state, &credential, &viewer.account, &reservation.id).await?;
    // Recorded before it is judged, so a link that is refused below is still
    // one an operator can find and revoke on the daemon.
    finalize(state, &viewer.account, &reservation.id, &minted).await;
    refuse_unexpected_role(state, &credential, &minted).await?;

    Ok((
        [(header::CACHE_CONTROL, "no-store")],
        Json(PairLinkBody { link: minted }),
    )
        .into_response())
}

fn require_panel_origin(state: &PanelState, headers: &HeaderMap) -> Result<(), ApiError> {
    if origin_matches(headers, &state.config.public_origin) {
        Ok(())
    } else {
        Err(ApiError::Forbidden(
            "pairing link requests must come from the panel origin",
        ))
    }
}

fn require_pairing_approval(account: &Account) -> Result<(), ApiError> {
    if account.can_pair {
        Ok(())
    } else {
        Err(ApiError::Forbidden(
            "the panel owner has not allowed this account to generate pairing links",
        ))
    }
}

/// Ask the daemon for the link this reservation stands for.
///
/// A daemon refusal gives the slot back because its transaction did not issue
/// anything. A lost or unreadable success keeps the reservation: the link may
/// already be live, so releasing it would let retries escape the cap.
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
        Err(MintError::NotIssued(error)) => {
            if let Err(release) = state.store.release_pair_link(reservation_id).await {
                record_unreleased(reservation_id, &release);
            }
            Err(error.into())
        }
        Err(MintError::IssuanceUnknown(error)) => {
            record_ambiguous(reservation_id, &error);
            Err(error.into())
        }
    }
}

/// Refuse a link the daemon issued under a role the panel did not ask for.
///
/// The panel picks the role from its own allow-list, but the daemon is what
/// decides what the code actually grants, and only the daemon knows. If the two
/// disagree — an endpoint pointed at the wrong daemon, or one that stopped
/// honouring the request — showing the code would hand somebody authority the
/// owner never approved, which is the whole thing the allow-list exists to
/// prevent.
///
/// The link is already minted, so withholding the code is not enough on its own
/// — it would stay claimable for its whole lifetime by anyone who could reach
/// the daemon another way. The panel withdraws it instead, which its
/// `pair_manage` scope now allows for the links it issued.
///
/// The withdrawal is best effort and its outcome is recorded rather than
/// raised: this is a second call to a daemon that has just behaved
/// unexpectedly, and the refusal stands whether or not it lands. The row
/// recorded a moment ago is what an operator reconciles against the daemon
/// either way.
async fn refuse_unexpected_role(
    state: &PanelState,
    credential: &DaemonCredential,
    minted: &MintedLink,
) -> Result<(), ApiError> {
    if minted.role == state.daemon.config.link_role {
        return Ok(());
    }
    let withdrawal = match state
        .daemon
        .client
        .revoke_pairing(credential, &minted.pairing_id)
        .await
    {
        Ok(_) => "and has been withdrawn",
        Err(error) => {
            record_unwithdrawn(&minted.pairing_id, &error);
            "and could not be withdrawn, so revoke it on the daemon"
        }
    };
    Err(ApiError::Internal(PanelError::daemon(format!(
        "the daemon minted a {} link where {} was asked for; pairing {} was not shown to \
         anyone {withdrawal}",
        minted.role, state.daemon.config.link_role, minted.pairing_id
    ))))
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
    // Both timestamps come from this host's clock, dating the link by the
    // lifetime the daemon granted rather than by the instant it named. Storing
    // the daemon's own expiry would put two hosts' clocks in one row, where a
    // panel running ahead would file a link as expiring before it was created
    // and, worse, stop counting it against the cap while it was still live.
    // The person who asked still sees the daemon's deadline in the response.
    let created_at = Utc::now();
    let recorded = state
        .store
        .finalize_pair_link(
            reservation_id,
            &PairLinkRecord {
                id: minted.pairing_id.clone(),
                account_id: account.id.clone(),
                role: minted.role.clone(),
                created_at,
                expires_at: created_at
                    + granted_lifetime(minted, state.daemon.config.link_ttl_seconds),
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
    PairLinkRecord {
        id: format!("reservation:{}", Uuid::new_v4()),
        account_id: account_id.to_owned(),
        role: state.daemon.config.link_role.clone(),
        created_at: now,
        expires_at: now + lifetime(state.daemon.config.link_ttl_seconds),
    }
}

/// How long this link occupies one of the account's slots.
///
/// The daemon may grant less than the panel asked for, and the shorter answer
/// is the true one. It does not get to grant more: a reply above the request,
/// or of nothing at all, dates the row by the request instead, so a daemon
/// that answered with something absurd cannot pin a slot the account then
/// cannot use.
fn granted_lifetime(minted: &MintedLink, requested_seconds: u64) -> Duration {
    if minted.ttl_seconds == 0 || minted.ttl_seconds > requested_seconds {
        return lifetime(requested_seconds);
    }
    lifetime(minted.ttl_seconds)
}

/// Seconds as a duration. The configuration refuses anything above a day, and
/// no value reaching here exceeds it, so the conversion never saturates.
fn lifetime(seconds: u64) -> Duration {
    Duration::seconds(i64::try_from(seconds).unwrap_or(i64::MAX))
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
fn record_ambiguous(reservation_id: &str, error: &PanelError) {
    tracing::warn!(
        reservation_id = %reservation_id,
        %error,
        "daemon mint outcome is unknown; pairing reservation kept for reconciliation"
    );
}

/// A link the panel refused to show and could not withdraw either.
///
/// Recorded at error level with the pairing id, which is the handle an operator
/// needs: the code is live and unseen, so it lapses on its own unless somebody
/// revokes it first.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn record_unwithdrawn(pairing_id: &str, error: &RevokeError) {
    tracing::error!(
        pairing_id = %pairing_id,
        %error,
        "panel could not withdraw a link it refused to show; revoke it on the daemon"
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
