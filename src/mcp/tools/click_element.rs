use std::sync::Arc;

use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::mcp::automation::{AutomationError, MouseButton, click};
use crate::mcp::protocol::ToolResult;
use crate::mcp::registry::{GetElementResult, Rect, RegistryClient, RegistryRequest};
use crate::mcp::tool::{Tool, ToolError};

use super::shared::{decode_params, map_registry_error};

#[derive(Debug, Deserialize)]
struct Params {
    identifier: String,
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

pub struct ClickElementTool {
    client: Arc<RegistryClient>,
}

impl ClickElementTool {
    #[must_use]
    pub const fn new(client: Arc<RegistryClient>) -> Self {
        Self { client }
    }
}

#[async_trait]
impl Tool for ClickElementTool {
    fn name(&self) -> &'static str {
        "click_element"
    }

    fn description(&self) -> &'static str {
        "Resolve an accessibility identifier to an element and click its \
         center in global coordinates."
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "identifier": {"type": "string"},
                "button": {"type": "string", "enum": ["left", "right", "middle"]},
                "doubleClick": {"type": "boolean"},
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
        let element = self.fetch_element(&parsed.identifier).await?;
        let (cx, cy) = center(&element.element.frame);
        let button = parsed.button.map_or(MouseButton::Left, MouseButton::from);
        click(cx, cy, button, parsed.double_click)
            .await
            .map_err(|error| map_click_error(&error))?;
        let payload = json!({"clicked": {"x": cx, "y": cy}});
        Ok(ToolResult::text(payload.to_string()))
    }
}

impl ClickElementTool {
    async fn fetch_element(&self, identifier: &str) -> Result<GetElementResult, ToolError> {
        let id = self.client.next_request_id();
        let request = RegistryRequest::GetElement {
            id,
            identifier: identifier.to_string(),
        };
        self.client
            .request(&request)
            .await
            .map_err(|error| map_registry_error(&error))
    }
}

fn center(frame: &Rect) -> (f64, f64) {
    (frame.x + frame.width / 2.0, frame.y + frame.height / 2.0)
}

fn map_click_error(error: &AutomationError) -> ToolError {
    match error {
        AutomationError::UnsupportedButton => ToolError::invalid(error.to_string()),
        _ => ToolError::internal(error.to_string()),
    }
}
