use crate::daemon::protocol::CodexRunStatus;
use crate::daemon::protocol::{CodexRunRequest, CodexRunSnapshot, TaskBoardEvaluateRequest};
use crate::daemon::service as daemon_service;
use crate::session::service as session_service;
use crate::session::types::{
    AgentStatus, CONTROL_PLANE_ACTOR_ID, ManagedAgentRef, SessionState, TaskStatus,
};
use crate::workspace::utc_now;
use harness_kernel::errors::{CliError, CliErrorKind};

use super::handle::{CodexControllerHandle, lock_db};
use super::handle_orchestration_lifecycle::{
    SessionlessWorkItemTerminalReport, apply_bound_task_terminal_transition,
    sessionless_work_item_terminal_report,
};
use super::orchestration::{
    orchestration_status_for_codex_run, rollback_codex_registration,
    update_codex_orchestration_status,
};
use super::orchestration_registration::{RegisteredOrchestrationAgent, RegistrationMutation};
use crate::daemon::db::prelude::*;
use crate::daemon::db::task_board::prelude::WorkItemProgressQueries;
use crate::daemon::db::task_board::work_item_progress::TaskBoardWorkItemReportRequest;

fn should_reconcile_board_item(
    state: &SessionState,
    run: &CodexRunSnapshot,
    task_changed: bool,
) -> bool {
    if run.status.is_active() || run.board_item_id.is_none() {
        return false;
    }
    task_changed
        || run
            .task_id
            .as_deref()
            .and_then(|task_id| state.tasks.get(task_id))
            .is_some_and(|task| task.status != TaskStatus::InProgress)
}

async fn persist_sessionless_work_item_terminal_async(
    db: &crate::daemon::db_handle::AsyncDaemonDbHandle,
    board_item_id: &str,
    work_item_id: &str,
    report: SessionlessWorkItemTerminalReport,
) -> Result<bool, CliError> {
    let current = db.task_board_work_item_progress(board_item_id).await?;
    if current
        .as_ref()
        .is_some_and(|progress| progress.work_item_id != work_item_id)
    {
        return Ok(false);
    }
    if db
        .task_board_work_item_is_workflow_owned(board_item_id, work_item_id)
        .await?
    {
        return Ok(false);
    }
    if current
        .as_ref()
        .is_some_and(|progress| terminal_report_matches(progress, &report))
    {
        return Ok(false);
    }
    let sequence = current
        .as_ref()
        .map(|progress| {
            progress.report_sequence.checked_add(1).ok_or_else(|| {
                CliError::from(CliErrorKind::invalid_transition(
                    "task-board work item report sequence is exhausted",
                ))
            })
        })
        .transpose()?;
    let outcome = db
        .report_task_board_work_item_progress(&TaskBoardWorkItemReportRequest {
            board_item_id: board_item_id.to_string(),
            work_item_id: work_item_id.to_string(),
            actor: CONTROL_PLANE_ACTOR_ID.to_string(),
            state: Some(report.state),
            summary: report.summary,
            progress_percent: None,
            blocked_reason: report.blocked_reason,
            sequence,
        })
        .await?;
    Ok(outcome.applied)
}

fn terminal_report_matches(
    progress: &crate::task_board::TaskBoardWorkItemProgress,
    report: &SessionlessWorkItemTerminalReport,
) -> bool {
    progress.state == report.state
        && progress.summary == report.summary
        && progress.blocked_reason == report.blocked_reason
}

impl CodexControllerHandle {
    pub(super) fn sync_orchestration_status_for_run(
        &self,
        run: &CodexRunSnapshot,
    ) -> Result<(), CliError> {
        let normalized = self.normalized_failed_completion(run)?;
        let run = normalized.as_ref().unwrap_or(run);
        let status = orchestration_status_for_codex_run(run.status);
        if self.persist_orchestration_status_for_run(run, status)? {
            self.broadcast_session_snapshot_best_effort(&run.session_id);
        }
        Ok(())
    }

    pub(super) fn normalized_failed_completion(
        &self,
        run: &CodexRunSnapshot,
    ) -> Result<Option<CodexRunSnapshot>, CliError> {
        if run.status != CodexRunStatus::Completed || self.completed_run_has_evidence(run)? {
            return Ok(None);
        }
        let mut failed = run.clone();
        let error = super::completion_evidence::missing_completion_evidence_error(run);
        failed.status = CodexRunStatus::Failed;
        failed.latest_summary = Some(error.clone());
        failed.error = Some(error);
        failed.updated_at = utc_now();
        self.save_and_broadcast(&failed)?;
        Ok(Some(failed))
    }

