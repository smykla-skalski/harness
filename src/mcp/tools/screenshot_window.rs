use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::mcp::automation::{AutomationError, ScreenshotOptions, screenshot};
use crate::mcp::protocol::ToolResult;
use crate::mcp::tool::{Tool, ToolError};

use super::shared::decode_params;

#[derive(Debug, Deserialize)]
struct Params {
    #[serde(rename = "windowID", default)]
    window_id: Option<u32>,
    #[serde(rename = "displayID", default)]
    display_id: Option<u32>,
    #[serde(rename = "includeCursor", default)]
    include_cursor: bool,
}

pub struct ScreenshotWindowTool;

#[async_trait]
impl Tool for ScreenshotWindowTool {
    fn name(&self) -> &'static str {
        "screenshot_window"
    }

    fn description(&self) -> &'static str {
        "Capture a PNG screenshot. If windowID is provided, capture that \
         window; otherwise the display. Returns a base64-encoded image \
         content block."
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "windowID": {"type": "integer"},
                "displayID": {"type": "integer"},
                "includeCursor": {"type": "boolean"},
            },
            "additionalProperties": false,
        })
    }

    async fn call(&self, params: Value) -> Result<ToolResult, ToolError> {
        let parsed: Params = decode_params(params)?;
        let options = ScreenshotOptions {
            window_id: parsed.window_id,
            display_id: parsed.display_id,
            include_cursor: parsed.include_cursor,
        };
        match screenshot(&options).await {
            Ok(bytes) => Ok(ToolResult::image(bytes, "image/png")),
            Err(error) => Err(map_automation_error(&error)),
        }
    }
}

fn map_automation_error(error: &AutomationError) -> ToolError {
    ToolError::internal(error.to_string())
}
