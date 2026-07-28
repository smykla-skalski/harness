use serde::{Deserialize, Serialize};
use serde_json::Value;

/// JSON-RPC 2.0 standard error codes plus MCP-specific ones.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorCode {
    ParseError,
    InvalidRequest,
    MethodNotFound,
    InvalidParams,
    InternalError,
    Custom(i32),
}

impl From<ErrorCode> for i32 {
    fn from(code: ErrorCode) -> Self {
        match code {
            ErrorCode::ParseError => -32700,
            ErrorCode::InvalidRequest => -32600,
            ErrorCode::MethodNotFound => -32601,
            ErrorCode::InvalidParams => -32602,
            ErrorCode::InternalError => -32603,
            ErrorCode::Custom(code) => code,
        }
    }
}

/// JSON-RPC error object sent inside an error response.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ErrorObject {
    pub code: i32,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

impl ErrorObject {
    #[must_use]
    pub fn new(code: ErrorCode, message: String) -> Self {
        Self {
            code: code.into(),
            message,
            data: None,
        }
    }

    #[must_use]
    pub fn with_data(code: ErrorCode, message: String, data: Value) -> Self {
        Self {
            code: code.into(),
            message,
            data: Some(data),
        }
    }
}