    fn persist_orchestration_status_for_run(
        &self,
        run: &CodexRunSnapshot,
        status: AgentStatus,
    ) -> Result<bool, CliError> {
        let Some(session_agent_id) = run.session_agent_id.clone() else {
            return self.persist_sessionless_work_item_terminal(run);
        };
        let managed_agent = ManagedAgentRef::codex(run.run_id.as_str());
        if let Some(result) = self.persist_orchestration_status_async(
            run,
            session_agent_id.clone(),
            managed_agent.clone(),
            status.clone(),
        ) {
            return result;
        }
        self.persist_orchestration_status_sync(run, &session_agent_id, &managed_agent, status)
    }

    fn persist_sessionless_work_item_terminal(
        &self,
        run: &CodexRunSnapshot,
    ) -> Result<bool, CliError> {
        let (Some(board_item_id), Some(work_item_id), Some(report)) = (
            run.board_item_id.clone(),
            run.task_id.clone(),
            sessionless_work_item_terminal_report(run),
        ) else {
            return Ok(false);
        };
        let Some(result) = self.run_with_async_db(|db| async move {
            persist_sessionless_work_item_terminal_async(&db, &board_item_id, &work_item_id, report)
                .await
        }) else {
            return Ok(false);
        };
        result
    }

    fn persist_orchestration_status_async(
        &self,
        run: &CodexRunSnapshot,
        session_agent_id: String,
        managed_agent: ManagedAgentRef,
        status: AgentStatus,
    ) -> Option<Result<bool, CliError>> {
        let session_id_async = run.session_id.clone();
        let run_async = run.clone();
        self.run_with_async_db(|async_db| async move {
            let now = utc_now();
            let status_for_update = status.clone();
            let (changed, reconcile_board_item) = async_db
                .update_session_state_immediate(&session_id_async, |state| {
                    let task_changed =
                        apply_bound_task_terminal_transition(state, &run_async, &now)?;
                    let status_changed = update_codex_orchestration_status(
                        state,
                        &session_agent_id,
                        &managed_agent,
                        status_for_update,
                        &now,
                    );
                    if task_changed || status_changed {
                        session_service::refresh_session(state, &now);
                    }
                    Ok((
                        task_changed || status_changed,
                        should_reconcile_board_item(state, &run_async, task_changed),
                    ))
                })
                .await?;
            if changed {
                daemon_service::sync_file_state_from_async_db(&async_db, &session_id_async).await?;
                async_db.bump_change(&session_id_async).await?;
                async_db.bump_change("global").await?;
            }
            if reconcile_board_item && let Some(board_item_id) = run_async.board_item_id.clone() {
                Box::pin(daemon_service::evaluate_task_board_async(
                    &TaskBoardEvaluateRequest {
                        item_id: Some(board_item_id),
                        status: None,
                        dry_run: false,
                    },
                    &async_db,
                ))
                .await?;
            }
            Ok(changed)
        })
    }

