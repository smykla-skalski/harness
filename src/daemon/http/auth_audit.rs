use axum::Json;
use axum::body::Body;
use axum::extract::connect_info::ConnectInfo;
use axum::http::{HeaderMap, Request, StatusCode};
use axum::response::{IntoResponse as _, Response};

use crate::daemon::protocol::HttpApiRouteContract;
use crate::daemon::remote::RemoteAccessScope;
use crate::daemon::remote_auth::{
    REMOTE_CLIENT_ID_HEADER, RemoteAuthError, remote_http_required_scope,
};
use crate::daemon::remote_request_audit::RemoteAuthorizationAudit;
use crate::errors::CliError;

use super::{DaemonConnectInfo, DaemonHttpState};

const AUDIT_CLIENT_ID_MAX_CHARS: usize = 256;
const REMOTE_AUDIT_UNAVAILABLE_MESSAGE: &str = "remote authorization audit is unavailable";

pub(super) struct RemoteHttpAuditContext {
    request_id: String,
    attempted_client_id: Option<String>,
    target: String,
    scope: RemoteAccessScope,
    remote_addr: Option<String>,
}

impl RemoteHttpAuditContext {
    pub(super) fn from_request(
        request: &Request<Body>,
        route: &HttpApiRouteContract,
    ) -> Result<Self, RemoteAuthError> {
        Ok(Self {
            request_id: super::extract_request_id(request.headers()),
            attempted_client_id: attempted_client_id(request.headers()),
            target: format!("{} {}", request.method(), route.path),
            scope: remote_http_required_scope(route)?,
            remote_addr: request
                .extensions()
                .get::<ConnectInfo<DaemonConnectInfo>>()
                .map(|ConnectInfo(info)| info.remote_addr().ip().to_string()),
        })
    }

    pub(super) fn record_allowed(
        &self,
        state: &DaemonHttpState,
        client_id: &str,
    ) -> Result<(), CliError> {
        RemoteAuthorizationAudit::allowed(
            &self.request_id,
            client_id,
            &self.target,
            self.scope,
            self.remote_addr.as_deref(),
        )
        .record(state.db.get())
    }

    pub(super) fn record_denied(
        &self,
        state: &DaemonHttpState,
        client_id: Option<&str>,
        error_detail: &str,
    ) -> Result<(), CliError> {
        RemoteAuthorizationAudit::denied(
            &self.request_id,
            client_id.or(self.attempted_client_id.as_deref()),
            &self.target,
            self.scope,
            self.remote_addr.as_deref(),
            error_detail,
        )
        .record(state.db.get())
    }
}

pub(super) fn authentication_error_detail(status: StatusCode) -> &'static str {
    if status == StatusCode::SERVICE_UNAVAILABLE {
        "remote authentication store is unavailable"
    } else {
        "remote authentication denied"
    }
}

pub(super) fn unavailable_response(error: &CliError) -> Response {
    log_unavailable(error);
    (
        StatusCode::SERVICE_UNAVAILABLE,
        Json(serde_json::json!({
            "error": {
                "code": "REMOTE_AUDIT",
                "message": REMOTE_AUDIT_UNAVAILABLE_MESSAGE,
            }
        })),
    )
        .into_response()
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_unavailable(error: &CliError) {
    tracing::error!(error = %error, "remote authorization audit failed");
}

fn attempted_client_id(headers: &HeaderMap) -> Option<String> {
    headers
        .get(REMOTE_CLIENT_ID_HEADER)
        .and_then(|value| value.to_str().ok())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| value.chars().take(AUDIT_CLIENT_ID_MAX_CHARS).collect())
}
