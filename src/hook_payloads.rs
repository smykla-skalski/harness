use std::collections::HashMap;
use std::io;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::errors::CliError;

/// A write request from a hook envelope.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HookWriteRequest {
    pub file_path: String,
}

/// An option in an `AskUserQuestion` prompt.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AskUserQuestionOption {
    pub label: String,
    #[serde(default)]
    pub description: String,
}

/// An `AskUserQuestion` prompt with header, options, multi-select.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AskUserQuestionPrompt {
    pub question: String,
    #[serde(default)]
    pub header: Option<String>,
    #[serde(default)]
    pub options: Vec<AskUserQuestionOption>,
    #[serde(default)]
    pub multi_select: bool,
}

impl AskUserQuestionPrompt {
    /// Option labels as borrowed string slices.
    #[must_use]
    pub fn option_labels(&self) -> Vec<&str> {
        self.options.iter().map(|o| o.label.as_str()).collect()
    }

    /// First line of the question text.
    #[must_use]
    pub fn question_head(&self) -> &str {
        self.question
            .lines()
            .next()
            .unwrap_or(&self.question)
            .trim()
    }
}

/// Answer to an `AskUserQuestion`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AskUserAnswer {
    pub question: String,
    pub answer: String,
}

/// Annotation payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AskUserAnnotation {
    pub question: String,
    pub notes: String,
}

/// Hook message payload extracted from tool input.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HookMessagePayload {
    #[serde(default)]
    pub command: Option<String>,
    #[serde(default)]
    pub file_path: Option<String>,
    #[serde(default)]
    pub writes: Vec<HookWriteRequest>,
    #[serde(default)]
    pub questions: Vec<AskUserQuestionPrompt>,
    #[serde(default)]
    pub answers: Vec<AskUserAnswer>,
    #[serde(default)]
    pub annotations: Vec<AskUserAnnotation>,
}

/// The full hook envelope payload from Claude Code.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HookEnvelopePayload {
    #[serde(default)]
    pub root: Option<String>,
    #[serde(default)]
    pub input_payload: Option<HookMessagePayload>,
    #[serde(default)]
    pub tool_input: Option<serde_json::Value>,
    #[serde(default)]
    pub response: Option<serde_json::Value>,
    #[serde(default)]
    pub last_assistant_message: Option<String>,
    #[serde(default)]
    pub transcript_path: Option<String>,
    #[serde(default)]
    pub stop_hook_active: bool,
    #[serde(default)]
    pub raw_keys: Vec<String>,
}

impl HookEnvelopePayload {
    /// Parse from JSON text.
    ///
    /// # Errors
    /// Returns `CliError` if the text is not valid JSON or does not match the
    /// expected envelope shape.
    pub fn from_json_text(text: &str) -> Result<Self, CliError> {
        serde_json::from_str(text).map_err(|e| CliError {
            code: "KSH001".to_string(),
            message: format!("invalid hook payload: {e}"),
            exit_code: 1,
            hint: None,
            details: None,
        })
    }

    /// Parse from stdin.
    ///
    /// # Errors
    /// Returns `CliError` if stdin cannot be read or the payload is invalid.
    pub fn from_stdin() -> Result<Self, CliError> {
        use io::Read;
        let mut text = String::new();
        io::stdin()
            .read_to_string(&mut text)
            .map_err(|e| CliError {
                code: "KSH001".to_string(),
                message: format!("failed to read stdin: {e}"),
                exit_code: 1,
                hint: None,
                details: None,
            })?;
        Self::from_json_text(&text)
    }
}

/// High-level hook event wrapping the envelope.
#[derive(Debug, Clone)]
pub struct HookEvent {
    pub payload: HookEnvelopePayload,
}

impl HookEvent {
    /// Parse from stdin.
    ///
    /// # Errors
    /// Returns `CliError` if stdin cannot be read or the payload is invalid.
    pub fn from_stdin() -> Result<Self, CliError> {
        let payload = HookEnvelopePayload::from_stdin()?;
        Ok(Self { payload })
    }
}

/// Hook context combining event, run context, workflow state, and skill info.
#[derive(Debug)]
pub struct HookContext {
    pub skill: String,
    pub event: HookEvent,
    pub run_dir: Option<PathBuf>,
    pub skill_active: bool,
    pub active_skill: Option<String>,
    pub inactive_reason: Option<String>,
}

impl HookContext {
    /// Build hook context from stdin for a given skill.
    ///
    /// Reads the hook envelope from stdin and resolves run context and
    /// skill-active state. Skill-active detection is simplified here; full
    /// transcript-based detection requires the workflow module.
    ///
    /// # Errors
    /// Returns `CliError` if stdin cannot be read or the payload is invalid.
    pub fn from_stdin(skill: &str) -> Result<Self, CliError> {
        let event = HookEvent::from_stdin()?;
        Ok(Self {
            skill: skill.to_string(),
            event,
            run_dir: None,
            skill_active: true,
            active_skill: Some(skill.to_string()),
            inactive_reason: None,
        })
    }

    /// Build hook context from a pre-parsed envelope payload.
    ///
    /// Used when the envelope has already been read (e.g. from a test).
    #[must_use]
    pub fn from_envelope(skill: &str, payload: HookEnvelopePayload) -> Self {
        Self {
            skill: skill.to_string(),
            event: HookEvent { payload },
            run_dir: None,
            skill_active: true,
            active_skill: Some(skill.to_string()),
            inactive_reason: None,
        }
    }

    /// The raw command string from the input payload, if any.
    #[must_use]
    pub fn command_text(&self) -> Option<&str> {
        self.event
            .payload
            .input_payload
            .as_ref()
            .and_then(|p| p.command.as_deref())
    }

