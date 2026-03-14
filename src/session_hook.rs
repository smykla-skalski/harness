use serde::{Deserialize, Serialize};

/// Input payload for the session-start hook.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionStartHookInput {
    pub source: String,
    pub session_id: String,
    #[serde(default)]
    pub transcript_path: Option<String>,
    pub cwd: String,
    #[serde(default)]
    pub raw_keys: Vec<String>,
}

/// Input payload for the pre-compact hook.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PreCompactHookInput {
    pub trigger: String,
    #[serde(default)]
    pub custom_instructions: Option<String>,
    pub session_id: String,
    #[serde(default)]
    pub transcript_path: Option<String>,
    pub cwd: String,
    #[serde(default)]
    pub raw_keys: Vec<String>,
}

/// Output payload for the session-start hook.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionStartHookOutput {
    pub hook_specific_output: SessionStartHookSpecificOutput,
}

/// Hook-specific output.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionStartHookSpecificOutput {
    pub hook_event_name: String,
    pub additional_context: String,
}

impl SessionStartHookOutput {
    /// Build from additional context.
    #[must_use]
    pub fn from_additional_context(additional_context: &str) -> Self {
        Self {
            hook_specific_output: SessionStartHookSpecificOutput {
                hook_event_name: "session_start".to_string(),
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

#[cfg(test)]
mod tests {}
