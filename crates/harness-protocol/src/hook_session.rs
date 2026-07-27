use serde::{Deserialize, Serialize};

/// Output payload for the session-start hook.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionStartHookOutput {
    pub hook_specific_output: SessionStartHookSpecificOutput,
}

/// Hook-specific output fields.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionStartHookSpecificOutput {
    pub hook_event_name: String,
    pub additional_context: String,
}

impl SessionStartHookOutput {
    /// Build from additional context text.
    #[must_use]
    pub fn from_additional_context(additional_context: &str) -> Self {
        Self {
            hook_specific_output: SessionStartHookSpecificOutput {
                hook_event_name: "SessionStart".to_string(),
                additional_context: additional_context.to_string(),
            },
        }
    }

    /// Serialize to JSON string.
    ///
    /// # Errors
    /// Returns an error on serialization failure.
    pub fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string(self)
    }
}
