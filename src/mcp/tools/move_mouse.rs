use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::mcp::automation::{AutomationError, move_mouse};
use crate::mcp::protocol::ToolResult;
use crate::mcp::tool::{Tool, ToolError};

use super::shared::decode_params;

#[derive(Debug, Deserialize)]
struct Params {
    x: f64,
    y: f64,
}

pub struct MoveMouseTool;

#[async_trait]
impl Tool for MoveMouseTool {
    fn name(&self) -> &'static str {
        "move_mouse"
    }

    fn description(&self) -> &'static str {
        "Move the mouse cursor to global screen coordinates (origin at \
         top-left). No click is performed."
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "x": {"type": "number"},
                "y": {"type": "number"},
            },
            "required": ["x", "y"],
            "additionalProperties": false,
        })
    }

    async fn call(&self, params: Value) -> Result<ToolResult, ToolError> {
        let parsed: Params = decode_params(params)?;
        match move_mouse(parsed.x, parsed.y).await {
            Ok(()) => Ok(ToolResult::text("ok")),
            Err(error) => Err(map_automation_error(&error)),
        }
    }
}

fn map_automation_error(error: &AutomationError) -> ToolError {
    ToolError::internal(error.to_string())
}
