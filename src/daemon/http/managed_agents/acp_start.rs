use std::time::Instant;

use axum::Json;
use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::response::Response;

use crate::daemon::agent_acp::AcpAgentStartRequest;
use crate::daemon::protocol::{ManagedAgentSnapshot, http_paths};
use crate::errors::{CliError, CliErrorKind};
use crate::feature_flags;

use super::super::DaemonHttpState;
use super::super::auth::require_auth;
use super::super::response::{extract_request_id, timed_json};

pub(super) async fn post_acp_agent_start(
    Path(session_id): Path<String>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
    Json(request): Json<AcpAgentStartRequest>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    if !feature_flags::acp_enabled_from_env() {
        return timed_json(
            "POST",
            http_paths::SESSION_MANAGED_AGENTS_ACP,
            &request_id,
            start,
            Err::<ManagedAgentSnapshot, CliError>(CliErrorKind::acp_disabled().into()),
        );
    }
    let result = state
        .acp_agent_manager
        .start(&session_id, &request)
        .map(ManagedAgentSnapshot::Acp);
    timed_json(
        "POST",
        http_paths::SESSION_MANAGED_AGENTS_ACP,
        &request_id,
        start,
        result,
    )
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex, OnceLock};

    use axum::body::to_bytes;
    use axum::extract::{Path, State};
    use axum::http::{HeaderMap, StatusCode, header::AUTHORIZATION};
    use tokio::sync::broadcast;

    use crate::daemon::agent_acp::{AcpAgentManagerHandle, AcpAgentStartRequest};
    use crate::daemon::agent_tui::AgentTuiManagerHandle;
    use crate::daemon::codex_controller::CodexControllerHandle;
    use crate::daemon::http::{AsyncDaemonDbSlot, DaemonHttpState};
    use crate::daemon::protocol::StreamEvent;
    use crate::daemon::state::DaemonManifest;
    use crate::daemon::websocket::ReplayBuffer;
    use crate::session::types::SessionRole;

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
    async fn acp_start_returns_acp_disabled_error_when_feature_flag_off() {
        temp_env::async_with_vars([("HARNESS_FEATURE_ACP", Some("0"))], async {
            let state = minimal_state();
            let request = AcpAgentStartRequest {
                agent: "copilot".into(),
                role: SessionRole::Worker,
                fallback_role: None,
                capabilities: vec![],
                name: None,
                prompt: None,
                project_dir: None,
                persona: None,
                record_permissions: false,
            };
            let response = post_acp_agent_start(
                Path("test-session".to_string()),
                auth_headers(),
                State(state),
                axum::Json(request),
            )
            .await;
            let (status, body) = response_json(response).await;
            assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
            assert_eq!(body["error"]["code"], "ACP_DISABLED");
        })
        .await;
    }
}
