use axum::Json;
use axum::body::Body;
use axum::extract::{MatchedPath, State};
use axum::http::{HeaderMap, Method, Request, StatusCode, header::AUTHORIZATION};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};

use crate::daemon::protocol::{
    ControlPlaneActorRequest, HTTP_API_CONTRACT, HttpApiRouteContract, http_paths,
    with_control_plane_actor,
};
use crate::daemon::remote_auth::{
    REMOTE_CLIENT_ID_HEADER, RemoteAuthError, RemoteBearerCredentials, authorize_remote_http_route,
};
use crate::daemon::remote_identity::RemoteStoredClient;

use super::auth_audit::RemoteHttpAuditContext;
use super::{DaemonHttpState, auth_audit};

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

pub(super) struct RemoteHttpLimitAudit {
    context: RemoteHttpAuditContext,
    route: &'static HttpApiRouteContract,
    headers: HeaderMap,
}

impl RemoteHttpLimitAudit {
    pub(super) fn from_request(
        request: &Request<Body>,
        state: &DaemonHttpState,
    ) -> Result<Option<Self>, Box<Response>> {
        let Some((context, route)) = remote_http_limit_audit_target(request, state)? else {
            return Ok(None);
        };
        Ok(Some(Self {
            context,
            route,
            headers: remote_limit_auth_headers(request.headers()),
        }))
    }

