use std::fs;
use std::sync::{Arc, OnceLock};

use axum::Router;
use axum::extract::State;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::http::HeaderMap;
use axum::http::header::AUTHORIZATION;
use axum::response::IntoResponse;
use axum::routing::get;
use serde_json::{Value, json};
use tempfile::TempDir;
use tokio::net::TcpListener;
use tokio::sync::{Mutex as AsyncMutex, oneshot};
use tokio::task::JoinHandle;

use crate::daemon::protocol::{WsRequest, http_paths, ws_methods};
use crate::daemon::state::{self, DaemonManifest, ScopedDaemonRootOverride};
use crate::mcp::protocol::{ContentBlock, ToolResult};
use crate::mcp::registry::RegistryClient;
use crate::mcp::tool::ToolRegistry;

use super::{register_all, socket_path};

mod orchestrator_settings_tests;

static DAEMON_TEST_MUTEX: OnceLock<AsyncMutex<()>> = OnceLock::new();

fn daemon_test_mutex() -> &'static AsyncMutex<()> {
    DAEMON_TEST_MUTEX.get_or_init(|| AsyncMutex::new(()))
}

#[derive(Debug)]
struct CapturedWsRequest {
    authorization: Option<String>,
    request: WsRequest,
}

#[derive(Clone)]
struct WsServerState {
    captured: Arc<AsyncMutex<Option<oneshot::Sender<CapturedWsRequest>>>>,
    response: Value,
}

async fn ws_handler(
    ws: WebSocketUpgrade,
    State(state): State<WsServerState>,
    headers: HeaderMap,
) -> impl IntoResponse {
    let authorization = headers
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);
    ws.on_upgrade(move |socket| handle_socket(socket, state, authorization))
}

async fn handle_socket(mut socket: WebSocket, state: WsServerState, authorization: Option<String>) {
    let Some(Ok(Message::Text(text))) = socket.recv().await else {
        return;
    };
    let request =
        serde_json::from_str::<WsRequest>(text.as_ref()).expect("parse websocket request");
    if let Some(sender) = state.captured.lock().await.take() {
        let _ = sender.send(CapturedWsRequest {
            authorization,
            request: request.clone(),
        });
    }

    let response = json!({
        "id": request.id,
        "result": state.response,
        "error": null,
    });
    socket
        .send(Message::Text(response.to_string().into()))
        .await
        .expect("send websocket response");
}

async fn spawn_task_board_server(
    response: Value,
) -> (String, oneshot::Receiver<CapturedWsRequest>, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind websocket server");
    let endpoint = format!("http://{}", listener.local_addr().expect("local addr"));
    let (sender, receiver) = oneshot::channel();
    let state = WsServerState {
        captured: Arc::new(AsyncMutex::new(Some(sender))),
        response,
    };
    let server = tokio::spawn(async move {
        axum::serve(
            listener,
            Router::new()
                .route(http_paths::WS, get(ws_handler))
                .with_state(state),
        )
        .await
        .expect("serve task-board websocket");
    });
    (endpoint, receiver, server)
}

fn task_board_registry() -> ToolRegistry {
    let dir = TempDir::new().expect("tempdir");
    let client = Arc::new(RegistryClient::with_socket_path(socket_path(&dir)));
    let mut registry = ToolRegistry::new();
    register_all(&mut registry, &client);
    registry
}

async fn call_task_board_tool(
    tool_name: &str,
    arguments: Value,
    response: Value,
) -> (ToolResult, CapturedWsRequest) {
    let _guard = daemon_test_mutex().lock().await;
    let (endpoint, captured, server) = spawn_task_board_server(response).await;
    let dir = TempDir::new().expect("tempdir");
    let root = dir.path().join("daemon-root");
    let _override = ScopedDaemonRootOverride::set(Some(root));
    let _lock = state::acquire_singleton_lock().expect("acquire daemon lock");
    let token_path = state::auth_token_path();
    fs::write(&token_path, "test-token").expect("write auth token");
    let manifest = DaemonManifest {
        endpoint,
        token_path: token_path.display().to_string(),
    };
    let _ = state::write_manifest(&manifest).expect("write manifest");

    let registry = task_board_registry();
    let tool = registry
        .get(tool_name)
        .expect("task-board tool should exist");
    let result = tool
        .call(arguments)
        .await
        .expect("tool call should succeed");
    let captured = captured.await.expect("capture websocket request");

    server.abort();
    let _ = server.await;

    (result, captured)
}

fn text_result_json(result: &ToolResult) -> Value {
    assert!(!result.is_error, "unexpected tool error result");
    assert_eq!(result.content.len(), 1);
    match &result.content[0] {
        ContentBlock::Text { text } => serde_json::from_str(text).expect("tool json content"),
        other @ ContentBlock::Image { .. } => {
            panic!("expected text content, got {other:?}")
        }
    }
}