    fn persist_orchestration_status_sync(
        &self,
        run: &CodexRunSnapshot,
        session_agent_id: &str,
        managed_agent: &ManagedAgentRef,
        status: AgentStatus,
    ) -> Result<bool, CliError> {
        let db = self.db()?;
        let db = lock_db(&db)?;
        let Some(mut state) = db.load_session_state_for_mutation(&run.session_id)? else {
            return Ok(false);
        };
        let now = utc_now();
        let task_changed = apply_bound_task_terminal_transition(&mut state, run, &now)?;
        let status_changed = update_codex_orchestration_status(
            &mut state,
            session_agent_id,
            managed_agent,
            status,
            &now,
        );
        if !task_changed && !status_changed {
            return Ok(false);
        }
        session_service::refresh_session(&mut state, &now);
        let project_id = db
            .project_id_for_session(&run.session_id)?
            .ok_or_else(|| daemon_service::session_not_found(&run.session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.bump_change(&run.session_id)?;
        db.bump_change("global")?;
        Ok(true)
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "best-effort broadcast deliberately falls through async and sync delivery paths"
    )]
    fn broadcast_session_snapshot_best_effort(&self, session_id: &str) {
        if self.spawn_async_session_snapshot_broadcast(session_id) {
            return;
        }
        if let Err(error) = self.broadcast_session_snapshot(session_id) {
            tracing::warn!(
                %error,
                session_id,
                "failed to broadcast codex orchestration status update"
            );
        }
    }

    fn spawn_async_session_snapshot_broadcast(&self, session_id: &str) -> bool {
        let (Some(async_db), Some(runtime)) = (
            self.state.async_db.get().cloned(),
            self.state.runtime.clone(),
        ) else {
            return false;
        };
        let sender = self.state.sender.clone();
        let session_id = session_id.to_string();
        runtime.spawn(async move {
            daemon_service::broadcast_session_snapshot_async(
                &sender,
                &session_id,
                Some(async_db.as_ref()),
            )
            .await;
        });
        true
    }

    fn broadcast_session_snapshot(&self, session_id: &str) -> Result<(), CliError> {
        let db = self.db()?;
        let db = lock_db(&db)?;
        daemon_service::broadcast_session_snapshot(&self.state.sender, session_id, Some(&db));
        Ok(())
    }

    pub(super) fn register_orchestration_agent(
        &self,
        session_id: &str,
        run_id: &str,
        request: &CodexRunRequest,
        display_name: &str,
    ) -> Result<RegisteredOrchestrationAgent, CliError> {
        let managed_agent = ManagedAgentRef::codex(run_id);
        if let Some(result) = super::orchestration_registration::register_async(
            self,
            session_id,
            request,
            display_name,
            &managed_agent,
        ) {
            return result;
        }
        super::orchestration_registration::register_sync(
            self,
            session_id,
            request,
            display_name,
            &managed_agent,
        )
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "rollback keeps async and sync session-state paths together for identical logging"
    )]
    pub(super) fn rollback_orchestration_agent_registration(
        &self,
        session_id: &str,
        session_agent_id: &str,
        managed_agent: &ManagedAgentRef,
        mutation: &RegistrationMutation,
    ) {
        if self.rollback_orchestration_agent_registration_async(
            session_id,
            session_agent_id,
            managed_agent,
            mutation,
        ) {
            return;
        }

        match self.rollback_orchestration_agent_registration_sync(
            session_id,
            session_agent_id,
            managed_agent,
            mutation,
        ) {
            Err(error) => tracing::warn!(
                %error,
                session_id,
                session_agent_id,
                "failed to roll back codex orchestration agent registration"
            ),
            Ok(false) => tracing::warn!(
                session_id,
                session_agent_id,
                "skipped codex registration rollback after concurrent session mutation"
            ),
            Ok(true) => {}
        }
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "async rollback handles optional async database availability and change bumping"
    )]
    fn rollback_orchestration_agent_registration_async(
        &self,
        session_id: &str,
        session_agent_id: &str,
        managed_agent: &ManagedAgentRef,
        mutation: &RegistrationMutation,
    ) -> bool {
        let session_id_for_task = session_id.to_string();
        let session_agent_id_for_task = session_agent_id.to_string();
        let session_id_for_log = session_id.to_string();
        let session_agent_id_for_log = session_agent_id.to_string();
        let managed_agent = managed_agent.clone();
        let mutation = mutation.clone();
        let Some(result) = self.run_with_async_db(|async_db| async move {
            let now = utc_now();
            let removed = async_db
                .update_session_state_immediate(&session_id_for_task, |state| {
                    Ok(rollback_codex_registration(
                        state,
                        &session_agent_id_for_task,
                        &managed_agent,
                        mutation.newly_joined,
                        mutation.task_binding_rollback.as_ref(),
                        &now,
                    ))
                })
                .await?;
            if removed {
                if mutation.newly_joined {
                    async_db
                        .append_log_entry(&daemon_service::build_log_entry(
                            &session_id_for_task,
                            session_service::log_agent_removed(&session_agent_id_for_task),
                            None,
                            Some("Codex startup rolled back before the run was persisted"),
                        ))
                        .await?;
                }
                daemon_service::sync_file_state_from_async_db(&async_db, &session_id_for_task)
                    .await?;
                async_db.bump_change(&session_id_for_task).await?;
                async_db.bump_change("global").await?;
            }
            Ok(removed)
        }) else {
            return false;
        };
        match result {
            Err(error) => tracing::warn!(
                %error,
                session_id = %session_id_for_log,
                session_agent_id = %session_agent_id_for_log,
                "failed to roll back codex orchestration agent registration"
            ),
            Ok(false) => tracing::warn!(
                session_id = %session_id_for_log,
                session_agent_id = %session_agent_id_for_log,
                "skipped codex registration rollback after concurrent session mutation"
            ),
            Ok(true) => {}
        }
        true
    }

    fn rollback_orchestration_agent_registration_sync(
        &self,
        session_id: &str,
        session_agent_id: &str,
        managed_agent: &ManagedAgentRef,
        mutation: &RegistrationMutation,
    ) -> Result<bool, CliError> {
        let db = self.db()?;
        let db = lock_db(&db)?;
        let Some(mut state) = db.load_session_state_for_mutation(session_id)? else {
            return Ok(false);
        };
        let now = utc_now();
        if !rollback_codex_registration(
            &mut state,
            session_agent_id,
            managed_agent,
            mutation.newly_joined,
            mutation.task_binding_rollback.as_ref(),
            &now,
        ) {
            return Ok(false);
        }
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| daemon_service::session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        if mutation.newly_joined {
            db.append_log_entry(&daemon_service::build_log_entry(
                session_id,
                session_service::log_agent_removed(session_agent_id),
                None,
                Some("Codex startup rolled back before the run was persisted"),
            ))?;
        }
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        Ok(true)
    }
}