    /// Shell-split command words from the input payload.
    #[must_use]
    pub fn command_words(&self) -> Vec<String> {
        self.command_text().map_or_else(Vec::new, |cmd| {
            shell_words::split(cmd).unwrap_or_else(|e| {
                eprintln!(
                    "warning: shell_words::split failed ({e}), \
                     treating entire command as one word - \
                     per-word security checks may be bypassed"
                );
                vec![cmd.to_string()]
            })
        })
    }

    /// Write target paths from the input payload.
    // Improvement: return `Vec<&str>` to avoid cloning, but callers in
    // guard_write.rs and verify_write.rs pass `&[String]` downstream.
    #[must_use]
    pub fn write_paths(&self) -> Vec<String> {
        let mut paths = Vec::new();
        if let Some(p) = &self.event.payload.input_payload {
            if let Some(fp) = &p.file_path {
                paths.push(fp.clone());
            }
            for w in &p.writes {
                paths.push(w.file_path.clone());
            }
        }
        paths
    }

    /// `AskUserQuestion` prompts from the input payload.
    #[must_use]
    pub fn question_prompts(&self) -> &[AskUserQuestionPrompt] {
        self.event
            .payload
            .input_payload
            .as_ref()
            .map_or(&[], |p| &p.questions)
    }

    /// `AskUserQuestion` answers from the input payload.
    #[must_use]
    pub fn question_answers(&self) -> &[AskUserAnswer] {
        self.event
            .payload
            .input_payload
            .as_ref()
            .map_or(&[], |p| &p.answers)
    }

    /// Last assistant message from the envelope.
    #[must_use]
    pub fn last_assistant_message(&self) -> &str {
        self.event
            .payload
            .last_assistant_message
            .as_deref()
            .unwrap_or("")
    }

    /// Whether the stop hook is active in the envelope.
    #[must_use]
    pub fn stop_hook_active(&self) -> bool {
        self.event.payload.stop_hook_active
    }
}

/// Extra types used in hook payload extraction.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolTracking {
    #[serde(default)]
    pub tracked_tools: HashMap<String, u32>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn envelope_from_json_empty_object() {
        let envelope = HookEnvelopePayload::from_json_text("{}").unwrap();
        assert!(envelope.root.is_none());
        assert!(envelope.input_payload.is_none());
        assert!(envelope.tool_input.is_none());
        assert!(!envelope.stop_hook_active);
        assert!(envelope.raw_keys.is_empty());
    }

    #[test]
    fn envelope_from_json_with_command() {
        let json = r#"{"input_payload": {"command": "kubectl get pods"}}"#;
        let envelope = HookEnvelopePayload::from_json_text(json).unwrap();
        let payload = envelope.input_payload.unwrap();
        assert_eq!(payload.command.as_deref(), Some("kubectl get pods"));
    }

    #[test]
    fn envelope_from_json_with_writes() {
        let json = r#"{"input_payload": {"writes": [{"file_path": "/tmp/test.txt"}]}}"#;
        let envelope = HookEnvelopePayload::from_json_text(json).unwrap();
        let payload = envelope.input_payload.unwrap();
        assert_eq!(payload.writes.len(), 1);
        assert_eq!(payload.writes[0].file_path, "/tmp/test.txt");
    }

    #[test]
    fn envelope_from_json_with_questions() {
        let json = r#"{
            "input_payload": {
                "questions": [{
                    "question": "Install validator?",
                    "options": [
                        {"label": "Yes", "description": "Install it"},
                        {"label": "No", "description": "Skip"}
                    ]
                }]
            }
        }"#;
        let envelope = HookEnvelopePayload::from_json_text(json).unwrap();
        let payload = envelope.input_payload.unwrap();
        assert_eq!(payload.questions.len(), 1);
        let q = &payload.questions[0];
        assert_eq!(q.question, "Install validator?");
        assert_eq!(q.option_labels(), vec!["Yes", "No"]);
        assert_eq!(q.question_head(), "Install validator?");
    }

    #[test]
    fn envelope_from_json_invalid() {
        let result = HookEnvelopePayload::from_json_text("not json");
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert_eq!(err.code, "KSH001");
        assert!(err.message.contains("invalid hook payload"));
    }

    #[test]
    fn envelope_from_json_full_envelope() {
        let json = r#"{
            "root": "/workspace",
            "transcript_path": "/tmp/transcript.json",
            "stop_hook_active": true,
            "raw_keys": ["key1", "key2"]
        }"#;
        let envelope = HookEnvelopePayload::from_json_text(json).unwrap();
        assert_eq!(envelope.root.as_deref(), Some("/workspace"));
        assert_eq!(
            envelope.transcript_path.as_deref(),
            Some("/tmp/transcript.json")
        );
        assert!(envelope.stop_hook_active);
        assert_eq!(envelope.raw_keys, vec!["key1", "key2"]);
    }

    #[test]
    fn context_from_envelope_sets_skill() {
        let payload = HookEnvelopePayload::from_json_text("{}").unwrap();
        let ctx = HookContext::from_envelope("suite-runner", payload);
        assert_eq!(ctx.skill, "suite-runner");
        assert!(ctx.skill_active);
        assert_eq!(ctx.active_skill.as_deref(), Some("suite-runner"));
    }

    #[test]
    fn question_head_returns_first_line() {
        let prompt = AskUserQuestionPrompt {
            question: "First line\nSecond line\nThird".to_string(),
            header: None,
            options: vec![],
            multi_select: false,
        };
        assert_eq!(prompt.question_head(), "First line");
    }
}
