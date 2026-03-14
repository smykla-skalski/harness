use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

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
pub fn resolve_cwd(payload_cwd: &str, project_dir: &Path) -> PathBuf {
    if !payload_cwd.is_empty() {
        return PathBuf::from(payload_cwd);
    }
    project_dir.to_path_buf()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_start_output_from_additional_context() {
        let output = SessionStartHookOutput::from_additional_context("hello world");
        assert_eq!(output.hook_specific_output.hook_event_name, "SessionStart");
        assert_eq!(
            output.hook_specific_output.additional_context,
            "hello world"
        );
    }

    #[test]
    fn session_start_output_to_json_has_camel_case_keys() {
        let output = SessionStartHookOutput::from_additional_context("ctx");
        let json = output.to_json().unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(
            parsed["hookSpecificOutput"]["hookEventName"],
            "SessionStart"
        );
        assert_eq!(parsed["hookSpecificOutput"]["additionalContext"], "ctx");
    }

    #[test]
    fn session_start_output_roundtrips_json() {
        let output = SessionStartHookOutput::from_additional_context("round trip");
        let json = output.to_json().unwrap();
        let parsed: SessionStartHookOutput = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, output);
    }

    #[test]
    fn session_start_input_deserializes_from_json() {
        let json = r#"{"source":"compact","session_id":"abc","cwd":"/tmp"}"#;
        let input: SessionStartHookInput = serde_json::from_str(json).unwrap();
        assert_eq!(input.source, "compact");
        assert_eq!(input.session_id, "abc");
        assert_eq!(input.cwd, "/tmp");
        assert!(input.raw_keys.is_empty());
    }

    #[test]
    fn session_start_input_defaults_missing_fields() {
        let input: SessionStartHookInput = serde_json::from_str("{}").unwrap();
        assert!(input.source.is_empty());
        assert!(input.session_id.is_empty());
        assert!(input.cwd.is_empty());
        assert!(input.transcript_path.is_none());
    }

    #[test]
    fn pre_compact_input_deserializes_from_json() {
        let json = r#"{"trigger":"manual","session_id":"s1","cwd":"/repo"}"#;
        let input: PreCompactHookInput = serde_json::from_str(json).unwrap();
        assert_eq!(input.trigger, "manual");
        assert_eq!(input.session_id, "s1");
        assert!(input.custom_instructions.is_none());
    }

    #[test]
    fn resolve_cwd_uses_payload_when_present() {
        let result = resolve_cwd("/from/payload", Path::new("/fallback"));
        assert_eq!(result, PathBuf::from("/from/payload"));
    }

    #[test]
    fn resolve_cwd_falls_back_to_project_dir() {
        let result = resolve_cwd("", Path::new("/project"));
        assert_eq!(result, PathBuf::from("/project"));
    }
}
