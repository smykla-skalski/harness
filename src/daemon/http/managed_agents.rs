use std::time::Instant;

use axum::Router;
use axum::body::Body;
use axum::extract::MatchedPath;
use axum::http::Request;
use axum::middleware::{self, Next};
use axum::response::Response;
use axum::routing::{delete, get, post};

use crate::daemon::protocol::http_paths;
use crate::errors::{CliError, CliErrorKind};
use crate::feature_flags::acp_enabled_from_env;

use super::DaemonHttpState;
use super::response::{extract_request_id, timed_json};

mod acp_delete;
mod acp_inspect;
mod acp_start;
mod attach;
mod lookup;
mod mutations;
pub(crate) mod reads;
mod snapshots;

pub(crate) use lookup::{ensure_acp_agent, ensure_codex_agent, ensure_terminal_agent};
pub(crate) use snapshots::{
    acp_inspect_response, managed_agent_list_response, managed_agent_snapshot,
};

pub(super) fn managed_agent_routes() -> Router<DaemonHttpState> {
    Router::new()
        .route(
            http_paths::SESSION_MANAGED_AGENTS,
            get(reads::get_managed_agents),
        )
        .route(
            http_paths::SESSION_MANAGED_AGENTS_TERMINAL,
            post(mutations::post_terminal_agent_start),
        )
        .route(
            http_paths::SESSION_MANAGED_AGENTS_CODEX,
            post(mutations::post_codex_agent_start),
        )
        .route(
            http_paths::SESSION_MANAGED_AGENTS_ACP,
            post(acp_start::post_acp_agent_start)
                .route_layer(middleware::from_fn(require_acp_enabled_http)),
        )
        .route(
            http_paths::MANAGED_AGENT_DETAIL,
            get(reads::get_managed_agent),
        )
        .route(
            http_paths::MANAGED_AGENT_DETAIL,
            delete(acp_delete::delete_acp_agent)
                .route_layer(middleware::from_fn(require_acp_enabled_http)),
        )
        .route(
            http_paths::MANAGED_AGENT_INPUT,
            post(mutations::post_terminal_agent_input),
        )
        .route(
            http_paths::MANAGED_AGENT_RESIZE,
            post(mutations::post_terminal_agent_resize),
        )
        .route(
            http_paths::MANAGED_AGENT_STOP,
            post(mutations::post_terminal_agent_stop),
        )
        .route(
            http_paths::MANAGED_AGENT_READY,
            post(mutations::post_terminal_agent_ready),
        )
        .route(
            http_paths::MANAGED_AGENT_ATTACH,
            get(attach::get_terminal_agent_attach),
        )
        .route(
            http_paths::MANAGED_AGENT_STEER,
            post(mutations::post_codex_agent_steer),
        )
        .route(
            http_paths::MANAGED_AGENT_INTERRUPT,
            post(mutations::post_codex_agent_interrupt),
        )
        .route(
            http_paths::MANAGED_AGENT_APPROVAL,
            post(mutations::post_codex_agent_approval),
        )
        .route(
            http_paths::MANAGED_AGENT_ACP_PERMISSION,
            post(mutations::post_acp_permission)
                .route_layer(middleware::from_fn(require_acp_enabled_http)),
        )
        .route(
            http_paths::MANAGED_AGENTS_ACP_INSPECT,
            get(acp_inspect::get_acp_inspect)
                .route_layer(middleware::from_fn(require_acp_enabled_http)),
        )
}

async fn require_acp_enabled_http(request: Request<Body>, next: Next) -> Response {
    let start = Instant::now();
    if acp_enabled_from_env() {
        return next.run(request).await;
    }

    let method = request.method().to_string();
    let path = request.extensions().get::<MatchedPath>().map_or_else(
        || request.uri().path().to_string(),
        |matched| matched.as_str().to_string(),
    );
    let request_id = extract_request_id(request.headers());
    timed_json(
        &method,
        &path,
        &request_id,
        start,
        Err::<serde_json::Value, CliError>(CliErrorKind::acp_disabled().into()),
    )
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex, OnceLock};

    use reqwest::StatusCode;
    use serde_json::json;
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

    async fn response_json(response: reqwest::Response) -> (StatusCode, serde_json::Value) {
        let status = response.status();
        let json: serde_json::Value = response.json().await.expect("json body");
        (status, json)
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
                .post(format!("{base_url}/v1/sessions/test-session/managed-agents/acp"))
                .bearer_auth("token")
                .json(&json!({
                    "agent": "copilot",
                    "role": "worker",
                    "capabilities": [],
                    "record_permissions": false
                }))
                .send()
                .await
                .expect("send request");
            let (status, body) = response_json(response).await;
            server.abort();
            let _ = server.await;
            assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
            assert_eq!(body["error"]["code"], "ACP_DISABLED");
        })
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
            server.abort();
            let _ = server.await;
            assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
            assert_eq!(body["error"]["code"], "ACP_DISABLED");
        })
        .await;
    }
}
