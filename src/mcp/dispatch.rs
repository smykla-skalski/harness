//! Dispatcher: implements `RequestHandler` by routing MCP methods to the
//! handshake flow or the tool registry.

use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Value, json};
use tracing::debug;

use crate::mcp::handshake::InitializeResult;
use crate::mcp::protocol::{
    ErrorCode, ErrorObject, Notification, Request, RequestId, Response, ToolResult,
};
use crate::mcp::server::RequestHandler;
use crate::mcp::tool::{ToolError, ToolRegistry};

/// Dispatcher binds a tool registry to the MCP methods: `initialize`,
/// `tools/list`, `tools/call`. Unknown methods return `MethodNotFound`.
pub struct Dispatcher {
    registry: ToolRegistry,
}

impl Dispatcher {
    #[must_use]
    pub fn new(registry: ToolRegistry) -> Self {
        Self { registry }
    }
}

#[async_trait]
impl RequestHandler for Dispatcher {
    async fn handle_request(&self, request: Request) -> Response {
        match request.method.as_str() {
            "initialize" => handle_initialize(request),
            "tools/list" => handle_tools_list(&self.registry, request),
            "tools/call" => handle_tools_call(&self.registry, request).await,
            _ => method_not_found(request),
        }
    }

    async fn handle_notification(&self, notification: Notification) {
        debug!(method = %notification.method, "MCP notification");
    }
}

fn handle_initialize(request: Request) -> Response {
    let result = InitializeResult::default_with_tools();
    match serde_json::to_value(&result) {
        Ok(value) => Response::success(request.id, value),
        Err(error) => internal_error(request.id, &error.to_string()),
    }
}

fn handle_tools_list(registry: &ToolRegistry, request: Request) -> Response {
    let metadata = registry.metadata();
    Response::success(request.id, json!({ "tools": metadata }))
}

#[derive(Deserialize)]
struct ToolsCallParams {
    name: String,
    #[serde(default)]
    arguments: Value,
}

async fn handle_tools_call(registry: &ToolRegistry, request: Request) -> Response {
    let params: ToolsCallParams = match serde_json::from_value(request.params.clone()) {
        Ok(params) => params,
        Err(error) => return invalid_params(request.id, &error.to_string()),
    };
    let Some(tool) = registry.get(&params.name) else {
        return tool_not_found(request.id, &params.name);
    };
    match tool.call(params.arguments).await {
        Ok(result) => wrap_tool_result(request.id, &result),
        Err(ToolError::InvalidParams(message)) => invalid_params(request.id, &message),
        Err(ToolError::Internal(message)) => {
            let result = ToolResult::error(message);
            wrap_tool_result(request.id, &result)
        }
    }
}

fn wrap_tool_result(id: RequestId, result: &ToolResult) -> Response {
    match serde_json::to_value(result) {
        Ok(value) => Response::success(id, value),
        Err(error) => internal_error(id, &error.to_string()),
    }
}

fn invalid_params(id: RequestId, message: &str) -> Response {
    Response::error(
        id,
        ErrorObject::new(ErrorCode::InvalidParams, message.to_string()),
    )
}

fn internal_error(id: RequestId, message: &str) -> Response {
    Response::error(
        id,
        ErrorObject::new(ErrorCode::InternalError, message.to_string()),
    )
}

fn method_not_found(request: Request) -> Response {
    let message = format!("unknown method: {}", request.method);
    Response::error(
        request.id,
        ErrorObject::new(ErrorCode::MethodNotFound, message),
    )
}

fn tool_not_found(id: RequestId, name: &str) -> Response {
    Response::error(
        id,
        ErrorObject::new(ErrorCode::InvalidParams, format!("unknown tool: {name}")),
    )
}