#[tokio::test(flavor = "current_thread")]
async fn create_tool_proxies_to_running_daemon() {
    let arguments = json!({
        "title": "Ship MCP parity",
        "priority": "high",
        "tags": ["mcp"],
    });
    let (result, captured) = call_task_board_tool(
        ws_methods::TASK_BOARD_CREATE,
        arguments.clone(),
        json!({ "id": "board-1" }),
    )
    .await;

    assert_eq!(text_result_json(&result), json!({ "id": "board-1" }));
    assert_eq!(captured.authorization.as_deref(), Some("Bearer test-token"));
    assert_eq!(captured.request.method, ws_methods::TASK_BOARD_CREATE);
    assert_eq!(captured.request.params, arguments);
}

#[tokio::test(flavor = "current_thread")]
async fn update_tool_proxies_to_running_daemon() {
    let arguments = json!({
        "id": "board-1",
        "status": "in_progress",
    });
    let (result, captured) = call_task_board_tool(
        ws_methods::TASK_BOARD_UPDATE,
        arguments.clone(),
        json!({ "updated": true }),
    )
    .await;

    assert_eq!(text_result_json(&result), json!({ "updated": true }));
    assert_eq!(captured.request.method, ws_methods::TASK_BOARD_UPDATE);
    assert_eq!(captured.request.params, arguments);
}

#[tokio::test(flavor = "current_thread")]
async fn plan_submit_tool_proxies_to_running_daemon() {
    let arguments = json!({
        "id": "board-1",
        "summary": "Detailed execution plan",
    });
    let (result, captured) = call_task_board_tool(
        ws_methods::TASK_BOARD_PLAN_SUBMIT,
        arguments.clone(),
        json!({ "submitted": true }),
    )
    .await;

    assert_eq!(text_result_json(&result), json!({ "submitted": true }));
    assert_eq!(captured.request.method, ws_methods::TASK_BOARD_PLAN_SUBMIT);
    assert_eq!(captured.request.params, arguments);
}

#[tokio::test(flavor = "current_thread")]
async fn sync_tool_proxies_to_running_daemon() {
    let arguments = json!({
        "status": "todo",
        "dry_run": true,
    });
    let (result, captured) = call_task_board_tool(
        ws_methods::TASK_BOARD_SYNC,
        arguments.clone(),
        json!({ "synced": 2 }),
    )
    .await;

    assert_eq!(text_result_json(&result), json!({ "synced": 2 }));
    assert_eq!(captured.request.method, ws_methods::TASK_BOARD_SYNC);
    assert_eq!(captured.request.params, arguments);
}

#[tokio::test(flavor = "current_thread")]
async fn dispatch_tool_proxies_to_running_daemon() {
    let arguments = json!({
        "status": "todo",
        "dry_run": true,
    });
    let (result, captured) = call_task_board_tool(
        ws_methods::TASK_BOARD_DISPATCH,
        arguments.clone(),
        json!({ "dispatched": 1 }),
    )
    .await;

    assert_eq!(text_result_json(&result), json!({ "dispatched": 1 }));
    assert_eq!(captured.request.method, ws_methods::TASK_BOARD_DISPATCH);
    assert_eq!(captured.request.params, arguments);
}

#[tokio::test(flavor = "current_thread")]
async fn policy_save_draft_tool_proxies_to_running_daemon() {
    let arguments = json!({
        "document": {},
    });
    let (result, captured) = call_task_board_tool(
        ws_methods::POLICY_PIPELINE_SAVE_DRAFT,
        arguments.clone(),
        json!({ "revision": 2 }),
    )
    .await;

    assert_eq!(text_result_json(&result), json!({ "revision": 2 }));
    assert_eq!(
        captured.request.method,
        ws_methods::POLICY_PIPELINE_SAVE_DRAFT
    );
    assert_eq!(captured.request.params, arguments);
}

/// Public fields the MCP create schema must advertise. Hard-coded so a
/// future field rename or addition forces this test to fail until
/// `create_schema` is updated.
const TASK_BOARD_CREATE_FIELDS: &[&str] = &[
    "title",
    "body",
    "priority",
    "agent_mode",
    "tags",
    "project_id",
    "target_project_types",
    "external_refs",
    "planning",
    "workflow",
    "session_id",
    "work_item_id",
    "id",
];

/// Public fields the MCP update schema must advertise. Same regression guard
/// shape as `TASK_BOARD_CREATE_FIELDS`.
const TASK_BOARD_UPDATE_FIELDS: &[&str] = &[
    "id",
    "title",
    "body",
    "status",
    "priority",
    "agent_mode",
    "tags",
    "project_id",
    "target_project_types",
    "external_refs",
    "planning",
    "workflow",
    "session_id",
    "work_item_id",
];

