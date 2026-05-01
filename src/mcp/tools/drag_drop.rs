use std::sync::Arc;

use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::mcp::automation::drag_drop;
use crate::mcp::protocol::ToolResult;
use crate::mcp::registry::{GetElementResult, Rect, RegistryClient};
use crate::mcp::tool::{Tool, ToolError};

use super::shared::{decode_params, resolve_get_element};

const MAX_DURATION_MS: u64 = 60_000;

#[derive(Debug, Deserialize)]
struct Params {
    #[serde(rename = "sourceIdentifier")]
    source_identifier: String,
    #[serde(rename = "destinationIdentifier")]
    destination_identifier: String,
    #[serde(rename = "durationMs", default = "default_duration_ms")]
    duration_ms: u64,
}

const fn default_duration_ms() -> u64 {
    180
}

pub struct DragDropTool {
    client: Arc<RegistryClient>,
}

impl DragDropTool {
    #[must_use]
    pub const fn new(client: Arc<RegistryClient>) -> Self {
        Self { client }
    }

    async fn fetch_element(&self, identifier: &str) -> Result<GetElementResult, ToolError> {
        resolve_get_element(&self.client, identifier).await
    }
}

#[async_trait]
impl Tool for DragDropTool {
    fn name(&self) -> &'static str {
        "drag_drop"
    }

    fn description(&self) -> &'static str {
        "Drag from one registered accessibility target to another using their \
         identifiers."
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "sourceIdentifier": {"type": "string"},
                "destinationIdentifier": {"type": "string"},
                "durationMs": {"type": "integer", "minimum": 0, "maximum": MAX_DURATION_MS},
            },
            "required": ["sourceIdentifier", "destinationIdentifier"],
            "additionalProperties": false,
        })
    }

    async fn call(&self, params: Value) -> Result<ToolResult, ToolError> {
        let parsed: Params = decode_params(params)?;
        if parsed.source_identifier.is_empty() {
            return Err(ToolError::invalid("sourceIdentifier cannot be empty"));
        }
        if parsed.destination_identifier.is_empty() {
            return Err(ToolError::invalid("destinationIdentifier cannot be empty"));
        }
        if parsed.duration_ms > MAX_DURATION_MS {
            return Err(ToolError::invalid(format!(
                "durationMs must be <= {MAX_DURATION_MS}"
            )));
        }

        let source = self.fetch_element(&parsed.source_identifier).await?;
        let destination = self.fetch_element(&parsed.destination_identifier).await?;
        if !source.element.enabled {
            return Err(ToolError::invalid(format!(
                "sourceIdentifier '{}' resolves to a disabled target",
                parsed.source_identifier
            )));
        }
        if !destination.element.enabled {
            return Err(ToolError::invalid(format!(
                "destinationIdentifier '{}' resolves to a disabled target",
                parsed.destination_identifier
            )));
        }
        let (start_x, start_y) = center(&source.element.frame);
        let (end_x, end_y) = center(&destination.element.frame);
        drag_drop(start_x, start_y, end_x, end_y, parsed.duration_ms)
            .await
            .map_err(|error| ToolError::internal(error.to_string()))?;
        let payload = json!({
            "dragged": {
                "sourceIdentifier": parsed.source_identifier,
                "destinationIdentifier": parsed.destination_identifier,
                "start": {"x": start_x, "y": start_y},
                "end": {"x": end_x, "y": end_y},
                "durationMs": parsed.duration_ms,
            }
        });
        Ok(ToolResult::text(payload.to_string()))
    }
}

fn center(frame: &Rect) -> (f64, f64) {
    (frame.x + frame.width / 2.0, frame.y + frame.height / 2.0)
}
