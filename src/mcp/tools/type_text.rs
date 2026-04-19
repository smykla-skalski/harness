use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::mcp::automation::{AutomationError, type_text};
use crate::mcp::protocol::ToolResult;
use crate::mcp::tool::{Tool, ToolError};

use super::shared::decode_params;

#[derive(Debug, Deserialize)]
struct Params {
    text: String,
}

pub struct TypeTextTool;

#[async_trait]
impl Tool for TypeTextTool {
    fn name(&self) -> &'static str {
        "type_text"
    }

    fn description(&self) -> &'static str {
        "Type the given text into whatever window currently has keyboard \
         focus. Unicode-safe."
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {"text": {"type": "string"}},
            "required": ["text"],
            "additionalProperties": false,
        })
    }

    async fn call(&self, params: Value) -> Result<ToolResult, ToolError> {
        let parsed: Params = decode_params(params)?;
        match type_text(&parsed.text).await {
            Ok(()) => Ok(ToolResult::text("ok")),
            Err(error) => Err(map_automation_error(&error)),
        }
    }
}

fn map_automation_error(error: &AutomationError) -> ToolError {
    ToolError::internal(error.to_string())
}
