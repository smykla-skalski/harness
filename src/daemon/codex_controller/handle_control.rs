use std::convert::identity;
use std::future::Future;
use std::thread;
use std::time::Duration;

use serde_json::json;
use tokio::runtime::{Builder, Handle, RuntimeFlavor};
use tokio::sync::{mpsc, oneshot};
use tokio::task::block_in_place;
use tokio::time::timeout;

use crate::daemon::protocol::{
    CodexApprovalDecisionRequest, CodexApprovalRequest, CodexApprovalRequestedPayload,
    CodexRunSnapshot, CodexRunStatus, CodexSteerRequest,
};
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

use super::active_runs::{ActiveRun, ActiveRunRegistration, CodexControlAck, CodexControlMessage};
use super::handle::{CodexControllerHandle, record_snapshot_event};
use super::worker::CodexRunWorker;

impl CodexControllerHandle {
    /// Send same-turn steering text to an active Codex run.
    ///
    /// # Errors
    /// Returns [`CliError`] when the run is inactive or the request cannot be queued.
    pub fn steer(
        &self,
        run_id: &str,
        request: &CodexSteerRequest,
    ) -> Result<CodexRunSnapshot, CliError> {
        let prompt = request.prompt.trim();
        if prompt.is_empty() {
            return Err(CliErrorKind::workflow_parse("codex steer prompt cannot be empty").into());
        }
        if let Ok(active) = self.active_run(run_id) {
            return self.send_control_and_wait(&active, "steer", |ack| {
                CodexControlMessage::Steer {
                    prompt: prompt.to_string(),
                    ack,
                }
            });
        }

        self.start_follow_up_turn(run_id, prompt)
    }

    /// Interrupt an active Codex turn.
    ///
    /// # Errors
    /// Returns [`CliError`] when the run is inactive or the request cannot be queued.
    pub fn interrupt(&self, run_id: &str) -> Result<CodexRunSnapshot, CliError> {
        let active = self.active_run(run_id)?;
        self.send_control_and_wait(&active, "interrupt", |ack| CodexControlMessage::Interrupt {
            ack,
        })
    }

    /// Stop a managed Codex agent.
    ///
    /// # Errors
    /// Returns [`CliError`] when the run cannot be loaded or the stopped
    /// snapshot cannot be persisted.
    pub fn stop(&self, run_id: &str) -> Result<CodexRunSnapshot, CliError> {
        let mut snapshot = self.load_run(run_id)?;
        if !snapshot.status.is_active() {
            self.sync_orchestration_status_for_run(&snapshot)?;
            return Ok(snapshot);
        }
        if let Ok(active) = self.active_run(run_id) {
            return self
                .send_control_and_wait(&active, "stop", |ack| CodexControlMessage::Stop { ack });
        }
        self.state.active_runs.remove(run_id);
        snapshot.status = CodexRunStatus::Cancelled;
        snapshot.latest_summary = Some("Codex agent stopped".to_string());
        snapshot.error = None;
        snapshot.pending_approvals.clear();
        snapshot.updated_at = utc_now();
        record_snapshot_event(
            &mut snapshot,
            "agent/stop",
            "Codex agent stopped".to_string(),
            &json!({
                "runId": run_id,
                "status": "cancelled",
            }),
        );
        self.save_and_broadcast(&snapshot)?;
        self.sync_orchestration_status_for_run(&snapshot)?;
        Ok(snapshot)
    }

    /// Resolve a pending Codex approval prompt.
    ///
    /// # Errors
    /// Returns [`CliError`] when the run is inactive or the approval cannot be queued.
    pub fn resolve_approval(
        &self,
        run_id: &str,
        approval_id: &str,
        request: &CodexApprovalDecisionRequest,
    ) -> Result<CodexRunSnapshot, CliError> {
        let active = self.active_run(run_id)?;
        self.send_control_and_wait(&active, "approval", |ack| CodexControlMessage::Approval {
            approval_id: approval_id.to_string(),
            decision: request.decision,
            ack,
        })
    }

    pub(super) fn active_run(&self, run_id: &str) -> Result<ActiveRun, CliError> {
        self.state.active_runs.get(run_id)
    }

    pub(super) fn send_control_and_wait(
        &self,
        active: &ActiveRun,
        action: &str,
        build: impl FnOnce(CodexControlAck) -> CodexControlMessage,
    ) -> Result<CodexRunSnapshot, CliError> {
        let (ack, receiver) = oneshot::channel();
        active
            .control_tx
            .send(build(ack))
            .map_err(|error| CliErrorKind::workflow_io(format!("queue codex {action}: {error}")))?;
        self.wait_for_control_ack(action, receiver)
    }

    fn wait_for_control_ack(
        &self,
        action: &str,
        receiver: oneshot::Receiver<Result<CodexRunSnapshot, CliError>>,
    ) -> Result<CodexRunSnapshot, CliError> {
        let action = action.to_string();
        self.block_on_controller_future(async move {
            let result = timeout(Duration::from_secs(30), receiver)
                .await
                .map_err(|_| {
                    CliErrorKind::workflow_io(format!(
                        "codex {action} worker did not acknowledge within 30s"
                    ))
                })?;
            result.map_err(|error| {
                CliErrorKind::workflow_io(format!(
                    "codex {action} worker dropped before acknowledgement: {error}"
                ))
            })?
        })
    }

