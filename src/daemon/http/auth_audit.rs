use std::sync::{Arc, OnceLock};

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
use crate::daemon::remote_request_audit::{
    RemoteAuthorizationAudit, RemoteAuthorizationAuditReceipt,
};
use crate::errors::{CliError, CliErrorKind};

use super::{DaemonConnectInfo, DaemonHttpState};

const AUDIT_CLIENT_ID_MAX_CHARS: usize = 256;
const REMOTE_AUDIT_UNAVAILABLE_MESSAGE: &str = "remote authorization audit is unavailable";

#[derive(Clone, Default)]
pub(super) struct RemoteHttpAuditMarker(Arc<OnceLock<RemoteAuthorizationAuditReceipt>>);

impl RemoteHttpAuditMarker {
    fn mark_recorded(&self, receipt: RemoteAuthorizationAuditReceipt) {
        drop(self.0.set(receipt));
    }

    fn receipt(&self) -> Option<RemoteAuthorizationAuditReceipt> {
        self.0.get().cloned()
    }
}

pub(super) struct RemoteHttpAuditContext {
    request_id: String,
    attempted_client_id: Option<String>,
    target: String,
    scope: RemoteAccessScope,
    remote_addr: Option<String>,
    marker: Option<RemoteHttpAuditMarker>,
    receipt: OnceLock<RemoteAuthorizationAuditReceipt>,
}

impl RemoteHttpAuditContext {
    pub(super) fn from_request(
        request: &Request<Body>,
        route: &HttpApiRouteContract,
    ) -> Result<Self, RemoteAuthError> {
        Ok(Self::new(
            request,
            format!("{} {}", request.method(), route.path),
            remote_http_required_scope(route)?,
        ))
    }

    pub(super) fn from_execution_request(request: &Request<Body>) -> Self {
        Self::new(
            request,
            format!("{} {}", request.method(), request.uri().path()),
            RemoteAccessScope::Execute,
        )
    }

    fn new(request: &Request<Body>, target: String, scope: RemoteAccessScope) -> Self {
        Self {
            request_id: super::extract_request_id(request.headers()),
            attempted_client_id: attempted_client_id(request.headers()),
            target,
            scope,
            remote_addr: request
                .extensions()
                .get::<ConnectInfo<DaemonConnectInfo>>()
                .map(|ConnectInfo(info)| info.remote_addr().ip().to_string()),
            marker: request.extensions().get::<RemoteHttpAuditMarker>().cloned(),
            receipt: OnceLock::new(),
        }
    }

    pub(super) async fn record_allowed(
        &self,
        state: &DaemonHttpState,
        client_id: &str,
    ) -> Result<(), CliError> {
        let result = RemoteAuthorizationAudit::allowed(
            &self.request_id,
            client_id,
            &self.target,
            self.scope,
            self.remote_addr.as_deref(),
        )
        .record(state.async_db.get())
        .await;
        self.finish_record(result)
    }

    pub(super) async fn record_allowed_failure(
        &self,
        state: &DaemonHttpState,
        client_id: &str,
        error_detail: &str,
    ) -> Result<(), CliError> {
        let result = RemoteAuthorizationAudit::allowed_failure(
            &self.request_id,
            client_id,
            &self.target,
            self.scope,
            self.remote_addr.as_deref(),
            error_detail,
        )
        .record(state.async_db.get())
        .await;
        self.finish_record(result)
    }

    pub(super) async fn record_denied(
        &self,
        state: &DaemonHttpState,
        client_id: Option<&str>,
        error_detail: &str,
    ) -> Result<(), CliError> {
        let result = RemoteAuthorizationAudit::denied(
            &self.request_id,
            client_id.or(self.attempted_client_id.as_deref()),
            &self.target,
            self.scope,
            self.remote_addr.as_deref(),
            error_detail,
        )
        .record(state.async_db.get())
        .await;
        self.finish_record(result)
    }

    pub(super) async fn amend_recorded_failure(
        &self,
        state: &DaemonHttpState,
        error_detail: &str,
    ) -> Result<bool, CliError> {
        let Some(receipt) = self
            .marker
            .as_ref()
            .and_then(RemoteHttpAuditMarker::receipt)
        else {
            return Ok(false);
        };
        receipt
            .mark_failed(state.async_db.get(), error_detail)
            .await?;
        Ok(true)
    }

    pub(super) async fn mark_handler_failure(
        &self,
        state: &DaemonHttpState,
        error_detail: &str,
    ) -> Result<(), CliError> {
        let receipt = self.receipt.get().ok_or_else(|| {
            CliError::from(CliErrorKind::workflow_io(
                "remote authorization audit receipt is unavailable",
            ))
        })?;
        receipt
            .mark_failed(state.async_db.get(), error_detail)
            .await
    }

    fn finish_record(
        &self,
        result: Result<RemoteAuthorizationAuditReceipt, CliError>,
    ) -> Result<(), CliError> {
        let receipt = result?;
        drop(self.receipt.set(receipt.clone()));
        if let Some(marker) = &self.marker {
            marker.mark_recorded(receipt);
        }
        Ok(())
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
pub(super) fn log_update_failure(error: &CliError) {
    tracing::error!(error = %error, "remote authorization audit update failed");
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
