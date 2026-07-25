//! Reading routes: who is signed in, who has signed in, and the app itself.

use axum::Json;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use serde::Serialize;

use super::PanelState;
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
pub async fn me(
    State(state): State<PanelState>,
    headers: HeaderMap,
) -> Result<Json<Viewer>, ApiError> {
    Ok(Json(require_viewer(&state, &headers).await?))
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
) -> Result<Json<AccountsBody>, ApiError> {
    let viewer = require_viewer(&state, &headers).await?;
    if !viewer.is_owner {
        return Err(ApiError::Forbidden(
            "only the panel owner can list accounts",
        ));
    }
    Ok(Json(AccountsBody {
        accounts: state.store.list_accounts().await?,
    }))
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
