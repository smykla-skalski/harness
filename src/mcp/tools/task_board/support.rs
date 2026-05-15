use std::fmt::Write as _;
use std::fs;

use async_trait::async_trait;
use futures_util::{SinkExt, StreamExt};
use serde::de::DeserializeOwned;
use serde_json::{Map, Value};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::http::header::AUTHORIZATION;
use tokio_tungstenite::tungstenite::protocol::Message;
use uuid::Uuid;

use crate::daemon::discovery::{self, AdoptionOutcome};
use crate::daemon::protocol::{WsErrorPayload, WsRequest, WsResponse, http_paths};
use crate::daemon::state;
use crate::mcp::protocol::ToolResult;
use crate::mcp::tool::{Tool, ToolError, ToolRegistry};

pub(super) type NormalizeFn = fn(Value) -> Result<Value, ToolError>;
type InputSchemaFn = fn() -> Value;

#[derive(Clone, Copy)]
pub(super) struct TaskBoardToolDescriptor {
    pub name: &'static str,
    pub description: &'static str,
    pub input_schema: InputSchemaFn,
    pub normalize: NormalizeFn,
}

pub(super) fn register_descriptors(
    registry: &mut ToolRegistry,
    descriptors: &[TaskBoardToolDescriptor],
) {
    for descriptor in descriptors {
        registry.register(Box::new(TaskBoardProxyTool::new(*descriptor)));
    }
}

struct TaskBoardProxyTool {
    descriptor: TaskBoardToolDescriptor,
}

impl TaskBoardProxyTool {
    const fn new(descriptor: TaskBoardToolDescriptor) -> Self {
        Self { descriptor }
    }
}

#[async_trait]
impl Tool for TaskBoardProxyTool {
    fn name(&self) -> &'static str {
        self.descriptor.name
    }

    fn description(&self) -> &'static str {
        self.descriptor.description
    }

    fn input_schema(&self) -> Value {
        (self.descriptor.input_schema)()
    }

    async fn call(&self, params: Value) -> Result<ToolResult, ToolError> {
        let normalized = (self.descriptor.normalize)(params)?;
        proxy_task_board_call(self.descriptor.name, normalized).await
    }
}

pub(super) fn validate_params<T: DeserializeOwned>(params: Value) -> Result<Value, ToolError> {
    let normalized = normalize_null_object(params);
    serde_json::from_value::<T>(normalized.clone())
        .map_err(|error| ToolError::invalid(error.to_string()))?;
    Ok(normalized)
}

pub(super) fn validate_empty_object(params: Value) -> Result<Value, ToolError> {
    let normalized = normalize_null_object(params);
    match normalized {
        Value::Object(map) if map.is_empty() => Ok(Value::Object(map)),
        Value::Object(_) => Err(ToolError::invalid("this tool does not accept arguments")),
        _ => Err(ToolError::invalid("arguments must be a JSON object")),
    }
}

fn normalize_null_object(params: Value) -> Value {
    if params.is_null() {
        Value::Object(Map::new())
    } else {
        params
    }
}

struct DaemonWebSocketConnection {
    url: String,
    auth_token: String,
}

fn daemon_websocket_connection() -> Result<DaemonWebSocketConnection, ToolError> {
    match discovery::adopt_running_daemon_root() {
        AdoptionOutcome::AlreadyCoherent { .. } | AdoptionOutcome::Adopted { .. } => {}
        AdoptionOutcome::NoRunningDaemon { default_root } => {
            return Err(ToolError::internal(format!(
                "task-board MCP tools require a running daemon under {}",
                default_root.display()
            )));
        }
    }

    let manifest = state::load_running_manifest()
        .map_err(|error| ToolError::internal(format!("load running daemon manifest: {error}")))?
        .ok_or_else(|| {
            ToolError::internal("task-board MCP tools could not find a running daemon")
        })?;

    let auth_token = fs::read_to_string(&manifest.token_path)
        .map_err(|error| ToolError::internal(format!("read daemon auth token: {error}")))?;
    let auth_token = auth_token.trim().to_string();
    if auth_token.is_empty() {
        return Err(ToolError::internal("daemon auth token is empty"));
    }

    Ok(DaemonWebSocketConnection {
        url: websocket_url(&manifest.endpoint)?,
        auth_token,
    })
}

fn websocket_url(endpoint: &str) -> Result<String, ToolError> {
    let base = if let Some(rest) = endpoint.strip_prefix("http://") {
        format!("ws://{rest}")
    } else if let Some(rest) = endpoint.strip_prefix("https://") {
        format!("wss://{rest}")
    } else {
        return Err(ToolError::internal(format!(
            "unsupported daemon endpoint scheme: {endpoint}"
        )));
    };
    Ok(format!("{base}{}", http_paths::WS))
}

async fn proxy_task_board_call(method: &str, params: Value) -> Result<ToolResult, ToolError> {
    let connection = daemon_websocket_connection()?;
    let mut request = connection.url.into_client_request().map_err(|error| {
        ToolError::internal(format!("prepare daemon websocket request: {error}"))
    })?;
    let header =
        HeaderValue::from_str(&format!("Bearer {}", connection.auth_token)).map_err(|error| {
            ToolError::internal(format!("build daemon authorization header: {error}"))
        })?;
    request.headers_mut().insert(AUTHORIZATION, header);

    let (mut socket, _) = connect_async(request)
        .await
        .map_err(|error| ToolError::internal(format!("connect to running daemon: {error}")))?;

    let request_id = format!("mcp-{}", Uuid::new_v4());
    let payload = serde_json::to_string(&WsRequest {
        id: request_id.clone(),
        method: method.to_string(),
        params,
        trace_context: None,
    })
    .map_err(|error| ToolError::internal(format!("serialize daemon websocket request: {error}")))?;

    socket
        .send(Message::Text(payload.into()))
        .await
        .map_err(|error| ToolError::internal(format!("send daemon websocket request: {error}")))?;

    while let Some(frame) = socket.next().await {
        let frame = frame.map_err(|error| {
            ToolError::internal(format!("read daemon websocket response: {error}"))
        })?;
        let Ok(text) = frame.into_text() else {
            continue;
        };
        let Ok(value) = serde_json::from_str::<Value>(text.as_ref()) else {
            continue;
        };
        if value.get("id").and_then(Value::as_str) != Some(request_id.as_str()) {
            continue;
        }

        let response = serde_json::from_value::<WsResponse>(value).map_err(|error| {
            ToolError::internal(format!("decode daemon websocket response: {error}"))
        })?;
        let _ = socket.close(None).await;
        return tool_result_from_response(method, response);
    }

    Err(ToolError::internal(
        "daemon websocket closed before the task-board tool received a response",
    ))
}

fn tool_result_from_response(method: &str, response: WsResponse) -> Result<ToolResult, ToolError> {
    if let Some(error) = response.error {
        let message = format_ws_error(method, &error);
        return match error.code.as_str() {
            "INVALID_PARAMS" | "MISSING_PARAM" => Err(ToolError::invalid(message)),
            _ => Ok(ToolResult::error(message)),
        };
    }

    ToolResult::json_text(&response.result.unwrap_or(Value::Null))
        .map_err(|error| ToolError::internal(format!("serialize task-board MCP response: {error}")))
}

fn format_ws_error(method: &str, error: &WsErrorPayload) -> String {
    let mut message = format!("{method}: {}", error.message);
    if let Some(status_code) = error.status_code {
        let _ = write!(message, " (status {status_code})");
    }
    if !error.details.is_empty() {
        let _ = write!(message, " [{}]", error.details.join("; "));
    }
    message
}
