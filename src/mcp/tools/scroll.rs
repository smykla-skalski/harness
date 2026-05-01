use std::sync::Arc;

use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::mcp::automation::scroll;
use crate::mcp::protocol::ToolResult;
use crate::mcp::registry::{GetElementResult, Rect, RegistryClient};
use crate::mcp::tool::{Tool, ToolError};

use super::shared::{decode_params, resolve_get_element};

#[derive(Debug, Deserialize)]
struct Params {
    identifier: String,
    #[serde(rename = "deltaX", default)]
    delta_x: f64,
    #[serde(rename = "deltaY")]
    delta_y: f64,
}

pub struct ScrollTool {
    client: Arc<RegistryClient>,
}

impl ScrollTool {
    #[must_use]
    pub const fn new(client: Arc<RegistryClient>) -> Self {
        Self { client }
    }

    async fn fetch_element(&self, identifier: &str) -> Result<GetElementResult, ToolError> {
        resolve_get_element(&self.client, identifier).await
    }
}

#[async_trait]
impl Tool for ScrollTool {
    fn name(&self) -> &'static str {
        "scroll"
    }

    fn description(&self) -> &'static str {
        "Scroll a registered accessibility target by identifier. Positive \
         deltaY scrolls down; negative deltaY scrolls up."
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "identifier": {"type": "string"},
                "deltaX": {"type": "number"},
                "deltaY": {"type": "number"},
            },
            "required": ["identifier", "deltaY"],
            "additionalProperties": false,
        })
    }

    async fn call(&self, params: Value) -> Result<ToolResult, ToolError> {
        let parsed: Params = decode_params(params)?;
        if parsed.identifier.is_empty() {
            return Err(ToolError::invalid("identifier cannot be empty"));
        }
        let element = self.fetch_element(&parsed.identifier).await?;
        if !element.element.enabled {
            return Err(ToolError::invalid(format!(
                "identifier '{}' resolves to a disabled target",
                parsed.identifier
            )));
        }
        let (cx, cy) = center(&element.element.frame);
        scroll(cx, cy, parsed.delta_x, parsed.delta_y)
            .await
            .map_err(|error| ToolError::internal(error.to_string()))?;
        let payload = json!({
            "scrolled": {
                "identifier": parsed.identifier,
                "x": cx,
                "y": cy,
                "deltaX": parsed.delta_x,
                "deltaY": parsed.delta_y,
            }
        });
        Ok(ToolResult::text(payload.to_string()))
    }
}

fn center(frame: &Rect) -> (f64, f64) {
    (frame.x + frame.width / 2.0, frame.y + frame.height / 2.0)
}
