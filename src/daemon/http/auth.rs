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

const REMOTE_AUTH_STORE_UNAVAILABLE_MESSAGE: &str = "remote authentication store is unavailable";

tokio::task_local! {
    static REMOTE_HTTP_CLIENT: RemoteStoredClient;
}

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
        DaemonHttpAuthMode::Remote => {
            if has_scoped_remote_client() {
                Ok(())
            } else {
                verify_remote_client(headers, state).map(|_| ())
            }
        }
    }
}

pub(crate) fn websocket_remote_client(
    headers: &HeaderMap,
    state: &DaemonHttpState,
) -> Result<Option<RemoteStoredClient>, Box<Response>> {
    match state.auth_mode {
        DaemonHttpAuthMode::Local => require_local_auth(headers, state).map(|()| None),
        DaemonHttpAuthMode::Remote => {
            if let Some(client) = scoped_remote_client() {
                Ok(Some(client))
            } else {
                verify_remote_client(headers, state).map(Some)
            }
        }
    }
}

#[cfg(test)]
pub(crate) fn authorize_http_route(
    headers: &HeaderMap,
    state: &DaemonHttpState,
    route: &HttpApiRouteContract,
) -> Result<(), Box<Response>> {
    match state.auth_mode {
        DaemonHttpAuthMode::Local => require_local_auth(headers, state),
        DaemonHttpAuthMode::Remote => {
            verify_and_authorize_http_route(headers, state, route).map(|_| ())
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
    let Some(route_path) = request
        .extensions()
        .get::<MatchedPath>()
        .map(MatchedPath::as_str)
    else {
        return next.run(request).await;
    };
    let Some(route) = http_route_contract(request.method(), route_path) else {
        return remote_auth_error_response(RemoteAuthError::MissingScopeContract);
    };
    match verify_and_authorize_http_route(request.headers(), &state, route) {
        Ok(client) => REMOTE_HTTP_CLIENT.scope(client, next.run(request)).await,
        Err(response) => *response,
    }
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
    let method = if *method == Method::HEAD {
        Method::GET.as_str()
    } else {
        method.as_str()
    };
    HTTP_API_CONTRACT
        .iter()
        .find(|route| route.method.as_str() == method && route.path == route_path)
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
    let db = db
        .lock()
        .map_err(|_| Box::new(remote_store_unavailable_response()))?;
    db.verify_remote_client_token(credentials.client_id(), credentials.token())
        .map_err(|_| Box::new(remote_store_unavailable_response()))?
        .ok_or_else(|| {
            Box::new(remote_auth_error_response(
                RemoteAuthError::InvalidBearerToken,
            ))
        })
}

fn verify_and_authorize_http_route(
    headers: &HeaderMap,
    state: &DaemonHttpState,
    route: &HttpApiRouteContract,
) -> Result<RemoteStoredClient, Box<Response>> {
    let client = verify_remote_client(headers, state)?;
    authorize_remote_http_route(&client, route)
        .map(|_| client)
        .map_err(|error| Box::new(remote_auth_error_response(error)))
}

fn scoped_remote_client() -> Option<RemoteStoredClient> {
    REMOTE_HTTP_CLIENT.try_with(Clone::clone).ok()
}

fn has_scoped_remote_client() -> bool {
    REMOTE_HTTP_CLIENT.try_with(|_| ()).is_ok()
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
    (
        StatusCode::SERVICE_UNAVAILABLE,
        Json(serde_json::json!({
            "error": {
                "code": "REMOTE_AUTH_STORE",
                "message": REMOTE_AUTH_STORE_UNAVAILABLE_MESSAGE,
            }
        })),
    )
        .into_response()
}
