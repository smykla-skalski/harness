use axum::http::StatusCode;
use tokio::time::Duration;

use crate::daemon::http::RemoteRequestLimitConfig;
use crate::daemon::protocol::http_paths;
use crate::daemon::remote_auth::REMOTE_CLIENT_ID_HEADER;
use crate::daemon::remote_identity::{RemoteAuditOutcome, RemoteAuditScopeDecision};

use super::super::remote_limits_support::{
    remote_state_with_viewer_config, remote_token as limit_remote_token,
};
use super::{audit_for_request, remote_audits, serve_remote, stop_server};

#[tokio::test]
async fn remote_authorization_audit_rate_limits_unauthenticated_writes_without_affecting_valid_clients()
 {
    let state = remote_state_with_viewer_config(RemoteRequestLimitConfig {
        max_unauthenticated_audit_attempts: 2,
        max_unauthenticated_audit_attempts_per_remote_addr: 2,
        unauthenticated_audit_window: Duration::from_secs(60),
        ..RemoteRequestLimitConfig::default()
    });
    let audit_state = state.clone();
    let (base_url, server) = serve_remote(state).await;
    let client = reqwest::Client::new();

    for (request_id, expected_status) in [
        ("audit-unauth-rate-1", StatusCode::UNAUTHORIZED),
        ("audit-unauth-rate-2", StatusCode::UNAUTHORIZED),
        ("audit-unauth-rate-3", StatusCode::TOO_MANY_REQUESTS),
        ("audit-unauth-rate-4", StatusCode::TOO_MANY_REQUESTS),
    ] {
        let response = client
            .get(format!("{base_url}{}", http_paths::HEALTH))
            .header("x-request-id", request_id)
            .send()
            .await
            .expect("send unauthenticated request");
        assert_eq!(response.status(), expected_status, "request {request_id}");
        if expected_status == StatusCode::TOO_MANY_REQUESTS {
            assert_eq!(
                response
                    .headers()
                    .get("retry-after")
                    .and_then(|value| value.to_str().ok()),
                Some("60")
            );
        }
    }

    let valid = client
        .get(format!("{base_url}{}", http_paths::HEALTH))
        .header("x-request-id", "audit-valid-after-rate-limit")
        .header(REMOTE_CLIENT_ID_HEADER, "viewer")
        .bearer_auth(limit_remote_token("viewer"))
        .send()
        .await
        .expect("send valid request after unauthenticated rate limit");
    assert_eq!(valid.status(), StatusCode::OK);

    let events = remote_audits(&audit_state);
    let unauthenticated = events
        .iter()
        .filter(|event| {
            event
                .request_id
                .as_deref()
                .is_some_and(|request_id| request_id.starts_with("audit-unauth-rate-"))
        })
        .collect::<Vec<_>>();
    assert_eq!(unauthenticated.len(), 3);
    let first = audit_for_request(&events, "audit-unauth-rate-1");
    assert_eq!(first.client_id, None);
    assert_eq!(first.scope_decision, RemoteAuditScopeDecision::Denied);
    assert_eq!(first.outcome, RemoteAuditOutcome::Failure);
    let aggregate = audit_for_request(&events, "audit-unauth-rate-3");
    assert_eq!(
        aggregate.error_detail.as_deref(),
        Some("remote unauthenticated requests are rate limited")
    );
    assert!(
        !events
            .iter()
            .any(|event| event.request_id.as_deref() == Some("audit-unauth-rate-4"))
    );
    let valid = audit_for_request(&events, "audit-valid-after-rate-limit");
    assert_eq!(valid.scope_decision, RemoteAuditScopeDecision::Allowed);
    assert_eq!(valid.outcome, RemoteAuditOutcome::Success);

    stop_server(server).await;
}
