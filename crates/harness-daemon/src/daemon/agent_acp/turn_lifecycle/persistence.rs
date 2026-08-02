use crate::agents::turn::{AgentTurnId, AgentTurnRuntime, AgentTurnStatus};
use crate::daemon::agent_acp::{AcpAgentSessionState, AgentTurnSettlement};
use crate::daemon::db::prelude::*;
use crate::daemon::db::{AgentTurnRunSnapshot, AgentTurnRunStatus};
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_workspace::workspace::utc_now;

use super::{OPENROUTER_RUNTIME, OpenRouterAgentTurnRuntime, OpenRouterTurnBinding};

impl OpenRouterAgentTurnRuntime {
    pub(super) async fn persist_start(
        &self,
        id: &AgentTurnId,
        requested_model: Option<String>,
        source_revision: Option<String>,
    ) -> Result<(), CliError> {
        let Some(store) = &self.store else {
            return Ok(());
        };
        let now = utc_now();
        let correlation = self.correlation.as_ref();
        store
            .record_agent_turn_run_started(&AgentTurnRunSnapshot {
                run_id: self.durable_run_id(id),
                session_id: Some(self.session_id.clone()),
                task_id: correlation.and_then(|c| c.task_id.clone()),
                board_item_id: correlation.and_then(|c| c.board_item_id.clone()),
                workflow_execution_id: correlation.and_then(|c| c.workflow_execution_id.clone()),
                project_dir: self.project_dir.clone(),
                runtime_turn_id: Some(id.as_str().to_owned()),
                requested_runtime: OPENROUTER_RUNTIME.into(),
                actual_runtime: Some(OPENROUTER_RUNTIME.into()),
                requested_model,
                actual_model: None,
                status: AgentTurnRunStatus::Running,
                source_revision,
                report: None,
                stop_reason: None,
                error: None,
                created_at: now.clone(),
                updated_at: now,
            })
            .await
            .map(|_| ())
    }

    /// Rebind a durable correlated turn to this runtime instance and persist any
    /// terminal provider state observed by the remote executor's probe.
    pub(crate) async fn reconcile_correlated_turn(
        &self,
        run: &AgentTurnRunSnapshot,
    ) -> Result<(), CliError> {
        if run.status != AgentTurnRunStatus::Running {
            return Ok(());
        }
        let runtime_turn_id = run.runtime_turn_id.as_deref().ok_or_else(|| {
            CliError::from(CliErrorKind::invalid_transition(
                "running OpenRouter turn has no provider turn id",
            ))
        })?;
        let id = AgentTurnId::new(runtime_turn_id)?;
        if self.durable_run_id(&id) != run.run_id {
            return Err(CliErrorKind::invalid_transition(
                "OpenRouter turn correlation does not match its durable run",
            )
            .into());
        }
        self.lock_bindings()?
            .entry(id.clone())
            .or_insert_with(|| OpenRouterTurnBinding {
                requested_model: run.requested_model.clone(),
                source_revision: run.source_revision.clone(),
                cancelled: false,
                terminal_persisted: false,
            });
        let inspection = self.manager.inspect(&self.session_id)?;
        if !inspection.available {
            return Ok(());
        }
        let attached = inspection
            .agents
            .iter()
            .any(|agent| agent.acp_id == runtime_turn_id);
        if !attached {
            return self.settle_detached_turn(&id, runtime_turn_id).await;
        }
        match self.status(&id).await? {
            AgentTurnStatus::Completed => {
                self.result(&id).await?.ok_or_else(|| {
                    CliError::from(CliErrorKind::invalid_transition(
                        "completed OpenRouter turn has no result",
                    ))
                })?;
            }
            AgentTurnStatus::Failed | AgentTurnStatus::Cancelled => {
                self.failure(&id).await?.ok_or_else(|| {
                    CliError::from(CliErrorKind::invalid_transition(
                        "failed OpenRouter turn has no failure",
                    ))
                })?;
            }
            AgentTurnStatus::Queued | AgentTurnStatus::Running => {}
        }
        Ok(())
    }

    /// Persist whatever terminal outcome `state` reports, and return the
    /// effective model it observed. A state with no terminal outcome persists
    /// nothing.
    pub(super) async fn persist_observed_settlement(
        &self,
        id: &AgentTurnId,
        state: &AcpAgentSessionState,
    ) -> Result<Option<String>, CliError> {
        let Some(settlement) = AgentTurnSettlement::from_session_state(state) else {
            return Ok(None);
        };
        let actual_model = settlement.actual_model.clone();
        self.persist_settlement(
            id,
            settlement.status,
            settlement.actual_model,
            settlement.report,
            settlement.stop_reason,
            settlement.error,
        )
        .await?;
        Ok(actual_model)
    }

    /// Settle a turn whose provider session is no longer attached.
    ///
    /// A turn can fail and then detach before the next probe reads it, so the
    /// detached session's last reported state decides the outcome. Only a turn
    /// that never reported one settles on the detachment error itself.
    async fn settle_detached_turn(
        &self,
        id: &AgentTurnId,
        runtime_turn_id: &str,
    ) -> Result<(), CliError> {
        let settlement = self
            .manager
            .detached_turn_state(&self.session_id, runtime_turn_id)?
            .as_ref()
            .and_then(AgentTurnSettlement::from_session_state)
            .unwrap_or_else(AgentTurnSettlement::detached);
        self.persist_settlement(
            id,
            settlement.status,
            settlement.actual_model,
            settlement.report,
            settlement.stop_reason,
            settlement.error,
        )
        .await
    }

    /// Persist an observed terminal settlement exactly once per turn.
    pub(super) async fn persist_settlement(
        &self,
        id: &AgentTurnId,
        status: AgentTurnRunStatus,
        actual_model: Option<String>,
        report: Option<String>,
        stop_reason: Option<String>,
        error: Option<String>,
    ) -> Result<(), CliError> {
        let Some(store) = &self.store else {
            return Ok(());
        };
        if self
            .lock_bindings()?
            .get(id)
            .is_some_and(|binding| binding.terminal_persisted)
        {
            return Ok(());
        }
        let now = utc_now();
        store
            .save_agent_turn_run(&AgentTurnRunSnapshot {
                run_id: self.durable_run_id(id),
                session_id: Some(self.session_id.clone()),
                task_id: None,
                board_item_id: None,
                workflow_execution_id: None,
                project_dir: self.project_dir.clone(),
                runtime_turn_id: Some(id.as_str().to_owned()),
                requested_runtime: OPENROUTER_RUNTIME.into(),
                actual_runtime: Some(OPENROUTER_RUNTIME.into()),
                requested_model: None,
                actual_model,
                status,
                source_revision: None,
                report,
                stop_reason,
                error,
                created_at: now.clone(),
                updated_at: now,
            })
            .await?;
        if let Ok(mut bindings) = self.lock_bindings()
            && let Some(binding) = bindings.get_mut(id)
        {
            binding.terminal_persisted = true;
        }
        Ok(())
    }
}
