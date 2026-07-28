use std::fmt::Write as _;
use std::fs;

use async_trait::async_trait;
use futures_util::{SinkExt, StreamExt};
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

type InputSchemaFn = fn() -> Value;

#[derive(Clone, Copy)]
pub(super) struct TaskBoardToolDescriptor {
    pub name: &'static str,
    pub description: &'static str,
    pub input_schema: InputSchemaFn,
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
        let normalized = validate_params(params, &(self.descriptor.input_schema)())?;
        proxy_task_board_call(self.descriptor.name, normalized).await
    }
}

pub(super) fn validate_params(params: Value, schema: &Value) -> Result<Value, ToolError> {
    let normalized = normalize_null_object(params);
    validate_value("arguments", &normalized, schema)?;
    Ok(normalized)
}

fn validate_value(path: &str, value: &Value, schema: &Value) -> Result<(), ToolError> {
    if let Some(constraints) = schema.get("allOf").and_then(Value::as_array) {
        for constraint in constraints {
            validate_value(path, value, constraint)?;
        }
    }
    if let Some(variants) = schema.get("anyOf").and_then(Value::as_array)
        && !variants
            .iter()
            .any(|variant| validate_value(path, value, variant).is_ok())
    {
        return Err(ToolError::invalid(format!(
            "{path} matches none of the advertised variants"
        )));
    }
    if let Some(excluded) = schema.get("not")
        && validate_value(path, value, excluded).is_ok()
    {
        return Err(ToolError::invalid(format!(
            "{path} matches a disallowed field combination"
        )));
    }
    if let Some(expected) = schema.get("const")
        && expected != value
    {
        return Err(ToolError::invalid(format!(
            "{path} must match the advertised constant"
        )));
    }
    if let Some(expected) = schema.get("type").and_then(Value::as_str)
        && !matches_schema_type(value, expected)
    {
        return Err(ToolError::invalid(format!(
            "{path} must be {expected}, got {}",
            value_type(value)
        )));
    }

    if let Some(allowed) = schema.get("enum").and_then(Value::as_array)
        && !allowed.contains(value)
    {
        return Err(ToolError::invalid(format!(
            "{path} must match one of the advertised values"
        )));
    }

    match value {
        Value::Object(object) => validate_object(path, object, schema),
        Value::Array(items) => validate_array(path, items, schema),
        Value::Number(number) => validate_number(path, number, schema),
        _ => Ok(()),
    }
}

fn validate_object(
    path: &str,
    object: &Map<String, Value>,
    schema: &Value,
) -> Result<(), ToolError> {
    if let Some(required) = schema.get("required").and_then(Value::as_array) {
        for field in required.iter().filter_map(Value::as_str) {
            if !object.contains_key(field) {
                return Err(ToolError::invalid(format!(
                    "{path} is missing required field `{field}`"
                )));
            }
        }
    }

    let properties = schema.get("properties").and_then(Value::as_object);
    for (field, field_value) in object {
        let field_path = format!("{path}.{field}");
        if let Some(field_schema) = properties.and_then(|items| items.get(field)) {
            validate_value(&field_path, field_value, field_schema)?;
            continue;
        }
        match schema.get("additionalProperties") {
            Some(Value::Bool(false)) => {
                return Err(ToolError::invalid(format!(
                    "{path} contains unknown field `{field}`"
                )));
            }
            Some(additional_schema @ Value::Object(_)) => {
                validate_value(&field_path, field_value, additional_schema)?;
            }
            _ => {}
        }
    }
    Ok(())
}

fn validate_array(path: &str, items: &[Value], schema: &Value) -> Result<(), ToolError> {
    if let Some(item_schema) = schema.get("items") {
        for (index, item) in items.iter().enumerate() {
            validate_value(&format!("{path}[{index}]"), item, item_schema)?;
        }
    }
    Ok(())
}

fn validate_number(
    path: &str,
    number: &serde_json::Number,
    schema: &Value,
) -> Result<(), ToolError> {
    if let Some(minimum) = schema.get("minimum").and_then(Value::as_f64)
        && number.as_f64().is_some_and(|value| value < minimum)
    {
        return Err(ToolError::invalid(format!(
            "{path} must be at least {minimum}"
        )));
    }
    if let Some(maximum) = schema.get("maximum")
        && number_exceeds_maximum(number, maximum)
    {
        return Err(ToolError::invalid(format!(
            "{path} must be at most {maximum}"
        )));
    }
    Ok(())
}

fn number_exceeds_maximum(number: &serde_json::Number, maximum: &Value) -> bool {
    if let (Some(number), Some(maximum)) = (number.as_u64(), maximum.as_u64()) {
        return number > maximum;
    }
    number
        .as_f64()
        .zip(maximum.as_f64())
        .is_some_and(|(number, maximum)| number > maximum)
}

fn matches_schema_type(value: &Value, expected: &str) -> bool {
    match expected {
        "array" => value.is_array(),
        "boolean" => value.is_boolean(),
        "integer" => value.as_i64().is_some() || value.as_u64().is_some(),
        "number" => value.is_number(),
        "object" => value.is_object(),
        "string" => value.is_string(),
        _ => true,
    }
}

fn value_type(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(number) if number.is_i64() || number.is_u64() => "integer",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
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

/// What one task-board round trip produced.
///
/// A daemon-side refusal is not a transport failure: the MCP contract reports
/// it as a successful call carrying an error message, so a page walk can tell
/// "the daemon said no" apart from "the socket broke" without re-deriving the
/// distinction from a formatted string.
pub(super) enum TaskBoardCallOutcome {
    Result(Value),
    Refused(String),
}

async fn proxy_task_board_call(method: &str, params: Value) -> Result<ToolResult, ToolError> {
    match task_board_call(method, params).await? {
        TaskBoardCallOutcome::Result(value) => ToolResult::json_text(&value).map_err(|error| {
            ToolError::internal(format!("serialize task-board MCP response: {error}"))
        }),
        TaskBoardCallOutcome::Refused(message) => Ok(ToolResult::error(message)),
    }
}

pub(super) async fn task_board_call(
    method: &str,
    params: Value,
) -> Result<TaskBoardCallOutcome, ToolError> {
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
        return outcome_from_response(method, response);
    }

    Err(ToolError::internal(
        "daemon websocket closed before the task-board tool received a response",
    ))
}

fn outcome_from_response(
    method: &str,
    response: WsResponse,
) -> Result<TaskBoardCallOutcome, ToolError> {
    if let Some(error) = response.error {
        let message = format_ws_error(method, &error);
        return match error.code.as_str() {
            "INVALID_PARAMS" | "MISSING_PARAM" => Err(ToolError::invalid(message)),
            _ => Ok(TaskBoardCallOutcome::Refused(message)),
        };
    }

    Ok(TaskBoardCallOutcome::Result(
        response.result.unwrap_or(Value::Null),
    ))
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

#[cfg(test)]
#[path = "support_tests.rs"]
mod validation_tests;
