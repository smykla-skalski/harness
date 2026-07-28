use std::future::Future;
use std::sync::Arc;

use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::mcp::automation::{AutomationError, scroll};
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

    pub(crate) async fn call_with_dependencies<R, RFut, S, SFut>(
        &self,
        params: Value,
        resolve_element: R,
        perform_scroll: S,
    ) -> Result<ToolResult, ToolError>
    where
        R: FnOnce(String) -> RFut,
        RFut: Future<Output = Result<GetElementResult, ToolError>>,
        S: FnOnce(f64, f64, f64, f64) -> SFut,
        SFut: Future<Output = Result<(), AutomationError>>,
    {
        let parsed: Params = decode_params(params)?;
        if parsed.identifier.is_empty() {
            return Err(ToolError::invalid("identifier cannot be empty"));
        }
        let element = resolve_element(parsed.identifier.clone()).await?;
        if !element.element.enabled {
            return Err(ToolError::invalid(format!(
                "identifier '{}' resolves to a disabled target",
                parsed.identifier
            )));
        }
        let (cx, cy) = center(&element.element.frame);
        perform_scroll(cx, cy, parsed.delta_x, parsed.delta_y)
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
        self.call_with_dependencies(
            params,
            |identifier| async move { self.fetch_element(&identifier).await },
            |x, y, delta_x, delta_y| async move { scroll(x, y, delta_x, delta_y).await },
        )
        .await
    }
}

fn center(frame: &Rect) -> (f64, f64) {
    (frame.x + frame.width / 2.0, frame.y + frame.height / 2.0)
}
