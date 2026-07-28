use serde::de::Error as _;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::error::ErrorObject;

/// JSON-RPC 2.0 request identifier. MCP uses numeric or string ids.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum RequestId {
    Number(i64),
    String(String),
}

/// Marker for the JSON-RPC 2.0 version field. Serializes as the literal
/// `"2.0"` string and rejects any other value on parse.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct JsonRpcVersion;

impl Serialize for JsonRpcVersion {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str("2.0")
    }
}

impl<'de> Deserialize<'de> for JsonRpcVersion {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let tag = String::deserialize(deserializer)?;
        if tag == "2.0" {
            Ok(Self)
        } else {
            Err(D::Error::custom(format!(
                "expected jsonrpc=\"2.0\", got {tag:?}"
            )))
        }
    }
}

/// Incoming MCP request message.
#[derive(Debug, Clone, Deserialize)]
pub struct Request {
    #[serde(rename = "jsonrpc")]
    pub version: JsonRpcVersion,
    pub id: RequestId,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

/// Incoming MCP notification. Notifications carry no `id` and expect no
/// response.
#[derive(Debug, Clone, Deserialize)]
pub struct Notification {
    #[serde(rename = "jsonrpc")]
    pub version: JsonRpcVersion,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

/// Outgoing response. Either `result` or `error` is set; never both.
#[derive(Debug, Clone, Serialize)]
pub struct Response {
    #[serde(rename = "jsonrpc")]
    pub version: JsonRpcVersion,
    pub id: RequestId,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ErrorObject>,
}

impl Response {
    #[must_use]
    pub fn success(id: RequestId, result: Value) -> Self {
        Self {
            version: JsonRpcVersion,
            id,
            result: Some(result),
            error: None,
        }
    }

    #[must_use]
    pub fn error(id: RequestId, error: ErrorObject) -> Self {
        Self {
            version: JsonRpcVersion,
            id,
            result: None,
            error: Some(error),
        }
    }
}
