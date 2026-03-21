use serde::{Deserialize, Serialize};

#[cfg(test)]
use std::path::{Path, PathBuf};

/// Input payload for the session-start hook.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionStartHookInput {
    #[serde(default)]
    pub source: String,
    #[serde(default)]
    pub session_id: String,
    #[serde(default)]
    pub transcript_path: Option<String>,
    #[serde(default)]
    pub cwd: String,
    #[serde(default)]
    pub raw_keys: Vec<String>,
}

/// Input payload for the pre-compact hook.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PreCompactHookInput {
    #[serde(default)]
    pub trigger: String,
    #[serde(default)]
    pub custom_instructions: Option<String>,
    #[serde(default)]
    pub session_id: String,
    #[serde(default)]
    pub transcript_path: Option<String>,
    #[serde(default)]
    pub cwd: String,
    #[serde(default)]
    pub raw_keys: Vec<String>,
}

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

/// Resolve the effective cwd from the hook payload or project dir fallback.
#[must_use]
#[cfg(test)]
pub fn resolve_cwd(payload_cwd: &str, project_dir: &Path) -> PathBuf {
    if !payload_cwd.is_empty() {
        return PathBuf::from(payload_cwd);
    }
    project_dir.to_path_buf()
}

#[cfg(test)]
#[path = "session/tests.rs"]
mod tests;