fn assert_schema_covers_fields(schema: &Value, tool_name: &str, expected: &[&str]) {
    let properties = schema
        .get("properties")
        .and_then(Value::as_object)
        .unwrap_or_else(|| panic!("{tool_name} schema missing properties object"));
    for field in expected {
        assert!(
            properties.contains_key(*field),
            "{tool_name} schema missing field `{field}`; properties: {:?}",
            properties.keys().collect::<Vec<_>>()
        );
    }
    assert_eq!(
        schema.get("additionalProperties"),
        Some(&Value::Bool(false)),
        "{tool_name} schema must reject unknown fields for strict-client compatibility"
    );
}

fn assert_schema_omits_field(schema: &Value, tool_name: &str, field: &str) {
    let properties = schema
        .get("properties")
        .and_then(Value::as_object)
        .unwrap_or_else(|| panic!("{tool_name} schema missing properties object"));
    assert!(
        !properties.contains_key(field),
        "{tool_name} schema advertises unsupported field `{field}`"
    );
}

fn assert_schema_requires_fields(schema: &Value, tool_name: &str, expected: &[&str]) {
    let required = schema
        .get("required")
        .and_then(Value::as_array)
        .unwrap_or_else(|| panic!("{tool_name} schema missing required array"));
    for field in expected {
        assert!(
            required.iter().any(|value| value.as_str() == Some(*field)),
            "{tool_name} schema does not require `{field}`; required: {required:?}"
        );
    }
}

fn task_board_tool_schema(tool_name: &str) -> Value {
    let registry = task_board_registry();
    let tool = registry
        .get(tool_name)
        .unwrap_or_else(|| panic!("{tool_name} tool registered"));
    tool.input_schema()
}

#[test]
fn create_schema_covers_every_public_field() {
    let schema = task_board_tool_schema(ws_methods::TASK_BOARD_CREATE);
    assert_schema_covers_fields(
        &schema,
        ws_methods::TASK_BOARD_CREATE,
        TASK_BOARD_CREATE_FIELDS,
    );

    let probe = json!({
        "title": "probe",
        "body": "",
        "priority": "high",
        "agent_mode": "headless",
        "tags": ["mcp"],
        "project_id": "proj-1",
        "target_project_types": ["web"],
        "external_refs": [],
        "planning": { "summary": "draft" },
        "session_id": "sess-1",
        "work_item_id": "work-1",
        "id": "item-1",
    });
    let schema = task_board_tool_schema(ws_methods::TASK_BOARD_CREATE);
    let properties = schema["properties"].as_object().expect("properties");
    for field in probe.as_object().expect("probe object").keys() {
        assert!(properties.contains_key(field), "schema omitted `{field}`");
    }
}

#[test]
fn update_schema_uses_strict_additional_properties() {
    let schema = task_board_tool_schema(ws_methods::TASK_BOARD_UPDATE);
    assert_schema_covers_fields(
        &schema,
        ws_methods::TASK_BOARD_UPDATE,
        TASK_BOARD_UPDATE_FIELDS,
    );
}

#[test]
fn policy_schemas_advertise_protocol_fields() {
    for tool_name in [
        ws_methods::POLICY_PIPELINE_GET,
        ws_methods::POLICY_PIPELINE_AUDIT,
        ws_methods::POLICY_CANVAS_EXPORT,
    ] {
        assert_schema_covers_fields(
            &task_board_tool_schema(tool_name),
            tool_name,
            &["canvas_id"],
        );
    }

    for tool_name in [
        ws_methods::POLICY_PIPELINE_SIMULATE,
        ws_methods::POLICY_PIPELINE_GO_LIVE_DIFF,
    ] {
        let schema = task_board_tool_schema(tool_name);
        assert_schema_covers_fields(&schema, tool_name, &["canvas_id", "document"]);
        assert_schema_omits_field(&schema, tool_name, "if_revision");
    }

    let save_draft_schema = task_board_tool_schema(ws_methods::POLICY_PIPELINE_SAVE_DRAFT);
    assert_schema_covers_fields(
        &save_draft_schema,
        ws_methods::POLICY_PIPELINE_SAVE_DRAFT,
        &["canvas_id", "if_revision", "document"],
    );
    assert_schema_requires_fields(
        &save_draft_schema,
        ws_methods::POLICY_PIPELINE_SAVE_DRAFT,
        &["document"],
    );

    for tool_name in [
        ws_methods::POLICY_PIPELINE_PROMOTE,
        ws_methods::POLICY_PIPELINE_MAKE_LIVE,
    ] {
        let schema = task_board_tool_schema(tool_name);
        assert_schema_covers_fields(&schema, tool_name, &["canvas_id", "revision", "actor"]);
        assert_schema_requires_fields(&schema, tool_name, &["revision"]);
    }

    let import_schema = task_board_tool_schema(ws_methods::POLICY_CANVAS_IMPORT);
    assert_schema_covers_fields(
        &import_schema,
        ws_methods::POLICY_CANVAS_IMPORT,
        &["document", "title"],
    );
    assert_schema_requires_fields(
        &import_schema,
        ws_methods::POLICY_CANVAS_IMPORT,
        &["document"],
    );
}
