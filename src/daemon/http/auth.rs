use axum::Json;
use axum::http::{HeaderMap, StatusCode, header::AUTHORIZATION};
use axum::response::{IntoResponse, Response};

use crate::daemon::protocol::ControlPlaneActorRequest;

use super::DaemonHttpState;

pub(super) fn authorize_control_request<T: ControlPlaneActorRequest>(
    headers: &HeaderMap,
    state: &DaemonHttpState,
    request: &mut T,
) -> Result<(), Box<Response>> {
    require_auth(headers, state)?;
    request.bind_control_plane_actor();
    Ok(())
}

pub(crate) fn require_auth(
    headers: &HeaderMap,
    state: &DaemonHttpState,
) -> Result<(), Box<Response>> {
    let provided = headers
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .map(str::trim);
    if provided == Some(state.token.as_str()) {
        return Ok(());
    }
    Err(Box::new(
        (
            StatusCode::UNAUTHORIZED,
            Json(serde_json::json!({
                "error": {
                    "code": "DAEMON_AUTH",
                    "message": "missing or invalid daemon bearer token",
                }
            })),
        )
            .into_response(),
    ))
}