    pub(super) async fn record_rejection(
        &self,
        state: &DaemonHttpState,
        error_detail: &str,
    ) -> Result<(), Box<Response>> {
        record_remote_http_limit_rejection(
            &self.context,
            &self.headers,
            state,
            self.route,
            error_detail,
        )
        .await
    }
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

pub(crate) fn authenticated_remote_client(
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
    authorize_remote_http_request_inner(&state, request, next).await
}

async fn authorize_remote_http_request_inner(
    state: &DaemonHttpState,
    request: Request<Body>,
    next: Next,
) -> Response {
    let Some(route_path) = request
        .extensions()
        .get::<MatchedPath>()
        .map(MatchedPath::as_str)
    else {
        return next.run(request).await;
    };
    if is_public_remote_http_route(request.method(), route_path) {
        return next.run(request).await;
    }
    let Some(route) = http_route_contract(request.method(), route_path) else {
        return remote_auth_error_response(RemoteAuthError::MissingScopeContract);
    };
    let audit = match RemoteHttpAuditContext::from_request(&request, route) {
        Ok(audit) => audit,
        Err(error) => return remote_auth_error_response(error),
    };
    let verification = verify_remote_client(request.headers(), state);
    let client = match authenticate_and_audit_remote_http_request(
        &audit,
        verification,
        state,
        route,
    )
    .await
    {
        Ok(client) => client,
        Err(response) => return *response,
    };
    let actor = client.control_plane_actor_id();
    let response = REMOTE_HTTP_CLIENT
        .scope(client, with_control_plane_actor(actor, next.run(request)))
        .await;
    complete_remote_http_audit(&audit, state, response).await
}

async fn complete_remote_http_audit(
    audit: &RemoteHttpAuditContext,
    state: &DaemonHttpState,
    response: Response,
) -> Response {
    let status = response.status();
    if !status.is_client_error() && !status.is_server_error() {
        return response;
    }
    let error_detail = format!("remote HTTP handler returned status {}", status.as_u16());
    match audit.mark_handler_failure(state, &error_detail).await {
        Ok(()) => response,
        Err(error) => auth_audit::unavailable_response(&error),
    }
}

async fn authenticate_and_audit_remote_http_request(
    audit: &RemoteHttpAuditContext,
    verification: Result<RemoteStoredClient, Box<Response>>,
    state: &DaemonHttpState,
    route: &HttpApiRouteContract,
) -> Result<RemoteStoredClient, Box<Response>> {
    let client = match verification {
        Ok(client) => client,
        Err(response) => {
            return Err(Box::new(
                audit_verification_failure(audit, state, *response).await,
            ));
        }
    };
    authorize_and_audit_remote_http_client(audit, state, route, client).await
}

async fn audit_verification_failure(
    audit: &RemoteHttpAuditContext,
    state: &DaemonHttpState,
    response: Response,
) -> Response {
    let error_detail = auth_audit::authentication_error_detail(response.status());
    match audit.record_denied(state, None, error_detail).await {
        Ok(()) => response,
        Err(error) => auth_audit::unavailable_response(&error),
    }
}

async fn authorize_and_audit_remote_http_client(
    audit: &RemoteHttpAuditContext,
    state: &DaemonHttpState,
    route: &HttpApiRouteContract,
    client: RemoteStoredClient,
) -> Result<RemoteStoredClient, Box<Response>> {
    if let Err(error) = authorize_remote_http_route(&client, route) {
        return match audit
            .record_denied(state, Some(&client.client_id), &error.to_string())
            .await
        {
            Ok(()) => Err(Box::new(remote_auth_error_response(error))),
            Err(audit_error) => Err(Box::new(auth_audit::unavailable_response(&audit_error))),
        };
    }
    audit
        .record_allowed(state, &client.client_id)
        .await
        .map_err(|error| Box::new(auth_audit::unavailable_response(&error)))?;
    Ok(client)
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

fn is_public_remote_http_route(method: &Method, route_path: &str) -> bool {
    *method == Method::POST
        && matches!(
            route_path,
            http_paths::REMOTE_PAIR_CLAIM | http_paths::REMOTE_PAIR_STATUS
        )
}

fn remote_http_limit_audit_target(
    request: &Request<Body>,
    state: &DaemonHttpState,
) -> Result<Option<(RemoteHttpAuditContext, &'static HttpApiRouteContract)>, Box<Response>> {
    if state.auth_mode == DaemonHttpAuthMode::Local {
        return Ok(None);
    }
    let Some(route_path) = request
        .extensions()
        .get::<MatchedPath>()
        .map(MatchedPath::as_str)
    else {
        return Ok(None);
    };
    if is_public_remote_http_route(request.method(), route_path) {
        return Ok(None);
    }
    let route = http_route_contract(request.method(), route_path).ok_or_else(|| {
        Box::new(remote_auth_error_response(
            RemoteAuthError::MissingScopeContract,
        ))
    })?;
    let context = RemoteHttpAuditContext::from_request(request, route)
        .map_err(|error| Box::new(remote_auth_error_response(error)))?;
    Ok(Some((context, route)))
}

async fn record_remote_http_limit_rejection(
    audit: &RemoteHttpAuditContext,
    headers: &HeaderMap,
    state: &DaemonHttpState,
    route: &HttpApiRouteContract,
    error_detail: &str,
) -> Result<(), Box<Response>> {
    match audit.amend_recorded_failure(state, error_detail).await {
        Ok(true) => return Ok(()),
        Ok(false) => {}
        Err(error) => return Err(Box::new(auth_audit::unavailable_response(&error))),
    }
    let result = match verify_remote_client(headers, state) {
        Ok(client) if authorize_remote_http_route(&client, route).is_ok() => {
            audit
                .record_allowed_failure(state, &client.client_id, error_detail)
                .await
        }
        Ok(client) => {
            audit
                .record_denied(state, Some(&client.client_id), error_detail)
                .await
        }
        Err(_) => audit.record_denied(state, None, error_detail).await,
    };
    result.map_err(|error| Box::new(auth_audit::unavailable_response(&error)))
}

fn remote_limit_auth_headers(headers: &HeaderMap) -> HeaderMap {
    let mut owned = HeaderMap::new();
    if let Some(value) = headers.get(AUTHORIZATION) {
        owned.insert(AUTHORIZATION, value.clone());
    }
    if let Some(value) = headers.get(REMOTE_CLIENT_ID_HEADER) {
        owned.insert(REMOTE_CLIENT_ID_HEADER, value.clone());
    }
    owned
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

#[cfg(test)]
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