    fn start_follow_up_turn(
        &self,
        run_id: &str,
        prompt: &str,
    ) -> Result<CodexRunSnapshot, CliError> {
        let snapshot = self.run(run_id)?;
        if snapshot.thread_id.is_none() {
            return Err(CliErrorKind::session_not_active(format!(
                "codex agent '{run_id}' has no thread to resume"
            ))
            .into());
        }
        if snapshot.status.is_active() {
            return Err(CliErrorKind::session_agent_conflict(format!(
                "codex agent '{run_id}' already has an active turn"
            ))
            .into());
        }
        let reservation = match self.state.active_runs.reserve(run_id.to_string())? {
            ActiveRunRegistration::Acquired(reservation) => reservation,
            ActiveRunRegistration::Waiting(waiter) => return waiter.wait(),
            ActiveRunRegistration::Active => {
                return Err(CliErrorKind::session_agent_conflict(format!(
                    "codex agent '{run_id}' already has an active turn"
                ))
                .into());
            }
        };
        let snapshot = match self.prepare_follow_up_turn(snapshot, prompt) {
            Ok(snapshot) => snapshot,
            Err(error) => {
                reservation.abort(&error);
                return Err(error);
            }
        };
        let (control_tx, control_rx) = mpsc::unbounded_channel();
        if let Err(error) = reservation.commit(control_tx, snapshot.clone()) {
            self.record_follow_up_attach_failure(&snapshot, &error);
            return Err(error);
        }
        let worker = CodexRunWorker::new(self.clone(), snapshot.clone(), control_rx);
        tokio::spawn(async move {
            worker.run().await;
        });
        Ok(snapshot)
    }

    fn prepare_follow_up_turn(
        &self,
        mut snapshot: CodexRunSnapshot,
        prompt: &str,
    ) -> Result<CodexRunSnapshot, CliError> {
        self.preflight_websocket_probe(&snapshot.session_id)?;
        snapshot.prompt = prompt.to_string();
        snapshot.turn_id = None;
        snapshot.status = CodexRunStatus::Queued;
        snapshot.latest_summary = Some("Queued follow-up turn".to_string());
        snapshot.final_message = None;
        snapshot.error = None;
        snapshot.pending_approvals.clear();
        snapshot.updated_at = utc_now();
        super::completion_evidence::record_clean_worktree_baseline(&mut snapshot);
        self.save_and_broadcast(&snapshot)?;
        self.sync_orchestration_status_for_run(&snapshot)?;
        Ok(snapshot)
    }

    fn record_follow_up_attach_failure(&self, snapshot: &CodexRunSnapshot, error: &CliError) {
        let mut failed = snapshot.clone();
        failed.status = CodexRunStatus::Failed;
        failed.latest_summary =
            Some("Codex worker could not attach follow-up turn to daemon".to_string());
        failed.error = Some(error.to_string());
        failed.updated_at = utc_now();
        let payload = json!({
            "runId": failed.run_id.clone(),
            "status": "failed",
            "reason": "active run registry failed",
            "error": failed.error.clone(),
        });
        record_snapshot_event(
            &mut failed,
            "agent/reconciled",
            "Codex follow-up worker could not attach to daemon".to_string(),
            &payload,
        );
        let _ = self.save_and_broadcast(&failed);
        let _ = self.sync_orchestration_status_for_run(&failed);
    }

    pub(super) fn broadcast_approval(
        &self,
        snapshot: &CodexRunSnapshot,
        approval: &CodexApprovalRequest,
    ) {
        let payload = CodexApprovalRequestedPayload {
            run: snapshot.clone(),
            approval: approval.clone(),
        };
        self.broadcast("codex_approval_requested", snapshot, &payload);
    }

    pub(super) fn block_on_controller_future<T, Fut>(&self, future: Fut) -> Result<T, CliError>
    where
        Fut: Future<Output = Result<T, CliError>> + Send + 'static,
        T: Send + 'static,
    {
        if let Some(runtime) = self.state.runtime.clone() {
            return match Handle::try_current() {
                Ok(current) => match current.runtime_flavor() {
                    RuntimeFlavor::MultiThread => block_in_place(|| runtime.block_on(future)),
                    RuntimeFlavor::CurrentThread => thread::spawn(move || {
                        Builder::new_current_thread()
                            .enable_all()
                            .build()
                            .map_err(|error| {
                                CliError::from(CliErrorKind::workflow_io(format!(
                                    "build codex control runtime: {error}"
                                )))
                            })?
                            .block_on(future)
                    })
                    .join()
                    .map_err(|_| {
                        CliError::from(CliErrorKind::workflow_io("join codex control thread"))
                    })
                    .and_then(identity),
                    _ => runtime.block_on(future),
                },
                Err(_) => runtime.block_on(future),
            };
        }
        Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|error| {
                CliError::from(CliErrorKind::workflow_io(format!(
                    "build codex control runtime: {error}"
                )))
            })?
            .block_on(future)
    }
}
