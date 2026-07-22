use std::sync::{Arc, Mutex, OnceLock};

use reqwest::StatusCode;
use serde_json::json;
use tempfile::tempdir;
use tokio::net::TcpListener;
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
        auth_mode: crate::daemon::http::DaemonHttpAuthMode::Local,
        remote_domain: None,
        remote_request_limits: None,
        remote_pairing_limiter: crate::daemon::http::default_remote_pairing_limiter(),
        remote_pairing_status_limiter: crate::daemon::http::default_remote_pairing_status_limiter(),
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
        agent_tui_manager: AgentTuiManagerHandle::new(sender.clone(), db_slot, false),
        managed_agent_mutation_locks: crate::daemon::http::ManagedAgentMutationLocks::default(),
        recovery_snapshot: Default::default(),
    }
}

async fn response_json(response: reqwest::Response) -> (StatusCode, serde_json::Value) {
    let status = response.status();
    let json: serde_json::Value = response.json().await.expect("json body");
    (status, json)
}

async fn response_text(response: reqwest::Response) -> (StatusCode, String) {
    let status = response.status();
    let body = response.text().await.expect("text body");
    (status, body)
}

async fn stop_server(server: tokio::task::JoinHandle<()>) {
    server.abort();
    let _ = server.await;
}

async fn spawn_managed_agent_server(
    state: DaemonHttpState,
) -> (String, tokio::task::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind listener");
    let addr = listener.local_addr().expect("listener addr");
    let server = tokio::spawn(async move {
        axum::serve(listener, managed_agent_routes().with_state(state))
            .await
            .expect("serve managed agent routes");
    });
    (format!("http://{addr}"), server)
}

#[tokio::test]
async fn acp_start_route_returns_acp_disabled_when_feature_flag_off() {
    temp_env::async_with_vars([("HARNESS_FEATURE_ACP", Some("0"))], async {
        let (base_url, server) = spawn_managed_agent_server(minimal_state()).await;
        let response = reqwest::Client::new()
            .post(format!(
                "{base_url}/v1/sessions/test-session/managed-agents/acp"
            ))
            .bearer_auth("token")
            .json(&json!({
                "descriptor_id": "copilot",
                "role": "worker",
                "capabilities": [],
                "record_permissions": false
            }))
            .send()
            .await
            .expect("send request");
        let (status, body) = response_json(response).await;
        stop_server(server).await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(body["error"]["code"], "ACP_DISABLED");
    })
    .await;
}

/// MCP servers have no CLI flag, so this route is the only way to set them.
/// The request type denies unknown fields, so a decode gap shows up as 422
/// here rather than as inputs the agent silently never receives.
#[tokio::test]
async fn acp_start_route_accepts_per_start_mcp_servers_and_directories() {
    temp_env::async_with_vars([("HARNESS_FEATURE_ACP", Some("0"))], async {
        let (base_url, server) = spawn_managed_agent_server(minimal_state()).await;
        let response = reqwest::Client::new()
            .post(format!(
                "{base_url}/v1/sessions/test-session/managed-agents/acp"
            ))
            .bearer_auth("token")
            .json(&json!({
                "descriptor_id": "copilot",
                "role": "worker",
                "capabilities": [],
                "record_permissions": false,
                "additional_directories": ["/extra"],
                "mcp_servers": [{
                    "transport": "http",
                    "name": "remote",
                    "url": "https://example.test/mcp",
                    "headers": [{"name": "Authorization", "value": "Bearer secret"}]
                }]
            }))
            .send()
            .await
            .expect("send request");
        let (status, body) = response_json(response).await;
        stop_server(server).await;
        assert_eq!(
            status,
            StatusCode::SERVICE_UNAVAILABLE,
            "the body must decode and fail on the feature flag, not on parsing"
        );
        assert_eq!(body["error"]["code"], "ACP_DISABLED");
    })
    .await;
}

