use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::mcp::automation::{AutomationError, MouseButton, click};
use crate::mcp::protocol::ToolResult;
use crate::mcp::tool::{Tool, ToolError};

use super::shared::decode_params;

#[derive(Debug, Deserialize)]
struct Params {
    x: f64,
    y: f64,
    #[serde(default)]
    button: Option<ButtonArg>,
    #[serde(rename = "doubleClick", default)]
    double_click: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "lowercase")]
enum ButtonArg {
    Left,
    Right,
    Middle,
}

impl From<ButtonArg> for MouseButton {
    fn from(arg: ButtonArg) -> Self {
        match arg {
            ButtonArg::Left => Self::Left,
            ButtonArg::Right => Self::Right,
            ButtonArg::Middle => Self::Middle,
        }
    }
}

pub struct ClickTool;

#[async_trait]
impl Tool for ClickTool {
    fn name(&self) -> &'static str {
        "click"
    }

    fn description(&self) -> &'static str {
        "Perform a mouse click at global screen coordinates. Supports \
         left/right buttons and double click."
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "x": {"type": "number"},
                "y": {"type": "number"},
                "button": {"type": "string", "enum": ["left", "right", "middle"]},
                "doubleClick": {"type": "boolean"},
            },
            "required": ["x", "y"],
            "additionalProperties": false,
        })
    }

    async fn call(&self, params: Value) -> Result<ToolResult, ToolError> {
        let parsed: Params = decode_params(params)?;
        let button = parsed.button.map_or(MouseButton::Left, MouseButton::from);
        match click(parsed.x, parsed.y, button, parsed.double_click).await {
            Ok(()) => Ok(ToolResult::text("ok")),
            Err(error) => Err(map_click_error(&error)),
        }
    }
}

fn map_click_error(error: &AutomationError) -> ToolError {
    match error {
        AutomationError::UnsupportedButton => ToolError::invalid(error.to_string()),
        _ => ToolError::internal(error.to_string()),
    }
}
