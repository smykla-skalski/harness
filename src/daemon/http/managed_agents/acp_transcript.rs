use std::time::Instant;

use axum::extract::{Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use serde::Deserialize;

use crate::daemon::protocol::{AcpTranscriptResponse, http_paths};
use crate::errors::{CliError, CliErrorKind};

use super::super::DaemonHttpState;
use super::super::auth::require_auth;
use super::super::response::{extract_request_id, timed_json};
use super::ensure_acp_enabled;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct AcpTranscriptQuery {
    session_id: Option<String>,
}

pub(super) async fn get_acp_transcript(
    Query(query): Query<AcpTranscriptQuery>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }

    let result: Result<AcpTranscriptResponse, CliError> =
        match ensure_acp_enabled().and_then(|()| {
            query.session_id.ok_or_else(|| {
                CliError::new(CliErrorKind::usage_error(
                    "session_id is required for ACP transcript reads",
                ))
            })
        }) {
            Ok(session_id) => super::acp_transcript_response(&state, &session_id).await,
            Err(error) => Err(error),
        };

    timed_json(
        "GET",
        http_paths::MANAGED_AGENTS_ACP_TRANSCRIPT,
        &request_id,
        start,
        result,
    )
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex, OnceLock};

    use axum::body::to_bytes;
    use axum::extract::{Query, State};
    use axum::http::{HeaderMap, StatusCode, header::AUTHORIZATION};
    use tokio::sync::broadcast;

    use crate::daemon::agent_acp::AcpAgentManagerHandle;
    use crate::daemon::agent_tui::AgentTuiManagerHandle;
    use crate::daemon::codex_controller::CodexControllerHandle;
    use crate::daemon::http::{AsyncDaemonDbSlot, DaemonHttpState};
    use crate::daemon::protocol::StreamEvent;
    use crate::daemon::state::DaemonManifest;
    use crate::daemon::websocket::ReplayBuffer;

    use super::*;

    fn minimal_state() -> DaemonHttpState {
        let (sender, _) = broadcast::channel::<StreamEvent>(8);
        let db_slot = Arc::new(OnceLock::new());
        let manifest: DaemonManifest = serde_json::from_value(serde_json::json!({
            "version": "0.0.0", "pid": 1, "endpoint": "http://127.0.0.1:0",
            "started_at": "2026-01-01T00:00:00Z", "token_path": "/tmp/token",
            "sandboxed": false, "host_bridge": {}, "revision": 0,
            "updated_at": "", "binary_stamp": null,
        }))
        .expect("manifest");
        DaemonHttpState {
            token: "token".into(),
            sender: sender.clone(),
            prepared_sender: broadcast::channel(8).0,
            manifest,
            daemon_epoch: "epoch".into(),
            replay_buffer: Arc::new(Mutex::new(ReplayBuffer::new(8))),
            db: db_slot.clone(),
            async_db: AsyncDaemonDbSlot::empty(),
            db_path: None,
            codex_controller: CodexControllerHandle::new(sender.clone(), db_slot.clone(), false),
            acp_agent_manager: AcpAgentManagerHandle::new(sender.clone(), db_slot.clone()),
            agent_tui_manager: AgentTuiManagerHandle::new(sender, db_slot, false),
            managed_agent_mutation_locks: crate::daemon::http::ManagedAgentMutationLocks::default(),
        }
    }

    fn auth_headers() -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(AUTHORIZATION, "Bearer token".parse().expect("auth header"));
        headers
    }

    async fn response_json(response: axum::response::Response) -> (StatusCode, serde_json::Value) {
        let status = response.status();
        let bytes = to_bytes(response.into_body(), 65536).await.expect("body");
        let json: serde_json::Value = serde_json::from_slice(&bytes).expect("json body");
        (status, json)
    }

    #[tokio::test]
    async fn transcript_requires_a_scoped_session_id() {
        temp_env::async_with_vars([("HARNESS_FEATURE_ACP", Some("1"))], async {
            let state = minimal_state();
            let response = get_acp_transcript(
                Query(AcpTranscriptQuery { session_id: None }),
                auth_headers(),
                State(state),
            )
            .await;
            let (status, body) = response_json(response).await;
            assert_eq!(status, StatusCode::BAD_REQUEST);
            assert!(
                body.to_string()
                    .contains("session_id is required for ACP transcript reads"),
                "expected usage error to mention canonical session_id"
            );
        })
        .await;
    }

    #[tokio::test]
    async fn transcript_uses_session_id_scope() {
        temp_env::async_with_vars([("HARNESS_FEATURE_ACP", Some("1"))], async {
            let state = crate::daemon::http::tests::test_http_state_with_db();
            let db = state.db.get().expect("db slot").clone();
            {
                let db = db.lock().expect("db lock");
                let project = crate::daemon::http::tests::sample_project();
                db.sync_project(&project).expect("sync project");
                db.save_session_state(
                    &project.project_id,
                    &crate::daemon::http::tests::sample_session_state(),
                )
                .expect("save session state");
            }
            let response = get_acp_transcript(
                Query(AcpTranscriptQuery {
                    session_id: Some("f9d5e4d8-cbf0-5a86-a4fb-7ea71f7116e4".into()),
                }),
                auth_headers(),
                State(state),
            )
            .await;
            let (status, body) = response_json(response).await;
            assert_eq!(status, StatusCode::OK);
            assert_eq!(body["entries"].as_array().map(Vec::len), Some(0));
        })
        .await;
    }
}
