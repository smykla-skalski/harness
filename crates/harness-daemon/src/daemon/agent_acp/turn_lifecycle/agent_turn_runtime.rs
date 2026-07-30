use async_trait::async_trait;

use crate::agents::turn::{
    AgentTurnFailure, AgentTurnFailureCategory, AgentTurnId, AgentTurnRequest, AgentTurnResult,
    AgentTurnRuntime, AgentTurnStatus,
};
use crate::daemon::agent_acp::AcpSessionConfigOptionState;
use crate::daemon::db::AgentTurnRunStatus;
use harness_kernel::errors::CliError;

use super::{OPENROUTER_RUNTIME, OpenRouterAgentTurnRuntime};

#[async_trait]
impl AgentTurnRuntime for OpenRouterAgentTurnRuntime {
    fn runtime(&self) -> &'static str {
        OPENROUTER_RUNTIME
    }

    async fn start(&self, request: AgentTurnRequest) -> Result<AgentTurnId, CliError> {
        self.start_with_resume_session(request, None).await
    }

    async fn status(&self, id: &AgentTurnId) -> Result<AgentTurnStatus, CliError> {
        let binding = self.binding(id)?;
        if binding.cancelled {
            return Ok(AgentTurnStatus::Cancelled);
        }
        let state = self.inspect_turn(id)?.session_state.unwrap_or_default();
        if let Some(failure) = state.last_turn_failure {
            return Ok(if failure.category == AgentTurnFailureCategory::Cancelled {
                AgentTurnStatus::Cancelled
            } else {
                AgentTurnStatus::Failed
            });
        }
        if state.last_turn_result.is_some() {
            Ok(AgentTurnStatus::Completed)
        } else {
            Ok(AgentTurnStatus::Running)
        }
    }

    async fn result(&self, id: &AgentTurnId) -> Result<Option<AgentTurnResult>, CliError> {
        let binding = self.binding(id)?;
        if binding.cancelled {
            return Ok(None);
        }
        let snapshot = self.inspect_turn(id)?;
        let state = snapshot.session_state.unwrap_or_default();
        let Some(result) = state.last_turn_result else {
            return Ok(None);
        };
        let effective_model = effective_model(&state.config_options);
        self.persist_settlement(
            id,
            AgentTurnRunStatus::Completed,
            effective_model.clone(),
            Some(result.report.clone()),
            Some(result.stop_reason.clone()),
            None,
        )
        .await?;
        Ok(Some(AgentTurnResult {
            correlation_id: id.clone(),
            report: result.report,
            stop_reason: result.stop_reason,
            requested_model: binding.requested_model,
            effective_model,
            source_revision: binding.source_revision,
        }))
    }

    async fn failure(&self, id: &AgentTurnId) -> Result<Option<AgentTurnFailure>, CliError> {
        let binding = self.binding(id)?;
        if binding.cancelled {
            return Ok(Some(AgentTurnFailure::cancelled(
                "OpenRouter turn cancelled",
            )));
        }
        let Some(state) = self.inspect_turn(id)?.session_state else {
            return Ok(None);
        };
        let Some(failure) = state.last_turn_failure else {
            return Ok(None);
        };
        let actual_model = effective_model(&state.config_options);
        let (run_status, stop_reason, error) =
            if failure.category == AgentTurnFailureCategory::Cancelled {
                (
                    AgentTurnRunStatus::Cancelled,
                    Some(failure.detail.clone()),
                    None,
                )
            } else {
                (
                    AgentTurnRunStatus::Failed,
                    None,
                    Some(failure.detail.clone()),
                )
            };
        self.persist_settlement(id, run_status, actual_model, None, stop_reason, error)
            .await?;
        Ok(Some(failure))
    }

    async fn cancel(&self, id: &AgentTurnId) -> Result<AgentTurnStatus, CliError> {
        if !self.begin_cancellation(id)? {
            return Ok(AgentTurnStatus::Cancelled);
        }
        if let Err(error) = self.manager.stop(id.as_str()) {
            self.rollback_cancellation(id)?;
            return Err(error);
        }
        if let Err(error) = self
            .persist_settlement(
                id,
                AgentTurnRunStatus::Cancelled,
                None,
                None,
                Some("cancelled".into()),
                None,
            )
            .await
        {
            self.rollback_cancellation(id)?;
            return Err(error);
        }
        Ok(AgentTurnStatus::Cancelled)
    }
}

fn effective_model(options: &[AcpSessionConfigOptionState]) -> Option<String> {
    options
        .iter()
        .find(|option| option.id == "model")
        .map(|option| option.current_value.clone())
}
