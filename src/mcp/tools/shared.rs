use serde::de::DeserializeOwned;
use serde::Serialize;
use serde_json::Value;

use crate::mcp::protocol::ToolResult;
use crate::mcp::registry::RegistryError;
use crate::mcp::tool::ToolError;

/// Decode JSON params, mapping errors to `ToolError::InvalidParams` so the
/// dispatcher returns the JSON-RPC `InvalidParams` code.
///
/// # Errors
/// Returns `ToolError::InvalidParams` when `params` does not match `T`.
pub fn decode_params<T: DeserializeOwned>(params: Value) -> Result<T, ToolError> {
    serde_json::from_value(params).map_err(|error| ToolError::invalid(error.to_string()))
}

/// Turn a successful JSON payload into a pretty-printed text `ToolResult`.
///
/// # Errors
/// Returns `ToolError::internal` when the payload cannot be serialized (a
/// serde-internal failure).
pub fn ok_text<T: Serialize>(payload: &T) -> Result<ToolResult, ToolError> {
    ToolResult::json_text(payload).map_err(|error| ToolError::internal(error.to_string()))
}

/// Map a `RegistryError` into the tool-level `ToolError`. Unavailable and
/// server errors surface as `ToolError::Internal` so the LLM sees them in
/// the tool result with `isError: true`; protocol errors become
/// `InvalidParams` so the client retries with adjusted input.
#[must_use]
pub fn map_registry_error(error: &RegistryError) -> ToolError {
    match error {
        RegistryError::Unavailable { .. }
        | RegistryError::Server { .. }
        | RegistryError::Timeout { .. }
        | RegistryError::Closed { .. } => ToolError::internal(error.to_string()),
        RegistryError::Protocol { .. } => ToolError::invalid(error.to_string()),
    }
}
