use axum::Json;
use axum::body::Body;
use axum::extract::{MatchedPath, State};
use axum::http::{HeaderMap, Method, Request, StatusCode, header::AUTHORIZATION};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};

use crate::daemon::protocol::{ControlPlaneActorRequest, HTTP_API_CONTRACT, HttpApiRouteContract};
use crate::daemon::remote_auth::{
    RemoteAuthError, RemoteBearerCredentials, authorize_remote_http_route,
};
use crate::daemon::remote_identity::RemoteStoredClient;

use super::DaemonHttpState;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum DaemonHttpAuthMode {
    #[default]
    Local,
    Remote,
}

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
    match state.auth_mode {
        DaemonHttpAuthMode::Local => require_local_auth(headers, state),
        DaemonHttpAuthMode::Remote => verify_remote_client(headers, state).map(|_| ()),
    }
}

pub(crate) fn authorize_http_route(
    headers: &HeaderMap,
    state: &DaemonHttpState,
    route: &HttpApiRouteContract,
) -> Result<(), Box<Response>> {
    match state.auth_mode {
        DaemonHttpAuthMode::Local => require_local_auth(headers, state),
        DaemonHttpAuthMode::Remote => {
            let client = verify_remote_client(headers, state)?;
            authorize_remote_http_route(&client, route)
                .map(|_| ())
                .map_err(|error| Box::new(remote_auth_error_response(error)))
        }
    }
}

pub(crate) async fn authorize_remote_http_request(
    State(state): State<DaemonHttpState>,
    request: Request<Body>,
    next: Next,
) -> Response {
    if state.auth_mode == DaemonHttpAuthMode::Local {
        return next.run(request).await;
    }
    let route_path = request.extensions().get::<MatchedPath>().map_or_else(
        || request.uri().path().to_string(),
        |matched| matched.as_str().to_string(),
    );
    let Some(route) = http_route_contract(request.method(), &route_path) else {
        return remote_auth_error_response(RemoteAuthError::MissingScopeContract);
    };
    if let Err(response) = authorize_http_route(request.headers(), &state, route) {
        return *response;
    }
    next.run(request).await
}

fn require_local_auth(headers: &HeaderMap, state: &DaemonHttpState) -> Result<(), Box<Response>> {
    let provided = headers
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .map(str::trim);
    if provided == Some(state.token.as_str()) {
        return Ok(());
    }
    Err(Box::new(local_auth_response()))
}

fn http_route_contract(method: &Method, route_path: &str) -> Option<&'static HttpApiRouteContract> {
    HTTP_API_CONTRACT
        .iter()
        .find(|route| route.method.as_str() == method.as_str() && route.path == route_path)
}

fn verify_remote_client(
    headers: &HeaderMap,
    state: &DaemonHttpState,
) -> Result<RemoteStoredClient, Box<Response>> {
    let credentials = RemoteBearerCredentials::from_headers(headers)
        .map_err(|error| Box::new(remote_auth_error_response(error)))?;
    let db = state
        .db
        .get()
        .ok_or_else(|| Box::new(remote_store_unavailable_response()))?;
    let db = db.lock().map_err(|error| {
        Box::new(remote_service_error_response(format!(
            "remote client store lock poisoned: {error}"
        )))
    })?;
    db.verify_remote_client_token(credentials.client_id(), credentials.token())
        .map_err(|error| Box::new(remote_service_error_response(error.to_string())))?
        .ok_or_else(|| {
            Box::new(remote_auth_error_response(
                RemoteAuthError::InvalidBearerToken,
            ))
        })
}

fn local_auth_response() -> Response {
    (
        StatusCode::UNAUTHORIZED,
        Json(serde_json::json!({
            "error": {
                "code": "DAEMON_AUTH",
                "message": "missing or invalid daemon bearer token",
            }
        })),
    )
        .into_response()
}

fn remote_auth_error_response(error: RemoteAuthError) -> Response {
    (
        error.status_code(),
        Json(serde_json::json!({
            "error": {
                "code": "REMOTE_AUTH",
                "message": error.to_string(),
            }
        })),
    )
        .into_response()
}

fn remote_store_unavailable_response() -> Response {
    remote_service_error_response("remote client store is unavailable")
}

fn remote_service_error_response(message: impl Into<String>) -> Response {
    (
        StatusCode::SERVICE_UNAVAILABLE,
        Json(serde_json::json!({
            "error": {
                "code": "REMOTE_AUTH_STORE",
                "message": message.into(),
            }
        })),
    )
        .into_response()
}
