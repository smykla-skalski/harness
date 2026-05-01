use std::sync::Arc;

use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::mcp::protocol::ToolResult;
use crate::mcp::registry::{ElementKind, RegistryClient};
use crate::mcp::tool::{Tool, ToolError};

use super::shared::{decode_params, ok_text, resolve_list_elements};

#[derive(Debug, Deserialize)]
struct Params {
    #[serde(rename = "windowID", default)]
    window_id: Option<i64>,
    #[serde(default)]
    kind: Option<ElementKind>,
}

pub struct ListElementsTool {
    client: Arc<RegistryClient>,
}

impl ListElementsTool {
    #[must_use]
    pub const fn new(client: Arc<RegistryClient>) -> Self {
        Self { client }
    }
}

#[async_trait]
impl Tool for ListElementsTool {
    fn name(&self) -> &'static str {
        "list_elements"
    }

    fn description(&self) -> &'static str {
        "List interactive elements registered by Harness Monitor. Filter \
         by window id or element kind."
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "windowID": {
                    "type": "integer",
                    "description": "Only return elements in this window.",
                },
                "kind": {
                    "type": "string",
                    "enum": [
                        "button", "toggle", "textField", "text", "link",
                        "list", "row", "tab", "menuItem", "image", "other",
                    ],
                    "description": "Filter by element kind.",
                },
            },
            "additionalProperties": false,
        })
    }

    async fn call(&self, params: Value) -> Result<ToolResult, ToolError> {
        let parsed: Params = decode_params(params)?;
        let result = resolve_list_elements(&self.client, parsed.window_id, parsed.kind).await?;
        ok_text(&result)
    }
}
