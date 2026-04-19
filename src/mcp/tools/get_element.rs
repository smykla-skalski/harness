use std::sync::Arc;

use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::mcp::protocol::ToolResult;
use crate::mcp::registry::{GetElementResult, RegistryClient, RegistryRequest};
use crate::mcp::tool::{Tool, ToolError};

use super::shared::{decode_params, map_registry_error, ok_text};

#[derive(Debug, Deserialize)]
struct Params {
    identifier: String,
}

pub struct GetElementTool {
    client: Arc<RegistryClient>,
}

impl GetElementTool {
    #[must_use]
    pub const fn new(client: Arc<RegistryClient>) -> Self {
        Self { client }
    }
}

#[async_trait]
impl Tool for GetElementTool {
    fn name(&self) -> &'static str {
        "get_element"
    }

    fn description(&self) -> &'static str {
        "Get the full metadata for a registered element by its \
         accessibility identifier."
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "identifier": {
                    "type": "string",
                    "description": "The .accessibilityIdentifier value.",
                    "minLength": 1,
                },
            },
            "required": ["identifier"],
            "additionalProperties": false,
        })
    }

    async fn call(&self, params: Value) -> Result<ToolResult, ToolError> {
        let parsed: Params = decode_params(params)?;
        if parsed.identifier.is_empty() {
            return Err(ToolError::invalid("identifier cannot be empty"));
        }
        let id = self.client.next_request_id();
        let request = RegistryRequest::GetElement {
            id,
            identifier: parsed.identifier,
        };
        let result: GetElementResult = self
            .client
            .request(&request)
            .await
            .map_err(|error| map_registry_error(&error))?;
        ok_text(&result)
    }
}
