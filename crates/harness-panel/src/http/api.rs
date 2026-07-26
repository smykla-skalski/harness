//! Reading routes: who is signed in, who has signed in, and the app itself.

use axum::Json;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use chrono::Utc;
use serde::Serialize;

use super::PanelState;
use super::auth::origin_matches;
use super::session::{Viewer, require_viewer};
use crate::error::ApiError;
use crate::store::accounts::Account;

/// A page that reflects a session must never be reused for a different one, and
/// the entry page is rewritten per mount point rather than content-hashed.
const NO_STORE: &str = "no-store";
/// Vite content-hashes every emitted asset, so a cached copy cannot be a stale
/// version of itself.
const IMMUTABLE: &str = "public, max-age=31536000, immutable";

#[derive(Debug, Serialize)]
pub struct HealthBody {
    status: &'static str,
    /// `placeholder` when the binary was built without the web assets, so a
    /// deploy that skipped the frontend build is visible without loading a page.
    assets: &'static str,
}

#[derive(Debug, Serialize)]
pub struct AccountsBody {
    accounts: Vec<Account>,
}

pub async fn healthz(State(state): State<PanelState>) -> Json<HealthBody> {
    Json(HealthBody {
        status: "ok",
        assets: if state.assets.is_placeholder() {
            "placeholder"
        } else {
            "bundled"
        },
    })
}

/// The signed-in person.
///
/// # Errors
/// Returns [`ApiError::Unauthenticated`] when no live session is presented.
pub async fn me(State(state): State<PanelState>, headers: HeaderMap) -> Result<Response, ApiError> {
    Ok(private_json(&require_viewer(&state, &headers).await?))
}

/// Everyone who has signed in. The owner is the only account allowed to see
/// that anyone else exists.
///
/// # Errors
/// Returns [`ApiError::Unauthenticated`] when signed out and
/// [`ApiError::Forbidden`] for anyone but the owner.
pub async fn accounts(
    State(state): State<PanelState>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    require_owner(&state, &headers).await?;
    Ok(private_json(&AccountsBody {
        accounts: state.store.list_accounts().await?,
    }))
}

/// Let an account generate pairing links.
///
/// # Errors
/// Returns [`ApiError::Forbidden`] for anyone but the owner and
/// [`ApiError::NotFound`] when the account is gone.
pub async fn approve(
    State(state): State<PanelState>,
    headers: HeaderMap,
    Path(account_id): Path<String>,
) -> Result<Response, ApiError> {
    decide(&state, &headers, &account_id, true).await
}

/// Withdraw that ability.
///
/// # Errors
/// Returns [`ApiError::Forbidden`] for anyone but the owner and
/// [`ApiError::NotFound`] when the account is gone.
pub async fn revoke(
    State(state): State<PanelState>,
    headers: HeaderMap,
    Path(account_id): Path<String>,
) -> Result<Response, ApiError> {
    decide(&state, &headers, &account_id, false).await
}

/// `SameSite` cookies cross between sibling origins, so the request must also
/// prove that it came from this panel.
async fn decide(
    state: &PanelState,
    headers: &HeaderMap,
    account_id: &str,
    granted: bool,
) -> Result<Response, ApiError> {
    if !origin_matches(headers, &state.config.public_origin) {
        return Err(ApiError::Forbidden(
            "approval requests must come from the panel origin",
        ));
    }
    let owner = require_owner(state, headers).await?;
    let pairing_lock = state.pairing_lock(account_id);
    let _pairing_guard = pairing_lock.lock().await;

    if !state
        .store
        .set_can_pair(account_id, granted, &owner.account, Utc::now())
        .await?
    {
        return Err(ApiError::NotFound("no such account"));
    }

    let account = state
        .store
        .account_by_id(account_id)
        .await?
        .ok_or(ApiError::NotFound("no such account"))?;
    record_decision(&account, &owner.account.login, granted);
    Ok(private_json(&account))
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn record_decision(account: &Account, actor: &str, granted: bool) {
    tracing::info!(
        login = %account.login,
        actor = %actor,
        granted,
        "panel pairing approval changed"
    );
}

/// Resolve the signed-in owner, refusing anyone else.
///
/// # Errors
/// Returns [`ApiError::Unauthenticated`] when signed out and
/// [`ApiError::Forbidden`] for a signed-in account that does not own the panel.
async fn require_owner(state: &PanelState, headers: &HeaderMap) -> Result<Viewer, ApiError> {
    let viewer = require_viewer(state, headers).await?;
    if viewer.is_owner {
        Ok(viewer)
    } else {
        Err(ApiError::Forbidden("only the panel owner can do that"))
    }
}

/// Answer with JSON that belongs to one session and nothing else.
///
/// A 200 is heuristically cacheable, so without this a proxy between the daemon
/// and the browser is free to keep one person's account list and hand it to the
/// next request that looks the same.
fn private_json<T: Serialize>(body: &T) -> Response {
    ([(header::CACHE_CONTROL, NO_STORE)], Json(body)).into_response()
}

pub async fn index(State(state): State<PanelState>) -> Response {
    index_response(&state)
}

/// Serve a bundled file, or hand the path to the single-page app.
///
/// A path the bundle does not contain is a route the app owns, so answering
/// with the entry page is what makes a deep link or a reload work.
pub async fn asset_or_index(
    State(state): State<PanelState>,
    Path(asset): Path<String>,
) -> Response {
    let Some(file) = state.assets.file(&asset) else {
        return index_response(&state);
    };
    (
        [
            (header::CONTENT_TYPE, file.content_type),
            (
                header::CACHE_CONTROL,
                if file.immutable { IMMUTABLE } else { NO_STORE },
            ),
        ],
        file.bytes,
    )
        .into_response()
}

fn index_response(state: &PanelState) -> Response {
    (
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, "text/html; charset=utf-8"),
            (header::CACHE_CONTROL, NO_STORE),
        ],
        state.assets.index_html().to_owned(),
    )
        .into_response()
}
