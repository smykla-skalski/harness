use std::sync::Arc;

use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::mcp::protocol::ToolResult;
use crate::mcp::registry::RegistryClient;
use crate::mcp::tool::{Tool, ToolError};

use super::shared::{decode_params, ok_text, resolve_get_element};

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
        let result = resolve_get_element(&self.client, &parsed.identifier).await?;
        ok_text(&result)
    }
}
