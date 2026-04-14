use std::path::{Path, PathBuf};

use harness::hooks::GuardContext;
use harness::hooks::hook_result::{Decision, HookResult};
use harness::hooks::payloads::{AskUserQuestionOption, AskUserQuestionPrompt, HookEnvelopePayload};
use harness::run::RunContext;
use harness::run::workflow as runner_workflow;

/// Builds `HookEnvelopePayload` for hook tests.
#[derive(Default)]
pub struct HookPayloadBuilder {
    tool_name: Option<String>,
    command: Option<String>,
    file_path: Option<PathBuf>,
    writes: Vec<PathBuf>,
    questions: Vec<AskUserQuestionPrompt>,
    tool_response: Option<serde_json::Value>,
    last_assistant_message: Option<String>,
    stop_hook_active: bool,
}

impl HookPayloadBuilder {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    #[must_use]
    pub fn command(mut self, command: &str) -> Self {
        self.tool_name = Some("Bash".to_string());
        self.command = Some(command.to_string());
        self
    }

    #[must_use]
    pub fn write_path(mut self, path: &str) -> Self {
        self.tool_name = Some("Write".to_string());
        self.file_path = Some(PathBuf::from(path));
        self
    }

    #[must_use]
    pub fn write_paths(mut self, paths: &[&str]) -> Self {
        self.tool_name = Some("Write".to_string());
        self.writes = paths.iter().map(|path| PathBuf::from(*path)).collect();
        self
    }

    #[must_use]
    pub fn question(mut self, question: &str, options: &[&str]) -> Self {
        self.tool_name = Some("AskUserQuestion".to_string());
        let prompt = AskUserQuestionPrompt {
            question: question.to_string(),
            header: Some("Approval".to_string()),
            options: options
                .iter()
                .map(|label| AskUserQuestionOption {
                    label: (*label).to_string(),
                    description: format!("Select {label}"),
                })
                .collect(),
            multi_select: false,
        };
        self.questions.push(prompt);
        self
    }

    /// Add a question with a pre-set answer to the payload.
    ///
    /// # Panics
    /// Panics if serialization of the question or answer fails.
    #[must_use]
    pub fn question_with_answer(mut self, question: &str, options: &[&str], answer: &str) -> Self {
        self.tool_name = Some("AskUserQuestion".to_string());
        let prompt = AskUserQuestionPrompt {
            question: question.to_string(),
            header: Some("Approval".to_string()),
            options: options
                .iter()
                .map(|label| AskUserQuestionOption {
                    label: (*label).to_string(),
                    description: format!("Select {label}"),
                })
                .collect(),
            multi_select: false,
        };
        self.tool_response = Some(serde_json::json!({
            "answers": [{"question": question, "answer": answer}],
        }));
        self.questions.push(prompt);
        self
    }

    #[must_use]
    pub fn stop_hook_active(mut self, active: bool) -> Self {
        self.stop_hook_active = active;
        self
    }

    #[must_use]
    pub fn last_assistant_message(mut self, message: &str) -> Self {
        self.last_assistant_message = Some(message.to_string());
        self
    }

    #[must_use]
    pub fn build_envelope(&self) -> HookEnvelopePayload {
        let tool_input = if let Some(command) = &self.command {
            serde_json::json!({ "command": command })
        } else if let Some(file_path) = &self.file_path {
            serde_json::json!({ "file_path": file_path })
        } else if !self.writes.is_empty() {
            let paths = self
                .writes
                .iter()
                .map(|path| path.to_string_lossy().into_owned())
                .collect::<Vec<_>>();
            serde_json::json!({ "file_paths": paths })
        } else if !self.questions.is_empty() {
            serde_json::json!({ "questions": self.questions })
        } else {
            serde_json::Value::Null
        };

        HookEnvelopePayload {
            tool_name: self.tool_name.clone().unwrap_or_default(),
            tool_input,
            tool_response: self
                .tool_response
                .clone()
                .unwrap_or(serde_json::Value::Null),
            last_assistant_message: self.last_assistant_message.clone(),
            transcript_path: None,
            stop_hook_active: self.stop_hook_active,
            raw_keys: vec![],
        }
    }

    /// Build a `GuardContext` for a given skill.
    #[must_use]
    pub fn build_context(self, skill: &str) -> GuardContext {
        GuardContext::from_envelope(skill, self.build_envelope())
    }