#[tokio::test]
async fn acp_start_route_rejects_missing_session_before_spawn() {
    let tmp = tempdir().expect("tempdir");
    temp_env::async_with_vars(
        [
            ("HARNESS_FEATURE_ACP", Some("1")),
            (
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 tempdir path")),
            ),
            ("CLAUDE_SESSION_ID", Some("http-acp-missing-session")),
        ],
        async {
            let (base_url, server) =
                spawn_managed_agent_server(super::super::tests::test_http_state_with_db()).await;
            let response = reqwest::Client::new()
                .post(format!(
                    "{base_url}/v1/sessions/11111111-1111-4111-8111-111111111111/managed-agents/acp"
                ))
                .bearer_auth("token")
                .json(&json!({
                    "descriptor_id": "copilot",
                    "role": "worker",
                    "capabilities": [],
                    "record_permissions": false
                }))
                .send()
                .await
                .expect("send request");
            let (status, body) = response_json(response).await;
            stop_server(server).await;
            assert_eq!(status, StatusCode::BAD_REQUEST);
            assert_eq!(body["error"]["code"], "KSRCLI090");
            assert!(
                body["error"]["message"].as_str().is_some_and(|message| {
                    message.contains(
                        "harness session '11111111-1111-4111-8111-111111111111' not found",
                    )
                }),
                "unexpected error body: {body}"
            );
        },
    )
    .await;
}

#[tokio::test]
async fn acp_inspect_route_returns_acp_disabled_when_feature_flag_off() {
    temp_env::async_with_vars([("HARNESS_FEATURE_ACP", Some("0"))], async {
        let (base_url, server) = spawn_managed_agent_server(minimal_state()).await;
        let response = reqwest::Client::new()
            .get(format!("{base_url}/v1/managed-agents/acp/inspect"))
            .bearer_auth("token")
            .send()
            .await
            .expect("send request");
        let (status, body) = response_json(response).await;
        stop_server(server).await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(body["error"]["code"], "ACP_DISABLED");
    })
    .await;
}

#[tokio::test]
async fn acp_inspect_route_rejects_legacy_require_session_id_query_param() {
    temp_env::async_with_vars([("HARNESS_FEATURE_ACP", Some("1"))], async {
        let (base_url, server) = spawn_managed_agent_server(minimal_state()).await;
        let response = reqwest::Client::new()
            .get(format!(
                "{base_url}/v1/managed-agents/acp/inspect?require_session_id=test-session"
            ))
            .bearer_auth("token")
            .send()
            .await
            .expect("send request");
        let (status, body) = response_text(response).await;
        stop_server(server).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert!(
            body.contains("require_session_id"),
            "unexpected rejection body: {body}"
        );
    })
    .await;
}

#[tokio::test]
async fn acp_delete_route_returns_acp_disabled_when_feature_flag_off() {
    temp_env::async_with_vars([("HARNESS_FEATURE_ACP", Some("0"))], async {
        let (base_url, server) = spawn_managed_agent_server(minimal_state()).await;
        let response = reqwest::Client::new()
            .delete(format!(
                "{base_url}/v1/managed-agents/acp-session?session_id=test-session"
            ))
            .bearer_auth("token")
            .send()
            .await
            .expect("send request");
        let (status, body) = response_json(response).await;
        stop_server(server).await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(body["error"]["code"], "ACP_DISABLED");
    })
    .await;
}

#[tokio::test]
async fn acp_delete_route_rejects_legacy_require_session_id_query_param() {
    temp_env::async_with_vars([("HARNESS_FEATURE_ACP", Some("1"))], async {
        let (base_url, server) = spawn_managed_agent_server(minimal_state()).await;
        let response = reqwest::Client::new()
            .delete(format!(
                "{base_url}/v1/managed-agents/acp-session?require_session_id=test-session"
            ))
            .bearer_auth("token")
            .send()
            .await
            .expect("send request");
        let (status, body) = response_text(response).await;
        stop_server(server).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert!(
            body.contains("require_session_id"),
            "unexpected rejection body: {body}"
        );
    })
    .await;
}

#[tokio::test]
async fn acp_transcript_route_rejects_legacy_require_session_id_query_param() {
    temp_env::async_with_vars([("HARNESS_FEATURE_ACP", Some("1"))], async {
        let (base_url, server) = spawn_managed_agent_server(minimal_state()).await;
        let response = reqwest::Client::new()
            .get(format!(
                "{base_url}/v1/managed-agents/acp/transcript?require_session_id=test-session"
            ))
            .bearer_auth("token")
            .send()
            .await
            .expect("send request");
        let (status, body) = response_text(response).await;
        stop_server(server).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert!(
            body.contains("require_session_id"),
            "unexpected rejection body: {body}"
        );
    })
    .await;
}

