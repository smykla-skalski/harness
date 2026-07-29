use async_trait::async_trait;

use crate::agents::turn::{
    AgentTurnFailure, AgentTurnFailureCategory, AgentTurnFailureStage, AgentTurnId,
    AgentTurnRequest, AgentTurnResult, AgentTurnRuntime, AgentTurnStatus,
};
use crate::daemon::protocol::{CodexRunMode, CodexRunRequest, CodexRunSnapshot, CodexRunStatus};
use crate::daemon::remote_redaction::redact_known_secrets;
use crate::session::types::SessionRole;
use harness_kernel::errors::{CliError, CliErrorKind};

use super::{CodexControllerHandle, wire};

#[derive(Clone)]
pub struct CodexAgentTurnRuntime {
    controller: CodexControllerHandle,
    session_id: String,
}

impl CodexAgentTurnRuntime {
    #[must_use]
    pub fn new(controller: CodexControllerHandle, session_id: impl Into<String>) -> Self {
        Self {
            controller,
            session_id: session_id.into(),
        }
    }

    fn bound_snapshot(&self, id: &AgentTurnId) -> Result<CodexRunSnapshot, CliError> {
        let snapshot = self.controller.load_run(id.as_str())?;
        if snapshot.session_id != self.session_id {
            return Err(CliErrorKind::session_scope_denied(format!(
                "Codex turn '{id}' does not belong to session '{}'",
                self.session_id
            ))
            .into());
        }
        if snapshot.mode != CodexRunMode::Report {
            return Err(CliErrorKind::invalid_transition(format!(
                "Codex turn '{id}' is not a report run"
            ))
            .into());
        }
        Ok(snapshot)
    }

    fn snapshot(&self, id: &AgentTurnId) -> Result<CodexRunSnapshot, CliError> {
        self.controller.reconcile_run(self.bound_snapshot(id)?)
    }
}

#[async_trait]
impl AgentTurnRuntime for CodexAgentTurnRuntime {
    fn runtime(&self) -> &'static str {
        "codex"
    }

    async fn start(&self, request: AgentTurnRequest) -> Result<AgentTurnId, CliError> {
        let snapshot = self.controller.start_run(
            &self.session_id,
            &CodexRunRequest {
                actor: Some("agent-turn-lifecycle".into()),
                prompt: request.prompt,
                mode: CodexRunMode::Report,
                role: SessionRole::Worker,
                fallback_role: None,
                capabilities: Vec::new(),
                name: Some("Codex report turn".into()),
                persona: None,
                resume_thread_id: None,
                task_id: None,
                board_item_id: None,
                workflow_execution_id: None,
                model: request.requested_model,
                effort: None,
                allow_custom_model: false,
            },
        )?;
        AgentTurnId::new(snapshot.run_id)
    }

    async fn status(&self, id: &AgentTurnId) -> Result<AgentTurnStatus, CliError> {
        Ok(shared_status(self.snapshot(id)?.status))
    }

    async fn result(&self, id: &AgentTurnId) -> Result<Option<AgentTurnResult>, CliError> {
        let snapshot = self.snapshot(id)?;
        if snapshot.status != CodexRunStatus::Completed {
            return Ok(None);
        }
        let effective_model = codex_effective_model(&snapshot);
        let report = snapshot
            .final_message
            .filter(|report| !report.trim().is_empty())
            .ok_or_else(|| {
                CliError::from(CliErrorKind::workflow_parse(format!(
                    "completed Codex turn '{id}' omitted its final report"
                )))
            })?;
        Ok(Some(AgentTurnResult {
            correlation_id: id.clone(),
            report,
            stop_reason: "end_turn".into(),
            requested_model: snapshot.model,
            effective_model,
        }))
    }

    async fn failure(&self, id: &AgentTurnId) -> Result<Option<AgentTurnFailure>, CliError> {
        let snapshot = self.snapshot(id)?;
        match snapshot.status {
            CodexRunStatus::Failed => Ok(Some(codex_failure(snapshot.error.as_deref()))),
            CodexRunStatus::Cancelled => {
                Ok(Some(AgentTurnFailure::cancelled("Codex turn cancelled")))
            }
            CodexRunStatus::Queued
            | CodexRunStatus::Running
            | CodexRunStatus::WaitingApproval
            | CodexRunStatus::Completed => Ok(None),
        }
    }

    async fn cancel(&self, id: &AgentTurnId) -> Result<AgentTurnStatus, CliError> {
        self.bound_snapshot(id)?;
        Ok(shared_status(self.controller.stop(id.as_str())?.status))
    }
}

fn codex_effective_model(snapshot: &CodexRunSnapshot) -> Option<String> {
    snapshot.events.iter().rev().find_map(|event| {
        if !matches!(event.kind.as_str(), "thread/start" | "thread/resume") {
            return None;
        }
        event.payload.get("model")?.as_str().map(ToOwned::to_owned)
    })
}

fn codex_failure(error: Option<&str>) -> AgentTurnFailure {
    let raw_detail = error.unwrap_or("Codex execution failed without an error detail");
    let category = AgentTurnFailureCategory::from_message(raw_detail);
    let stage = if is_model_mismatch(raw_detail) {
        AgentTurnFailureStage::Start
    } else {
        AgentTurnFailureStage::Execution
    };
    AgentTurnFailure::new(category, stage, bounded_redacted_detail(raw_detail))
}

fn is_model_mismatch(detail: &str) -> bool {
    detail
        .strip_prefix("[WORKFLOW_PARSE] ")
        .unwrap_or(detail)
        .starts_with(wire::MODEL_MISMATCH_DETAIL)
}

fn bounded_redacted_detail(detail: &str) -> String {
    redact_known_secrets(detail).chars().take(512).collect()
}

const fn shared_status(status: CodexRunStatus) -> AgentTurnStatus {
    match status {
        CodexRunStatus::Queued => AgentTurnStatus::Queued,
        CodexRunStatus::Running | CodexRunStatus::WaitingApproval => AgentTurnStatus::Running,
        CodexRunStatus::Completed => AgentTurnStatus::Completed,
        CodexRunStatus::Failed => AgentTurnStatus::Failed,
        CodexRunStatus::Cancelled => AgentTurnStatus::Cancelled,
    }
}
