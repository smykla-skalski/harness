use std::sync::Arc;

use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::mcp::protocol::ToolResult;
use crate::mcp::registry::{ElementKind, ListElementsResult, RegistryClient, RegistryRequest};
use crate::mcp::tool::{Tool, ToolError};

use super::shared::{decode_params, map_registry_error, ok_text};

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
        let id = self.client.next_request_id();
        let request = RegistryRequest::ListElements {
            id,
            window_id: parsed.window_id,
            kind: parsed.kind,
        };
        let result: ListElementsResult = self
            .client
            .request(&request)
            .await
            .map_err(|error| map_registry_error(&error))?;
        ok_text(&result)
    }
}