#[tokio::test]
async fn acp_permission_route_returns_acp_disabled_when_feature_flag_off() {
    temp_env::async_with_vars([("HARNESS_FEATURE_ACP", Some("0"))], async {
        let (base_url, server) = spawn_managed_agent_server(minimal_state()).await;
        let response = reqwest::Client::new()
            .post(format!(
                "{base_url}/v1/managed-agents/acp-session/permission-batches/batch-1"
            ))
            .bearer_auth("token")
            .json(&json!({ "decision": "approve_all" }))
            .send()
            .await
            .expect("send request");
        let (status, body) = response_json(response).await;
        stop_server(server).await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(body["error"]["code"], "ACP_DISABLED");
    })
    .await;
}

#[tokio::test]
async fn acp_start_route_requires_auth_before_feature_flag_check() {
    temp_env::async_with_vars([("HARNESS_FEATURE_ACP", Some("0"))], async {
        let (base_url, server) = spawn_managed_agent_server(minimal_state()).await;
        let response = reqwest::Client::new()
            .post(format!(
                "{base_url}/v1/sessions/test-session/managed-agents/acp"
            ))
            .json(&json!({
                "descriptor_id": "copilot",
                "role": "worker",
                "capabilities": [],
                "record_permissions": false
            }))
            .send()
            .await
            .expect("send request");
        let (status, body) = response_json(response).await;
        stop_server(server).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        assert_eq!(body["error"]["code"], "DAEMON_AUTH");
    })
    .await;
}

#[tokio::test]
async fn acp_session_list_route_returns_acp_disabled_when_feature_flag_off() {
    temp_env::async_with_vars([("HARNESS_FEATURE_ACP", Some("0"))], async {
        let (base_url, server) = spawn_managed_agent_server(minimal_state()).await;
        let response = reqwest::Client::new()
            .get(format!("{base_url}/v1/managed-agents/agent-acp-1/sessions"))
            .bearer_auth("token")
            .send()
            .await
            .expect("send request");
        let (status, body) = response_json(response).await;
        stop_server(server).await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(body["error"]["code"], "ACP_DISABLED");
    })
    .await;
}

#[tokio::test]
async fn acp_session_delete_route_returns_acp_disabled_when_feature_flag_off() {
    temp_env::async_with_vars([("HARNESS_FEATURE_ACP", Some("0"))], async {
        let (base_url, server) = spawn_managed_agent_server(minimal_state()).await;
        let response = reqwest::Client::new()
            .delete(format!(
                "{base_url}/v1/managed-agents/agent-acp-1/sessions/acp-session-1"
            ))
            .bearer_auth("token")
            .send()
            .await
            .expect("send request");
        let (status, body) = response_json(response).await;
        stop_server(server).await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(body["error"]["code"], "ACP_DISABLED");
    })
    .await;
}

#[tokio::test]
async fn acp_session_close_route_returns_acp_disabled_when_feature_flag_off() {
    temp_env::async_with_vars([("HARNESS_FEATURE_ACP", Some("0"))], async {
        let (base_url, server) = spawn_managed_agent_server(minimal_state()).await;
        let response = reqwest::Client::new()
            .post(format!(
                "{base_url}/v1/managed-agents/agent-acp-1/sessions/acp-session-1/close"
            ))
            .bearer_auth("token")
            .send()
            .await
            .expect("send request");
        let (status, body) = response_json(response).await;
        stop_server(server).await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(body["error"]["code"], "ACP_DISABLED");
    })
    .await;
}

#[tokio::test]
async fn acp_session_routes_require_auth_before_feature_flag_check() {
    temp_env::async_with_vars([("HARNESS_FEATURE_ACP", Some("0"))], async {
        let (base_url, server) = spawn_managed_agent_server(minimal_state()).await;
        let response = reqwest::Client::new()
            .get(format!("{base_url}/v1/managed-agents/agent-acp-1/sessions"))
            .send()
            .await
            .expect("send request");
        let (status, body) = response_json(response).await;
        stop_server(server).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        assert_eq!(body["error"]["code"], "DAEMON_AUTH");
    })
    .await;
}
