use std::time::Instant;

use axum::extract::{Query, State};
use axum::http::HeaderMap;
use axum::response::Response;
use serde::Deserialize;

use crate::daemon::agent_acp::AcpAgentInspectResponse;
use crate::daemon::protocol::http_paths;
use crate::errors::{CliError, CliErrorKind};

use super::super::DaemonHttpState;
use super::super::auth::require_auth;
use super::super::response::{extract_request_id, timed_json};

#[derive(Debug, Deserialize)]
pub(super) struct AcpInspectQuery {
    session_id: Option<String>,
    /// When provided, asserts the caller's session scope. If `session_id` is
    /// also present and differs, returns `SESSION_SCOPE_DENIED`. When
    /// `session_id` is absent, acts as an implicit scope filter identical to
    /// providing `session_id`.
    require_session_id: Option<String>,
}

pub(super) async fn get_acp_inspect(
    Query(query): Query<AcpInspectQuery>,
    headers: HeaderMap,
    State(state): State<DaemonHttpState>,
) -> Response {
    let start = Instant::now();
    let request_id = extract_request_id(&headers);
    if let Err(response) = require_auth(&headers, &state) {
        return *response;
    }
    let result: Result<AcpAgentInspectResponse, CliError> = (|| {
        if let (Some(required), Some(explicit)) = (&query.require_session_id, &query.session_id)
            && required != explicit
        {
            return Err(CliErrorKind::session_scope_denied(
                "require_session_id does not match session_id",
            )
            .into());
        }
        let effective = query
            .session_id
            .as_deref()
            .or(query.require_session_id.as_deref());
        state.acp_agent_manager.inspect(effective)
    })();
    timed_json(
        "GET",
        http_paths::MANAGED_AGENTS_ACP_INSPECT,
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
    async fn inspect_returns_scope_denied_when_require_and_session_ids_conflict() {
        let state = minimal_state();
        let response = get_acp_inspect(
            Query(AcpInspectQuery {
                session_id: Some("session-a".into()),
                require_session_id: Some("session-b".into()),
            }),
            auth_headers(),
            State(state),
        )
        .await;
        let (status, body) = response_json(response).await;
        assert_eq!(status, StatusCode::FORBIDDEN);
        assert_eq!(body["error"]["code"], "SESSION_SCOPE_DENIED");
    }

    #[tokio::test]
    async fn inspect_uses_require_session_id_as_filter_when_session_id_absent() {
        let state = minimal_state();
        let response = get_acp_inspect(
            Query(AcpInspectQuery {
                session_id: None,
                require_session_id: Some("session-a".into()),
            }),
            auth_headers(),
            State(state),
        )
        .await;
        let (status, body) = response_json(response).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["agents"].as_array().map(Vec::len), Some(0));
    }
}
