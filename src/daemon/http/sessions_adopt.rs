use std::path::Path;
use std::time::Instant;

use axum::Json;
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};

use crate::daemon::db::ensure_shared_db;
use crate::daemon::protocol::{AdoptSessionRequest, SessionMutationResponse};
use crate::daemon::service;
use crate::errors::CliError;
use crate::sandbox;
use crate::workspace::adopter::{AdoptionError, AdoptionOutcome, SessionAdopter};
use crate::workspace::harness_data_root;
use crate::workspace::layout::sessions_root;

use super::DaemonHttpState;
use super::auth::require_auth;
use super::response::{extract_request_id, timed_json};

pub(super) async fn post_session_adopt(
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<AdoptSessionRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }

    let result = {
        #[cfg(target_os = "macos")]
        {
            let input = if sandbox::resolver::is_sandboxed() {
                request
                    .bookmark_id
                    .as_deref()
                    .unwrap_or(request.session_root.as_str())
            } else {
                request.session_root.as_str()
            };
            let session_root_scope = match sandbox::resolve_project_input(input) {
                Ok(session_root_scope) => session_root_scope,
                Err(error) => {
                    return timed_json(
                        "POST",
                        "/v1/sessions/adopt",
                        &request_id,
                        start,
                        Err::<SessionMutationResponse, _>(error),
                    );
                }
            };
            adopt_session(session_root_scope.path())
        }

        #[cfg(not(target_os = "macos"))]
        {
            adopt_session(Path::new(&request.session_root))
        }
    };

    match result {
        Ok(outcome) => {
            record_adopt_in_db(&state, &outcome).await;
            timed_json(
                "POST",
                "/v1/sessions/adopt",
                &request_id,
                start,
                Ok::<_, CliError>(SessionMutationResponse {
                    state: outcome.state,
                }),
            )
        }
        Err(ref adoption_error) => adoption_error_response(adoption_error),
    }
}

fn adopt_session(session_root: &Path) -> Result<AdoptionOutcome, AdoptionError> {
    let probed = SessionAdopter::probe(session_root)?;
    let data_root_sessions = sessions_root(&harness_data_root());
    SessionAdopter::register(probed, &data_root_sessions)
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
async fn record_adopt_in_db(state: &DaemonHttpState, outcome: &AdoptionOutcome) {
    if let Some(async_db) = state.async_db.get() {
        if let Err(error) = service::adopt_session_record_async(outcome, async_db.as_ref()).await {
            tracing::warn!(%error, "adopt: failed to write session to async db");
        }
        return;
    }
    if let Ok(db) = ensure_shared_db(&state.db) {
        let db_guard = db.lock().expect("db lock");
        if let Err(error) = service::adopt_session_record(outcome, &db_guard) {
            tracing::warn!(%error, "adopt: failed to write session to sync db");
        }
    }
}

fn adoption_error_response(error: &AdoptionError) -> Response {
    let (status, body) = match error {
        AdoptionError::LayoutViolation { reason } => (
            StatusCode::UNPROCESSABLE_ENTITY,
            serde_json::json!({ "error": "layout-violation", "reason": reason }),
        ),
        AdoptionError::UnsupportedSchemaVersion { found, supported } => (
            StatusCode::UNPROCESSABLE_ENTITY,
            serde_json::json!({
                "error": "unsupported-schema-version",
                "found": found,
                "supported": supported
            }),
        ),
        AdoptionError::OriginMismatch { expected, found } => (
            StatusCode::UNPROCESSABLE_ENTITY,
            serde_json::json!({
                "error": "origin-mismatch",
                "expected": expected,
                "found": found
            }),
        ),
        AdoptionError::AlreadyAttached { session_id } => (
            StatusCode::CONFLICT,
            serde_json::json!({ "error": "already-attached", "session_id": session_id }),
        ),
        AdoptionError::InvalidProjectDir
        | AdoptionError::Io { .. }
        | AdoptionError::Parse(_)
        | AdoptionError::Storage(_) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            serde_json::json!({ "error": "internal", "detail": error.to_string() }),
        ),
    };
    (status, Json(body)).into_response()
}

#[cfg(test)]
mod tests;
