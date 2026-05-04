use axum::Json;
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use harness_testkit::with_isolated_harness_env;
use tempfile::tempdir;

use crate::daemon::protocol::DaemonTelemetryKind;
use crate::daemon::protocol::DaemonTelemetryRequest;

use super::super::core::{get_diagnostics, post_daemon_telemetry};
use super::{auth_headers, response_json, test_http_state_with_db};

#[tokio::test]
async fn post_daemon_telemetry_requires_auth() {
    let response = post_daemon_telemetry(
        HeaderMap::new(),
        State(test_http_state_with_db()),
        Json(DaemonTelemetryRequest {
            kind: DaemonTelemetryKind::DecodeFailure,
            source: "swift.acp".to_string(),
            message: "failed to decode".to_string(),
            sample: None,
        }),
    )
    .await;

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[test]
fn post_daemon_telemetry_records_redacted_decode_failure_in_diagnostics() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let state = test_http_state_with_db();
            let response = post_daemon_telemetry(
                auth_headers(),
                State(state.clone()),
                Json(DaemonTelemetryRequest {
                    kind: DaemonTelemetryKind::DecodeFailure,
                    source: "swift.acp SOURCE_TOKEN=source-secret".to_string(),
                    message: "failed to decode Authorization: Bearer supersecret-token".to_string(),
                    sample: Some("ADMIN_TOKEN=topsecret-value".to_string()),
                }),
            )
            .await;
            let (status, body) = response_json(response).await;
            assert_eq!(status, StatusCode::OK);
            assert!(body["recorded_at"].as_str().is_some());

            let diagnostics = get_diagnostics(auth_headers(), State(state)).await;
            let (status, body) = response_json(diagnostics).await;
            assert_eq!(status, StatusCode::OK);

            let recent_events = body["recent_events"]
                .as_array()
                .expect("recent events array");
            let message = recent_events
                .last()
                .and_then(|event| event["message"].as_str())
                .expect("telemetry event message");

            assert!(message.contains("client telemetry decode_failure from swift.acp"));
            assert!(message.contains("[REDACTED:BEARER]"));
            assert!(message.contains("[REDACTED:ENV_SECRET]"));
            assert!(!message.contains("supersecret-token"));
            assert!(!message.contains("topsecret-value"));
            assert!(!message.contains("source-secret"));
        });
    });
}