    /// Build a `GuardContext` with an associated run directory.
    #[must_use]
    pub fn build_context_with_run(self, skill: &str, run_dir: &Path) -> GuardContext {
        let context = GuardContext::from_envelope(skill, self.build_envelope());
        attach_run_context(context, run_dir, false)
    }
}

fn attach_run_context(
    mut context: GuardContext,
    run_dir: &Path,
    activate_skill: bool,
) -> GuardContext {
    context.run_dir = Some(run_dir.to_path_buf());
    if let Ok(run_context) = RunContext::from_run_dir(run_dir) {
        context.runner_state = runner_workflow::read_runner_state(&run_context.layout.run_dir())
            .ok()
            .flatten();
        context.run = Some(run_context);
        if activate_skill {
            context.skill_active = true;
        }
    }
    context
}

/// Build a bash hook envelope. Drop-in for `helpers::make_bash_payload`.
#[must_use]
pub fn make_bash_payload(command: &str) -> HookEnvelopePayload {
    HookPayloadBuilder::new().command(command).build_envelope()
}

/// Build a write hook envelope. Drop-in for `helpers::make_write_payload`.
#[must_use]
pub fn make_write_payload(file_path: &str) -> HookEnvelopePayload {
    HookPayloadBuilder::new()
        .write_path(file_path)
        .build_envelope()
}

/// Build a multi-write hook envelope. Drop-in for `helpers::make_multi_write_payload`.
#[must_use]
pub fn make_multi_write_payload(paths: &[&str]) -> HookEnvelopePayload {
    HookPayloadBuilder::new()
        .write_paths(paths)
        .build_envelope()
}

/// Build a stop hook envelope. Drop-in for `helpers::make_stop_payload`.
#[must_use]
pub fn make_stop_payload() -> HookEnvelopePayload {
    HookPayloadBuilder::new()
        .stop_hook_active(true)
        .build_envelope()
}

/// Build a question hook envelope. Drop-in for `helpers::make_question_payload`.
#[must_use]
pub fn make_question_payload(question: &str, options: &[&str]) -> HookEnvelopePayload {
    HookPayloadBuilder::new()
        .question(question, options)
        .build_envelope()
}

/// Build a question-with-answer hook envelope.
/// Drop-in for `helpers::make_question_answer_payload`.
#[must_use]
pub fn make_question_answer_payload(
    question: &str,
    options: &[&str],
    answer: &str,
) -> HookEnvelopePayload {
    HookPayloadBuilder::new()
        .question_with_answer(question, options, answer)
        .build_envelope()
}

/// Build an empty hook envelope. Drop-in for `helpers::make_empty_payload`.
#[must_use]
pub fn make_empty_payload() -> HookEnvelopePayload {
    HookPayloadBuilder::new().build_envelope()
}

/// Build a `GuardContext` for a given skill and envelope.
/// Drop-in for `helpers::make_hook_context`.
#[must_use]
pub fn make_hook_context(skill: &str, payload: HookEnvelopePayload) -> GuardContext {
    GuardContext::from_envelope(skill, payload)
}

/// Build a `GuardContext` with an associated run directory.
/// Drop-in for `helpers::make_hook_context_with_run`.
#[must_use]
pub fn make_hook_context_with_run(
    skill: &str,
    payload: HookEnvelopePayload,
    run_dir: &Path,
) -> GuardContext {
    let context = GuardContext::from_envelope(skill, payload);
    attach_run_context(context, run_dir, true)
}

/// Assert the hook result matches a specific decision.
///
/// # Panics
/// Panics if the decision does not match the expected value.
pub fn assert_decision(result: &HookResult, expected: &Decision) {
    assert_eq!(
        &result.decision, expected,
        "expected {expected:?}, got {:?} (code={}, message={})",
        result.decision, result.code, result.message
    );
}

/// Assert the hook result is Allow.
pub fn assert_allow(result: &HookResult) {
    assert_decision(result, &Decision::Allow);
}

/// Assert the hook result is Deny.
pub fn assert_deny(result: &HookResult) {
    assert_decision(result, &Decision::Deny);
}

/// Assert the hook result is Warn.
pub fn assert_warn(result: &HookResult) {
    assert_decision(result, &Decision::Warn);
}
