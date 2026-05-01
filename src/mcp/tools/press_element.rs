use std::sync::Arc;

use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::mcp::automation::{
    AccessibilityAction, AccessibilityActionError, perform_accessibility_action,
};
use crate::mcp::protocol::ToolResult;
use crate::mcp::registry::{
    GetElementResult, RegistryClient, RegistryError, RegistrySemanticAction,
};
use crate::mcp::tool::{Tool, ToolError};

use super::shared::{decode_params, ok_text, resolve_get_element};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RegistryPressDisposition {
    Pressed,
    FallbackToAccessibility,
    TargetGone,
    ActionUnavailable,
}

#[derive(Debug, Deserialize)]
struct Params {
    identifier: String,
}

pub struct PressElementTool {
    client: Arc<RegistryClient>,
}

impl PressElementTool {
    #[must_use]
    pub const fn new(client: Arc<RegistryClient>) -> Self {
        Self { client }
    }

    async fn fetch_element(&self, identifier: &str) -> Result<GetElementResult, ToolError> {
        resolve_get_element(&self.client, identifier).await
    }

    async fn perform_registry_press(
        &self,
        identifier: &str,
    ) -> Result<RegistryPressDisposition, ToolError> {
        match self
            .client
            .perform_action(identifier, RegistrySemanticAction::Press)
            .await
        {
            Ok(()) => Ok(RegistryPressDisposition::Pressed),
            Err(error) if registry_press_should_fallback(&error) => {
                Ok(RegistryPressDisposition::FallbackToAccessibility)
            }
            Err(RegistryError::Server { code, .. }) if code == "not-found" => {
                Ok(RegistryPressDisposition::TargetGone)
            }
            Err(RegistryError::Server { code, .. }) if code == "action-unavailable" => {
                Ok(RegistryPressDisposition::ActionUnavailable)
            }
            Err(error) => Err(ToolError::internal(error.to_string())),
        }
    }
}

#[async_trait]
impl Tool for PressElementTool {
    fn name(&self) -> &'static str {
        "press_element"
    }

    fn description(&self) -> &'static str {
        "Invoke an element's semantic accessibility activation without moving \
         the mouse or requiring the app to be frontmost."
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "identifier": {"type": "string"},
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
        if !element.element.enabled {
            return Err(ToolError::invalid(format!(
                "identifier '{}' resolves to a disabled target",
                parsed.identifier
            )));
        }

        if element
            .element
            .supports_action(RegistrySemanticAction::Press)
        {
            match self.perform_registry_press(&parsed.identifier).await? {
                RegistryPressDisposition::Pressed => {
                    return ok_text(&json!({
                        "pressed": {
                            "identifier": parsed.identifier,
                        }
                    }));
                }
                RegistryPressDisposition::TargetGone => {
                    return Ok(ToolResult::error(format!(
                        "identifier '{}' resolved in the registry, but the live accessibility element \
                         disappeared before the semantic press could run",
                        parsed.identifier
                    )));
                }
                RegistryPressDisposition::ActionUnavailable => {
                    return Ok(ToolResult::error(format!(
                        "identifier '{}' resolves to a live element without a supported semantic \
                         press action",
                        parsed.identifier
                    )));
                }
                RegistryPressDisposition::FallbackToAccessibility => {}
            }
        }

        match perform_accessibility_action(
            &parsed.identifier,
            element.element.window_id,
            AccessibilityAction::Press,
        )
        .await
        {
            Ok(()) => ok_text(&json!({
                "pressed": {
                    "identifier": parsed.identifier,
                }
            })),
            Err(AccessibilityActionError::NotFound) => Ok(ToolResult::error(format!(
                "identifier '{}' resolved in the registry, but the live accessibility element \
                 disappeared before the semantic press could run",
                parsed.identifier
            ))),
            Err(AccessibilityActionError::ActionUnavailable) => Ok(ToolResult::error(format!(
                "identifier '{}' resolves to a live element without a supported semantic press \
                 action",
                parsed.identifier
            ))),
            Err(error) => Err(ToolError::internal(error.to_string())),
        }
    }
}

fn registry_press_should_fallback(error: &RegistryError) -> bool {
    match error {
        RegistryError::Unavailable { .. }
        | RegistryError::Timeout { .. }
        | RegistryError::Protocol { .. }
        | RegistryError::Closed { .. } => true,
        RegistryError::Server { code, .. } => matches!(
            code.as_str(),
            "invalid-argument" | "not-implemented" | "unsupported-capability"
        ),
    }
}
