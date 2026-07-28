use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde::{Deserialize, Serialize};

/// A single MCP content block in a tool result. MCP supports text, image,
/// and resource blocks. We model the subset we emit here.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum ContentBlock {
    Text {
        text: String,
    },
    Image {
        data: String,
        #[serde(rename = "mimeType")]
        mime_type: String,
    },
}

impl ContentBlock {
    #[must_use]
    pub fn text(text: impl Into<String>) -> Self {
        Self::Text { text: text.into() }
    }

    #[must_use]
    pub fn image(bytes: Vec<u8>, mime_type: impl Into<String>) -> Self {
        Self::Image {
            data: STANDARD.encode(bytes),
            mime_type: mime_type.into(),
        }
    }
}

/// Payload returned from a `tools/call` request. Mirrors the MCP spec's
/// `CallToolResult` shape: a non-empty content array plus an optional
/// `isError` flag that signals tool-level failure (distinct from protocol
/// errors, which are JSON-RPC responses).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolResult {
    pub content: Vec<ContentBlock>,
    #[serde(rename = "isError", default)]
    pub is_error: bool,
}

impl ToolResult {
    #[must_use]
    pub fn text(text: impl Into<String>) -> Self {
        Self {
            content: vec![ContentBlock::text(text)],
            is_error: false,
        }
    }

    #[must_use]
    pub fn error(text: impl Into<String>) -> Self {
        Self {
            content: vec![ContentBlock::text(text)],
            is_error: true,
        }
    }

    #[must_use]
    pub fn image(bytes: Vec<u8>, mime_type: impl Into<String>) -> Self {
        Self {
            content: vec![ContentBlock::image(bytes, mime_type)],
            is_error: false,
        }
    }

    /// Build a text result containing a pretty-printed JSON encoding of
    /// `value`.
    ///
    /// # Errors
    /// Returns the underlying `serde_json::Error` if `value` cannot be
    /// serialized.
    pub fn json_text<T: Serialize>(value: &T) -> Result<Self, serde_json::Error> {
        let text = serde_json::to_string_pretty(value)?;
        Ok(Self::text(text))
    }
}
