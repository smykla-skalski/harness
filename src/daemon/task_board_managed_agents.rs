use std::time::Duration;

use tokio::task::JoinHandle;
use tokio::time::sleep;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::http::{
    DaemonHttpState, require_async_db, run_codex_agent_blocking, run_terminal_agent_blocking,
};
use crate::daemon::protocol::ManagedAgentSnapshot;
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{
    AgentMode, DispatchAppliedTask, TaskBoardLaunchCapability,
    validate_task_board_read_only_run_context,
};

const DISPATCH_CLAIM_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(10);

mod requests;
use requests::{codex_worker_request, terminal_worker_request, worker_prompt};

mod claim_settlement;
pub(crate) use claim_settlement::settle_claimed_task_board_worker;

pub(crate) struct TaskBoardDispatchClaimHeartbeat {
    task: JoinHandle<()>,
}

#[derive(Debug)]
pub(crate) struct TaskBoardWorkerStartError {
    error: CliError,
    may_rollback: bool,
}

impl TaskBoardWorkerStartError {
    fn uncertain(error: CliError) -> Self {
        Self {
            error,
            may_rollback: false,
        }
    }

    fn uncertain_after_start(start_error: &CliError, probe_error: &CliError) -> Self {
        Self::uncertain(
            CliErrorKind::workflow_io(format!(
                "managed worker start failed ({start_error}); deterministic recovery probe was uncertain ({probe_error})"
            ))
            .into(),
        )
    }

    #[must_use]
    pub(crate) const fn may_rollback(&self) -> bool {
        self.may_rollback
    }

    #[must_use]
    pub(crate) fn into_cli_error(self) -> CliError {
        self.error
    }
}

impl From<CliError> for TaskBoardWorkerStartError {
    fn from(error: CliError) -> Self {
        Self {
            error,
            may_rollback: true,
        }
    }
}

impl Drop for TaskBoardDispatchClaimHeartbeat {
    fn drop(&mut self) {
        self.task.abort();
    }
}

pub(crate) fn maintain_task_board_dispatch_claim(
    db: AsyncDaemonDb,
    intent_id: &str,
    claim_token: &str,
) -> TaskBoardDispatchClaimHeartbeat {
    let intent_id = intent_id.to_string();
    let claim_token = claim_token.to_string();
    let task = tokio::spawn(async move {
        loop {
            sleep(DISPATCH_CLAIM_HEARTBEAT_INTERVAL).await;
            if let Err(error) = db
                .renew_task_board_dispatch_claim(&intent_id, &claim_token)
                .await
            {
                tracing::warn!(%intent_id, %error, "task board worker claim heartbeat stopped");
                break;
            }
        }
    });
    TaskBoardDispatchClaimHeartbeat { task }
}

#[cfg(test)]
async fn start_worker_for_applied_task(
    state: &DaemonHttpState,
    applied: &DispatchAppliedTask,
    dispatch_intent_id: &str,
    claim_token: &str,
) -> Result<ManagedAgentSnapshot, TaskBoardWorkerStartError> {
    let session_id = applied.session_id.clone();
    let worker_id = managed_worker_id(applied, dispatch_intent_id);
    let _guard = state
        .managed_agent_mutation_locks
        .lock(&session_id, &worker_id)
        .await;
    start_worker_for_applied_task_in_lane(
        state,
        applied,
        dispatch_intent_id,
        claim_token,
        &worker_id,
    )
    .await
}

async fn start_worker_for_applied_task_in_lane(
    state: &DaemonHttpState,
    applied: &DispatchAppliedTask,
    dispatch_intent_id: &str,
    claim_token: &str,
    worker_id: &str,
) -> Result<ManagedAgentSnapshot, TaskBoardWorkerStartError> {
    // Keep this deterministic probe ahead of every mutable preflight. A claim
    // reclaimed after an uncertain start may already own this exact worker;
    // current item or admission drift cannot safely reject it first.
    let existing = probe_existing_worker(state, applied, worker_id)
        .await
        .map_err(TaskBoardWorkerStartError::uncertain)?;
    if let Some(snapshot) = existing {
        return recover_same_applied_worker(snapshot, applied)
            .map_err(TaskBoardWorkerStartError::uncertain);
    }
    // Fail-closed recheck at the shared worker-start seam: this guards the
    // claim+start path used by both the route executor and the recovery loop, so
    // an already-prepared intent cannot start while the kill switch is engaged.
    // Transport-agnostic because it runs before stdio/bridge selection.
    ensure_spawn_kill_switch_clear(state, &applied.board_item_id).await?;
    crate::daemon::service::validate_read_only_workflow_launch(
        require_async_db(state, "read-only workflow start validation")?,
        applied,
    )
    .await?;
    #[cfg(test)]
    start_authorization_test_support::pause_before_final_authorization().await;
    // Keep the transaction-backed admission and item-revision fence immediately before the
    // external start. A post-commit mutation still follows the existing uncertain-start and
    // compensation model, but an edit completed before this boundary cannot launch stale work.
    require_async_db(state, "task-board worker admission check")?
        .validate_task_board_dispatch_admission_start(
            dispatch_intent_id,
            claim_token,
            launch_capability(applied.item.agent_mode),
            applied
                .read_only_workflow
                .as_ref()
                .map(|launch| (launch.prepared_item_revision, launch.configuration_revision)),
        )
        .await?;
    start_or_recover_worker(state, applied, dispatch_intent_id, worker_id).await
}

async fn start_or_recover_worker(
    state: &DaemonHttpState,
    applied: &DispatchAppliedTask,
    dispatch_intent_id: &str,
    worker_id: &str,
) -> Result<ManagedAgentSnapshot, TaskBoardWorkerStartError> {
    let start_error = match start_worker_by_mode(state, applied, dispatch_intent_id).await {
        Ok(snapshot) => return Ok(snapshot),
        Err(error) => error,
    };
    let probe = probe_existing_worker(state, applied, worker_id).await;
    resolve_start_failure(start_error, probe, applied)
}

fn resolve_start_failure(
    start_error: CliError,
    probe: Result<Option<ManagedAgentSnapshot>, CliError>,
    applied: &DispatchAppliedTask,
) -> Result<ManagedAgentSnapshot, TaskBoardWorkerStartError> {
    match probe {
        Ok(Some(snapshot)) => recover_same_applied_worker(snapshot, applied)
            .map_err(TaskBoardWorkerStartError::uncertain),
        Ok(None) => Err(TaskBoardWorkerStartError::from(start_error)),
        Err(probe_error) => Err(TaskBoardWorkerStartError::uncertain_after_start(
            &start_error,
            &probe_error,
        )),
    }
}

#[cfg(test)]
async fn begin_worker_compensation(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    applied: &DispatchAppliedTask,
    dispatch_intent_id: &str,
    claim_token: &str,
    reason: &str,
) -> Result<(), CliError> {
    compensate_worker_for_applied_task(
        state,
        db,
        applied,
        dispatch_intent_id,
        claim_token,
        Some(reason),
    )
    .await
}

pub(crate) async fn resume_worker_compensation(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    applied: &DispatchAppliedTask,
    dispatch_intent_id: &str,
    claim_token: &str,
) -> Result<(), CliError> {
    compensate_worker_for_applied_task(state, db, applied, dispatch_intent_id, claim_token, None)
        .await
}

async fn compensate_worker_for_applied_task(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    applied: &DispatchAppliedTask,
    dispatch_intent_id: &str,
    claim_token: &str,
    reason: Option<&str>,
) -> Result<(), CliError> {
    let session_id = applied.session_id.clone();
    let managed_worker_id = managed_worker_id(applied, dispatch_intent_id);
    let _guard = state
        .managed_agent_mutation_locks
        .lock(&session_id, &managed_worker_id)
        .await;
    if let Some(reason) = reason {
        db.begin_task_board_dispatch_compensation(
            dispatch_intent_id,
            claim_token,
            &managed_worker_id,
            reason,
        )
        .await?;
    } else {
        db.renew_task_board_dispatch_claim(dispatch_intent_id, claim_token)
            .await?;
    }
    stop_worker_in_lane(state, applied, managed_worker_id).await
}

async fn stop_worker_in_lane(
    state: &DaemonHttpState,
    applied: &DispatchAppliedTask,
    managed_worker_id: String,
) -> Result<(), CliError> {
    let worker_id = managed_worker_id.clone();
    let result = if applied.item.agent_mode == AgentMode::Interactive {
        run_terminal_agent_blocking(state, "task-board worker compensation", move |manager| {
            manager.stop(&managed_worker_id)
        })
        .await
        .map(|_| ())
    } else {
        run_codex_agent_blocking(state, "task-board worker compensation", move |controller| {
            controller.stop(&managed_worker_id)
        })
        .await
        .map(|_| ())
    };
    match result {
        Ok(()) => Ok(()),
        Err(error) if exact_worker_not_found(&error, applied.item.agent_mode, &worker_id) => Ok(()),
        Err(error) => Err(error),
    }
}

async fn probe_existing_worker(
    state: &DaemonHttpState,
    applied: &DispatchAppliedTask,
    worker_id: &str,
) -> Result<Option<ManagedAgentSnapshot>, CliError> {
    let result = if applied.item.agent_mode == AgentMode::Interactive {
        let worker_id = worker_id.to_string();
        run_terminal_agent_blocking(state, "task-board worker lookup", move |manager| {
            manager.get(&worker_id).map(ManagedAgentSnapshot::Terminal)
        })
        .await
    } else {
        let worker_id = worker_id.to_string();
        run_codex_agent_blocking(state, "task-board worker lookup", move |controller| {
            controller.run(&worker_id).map(ManagedAgentSnapshot::Codex)
        })
        .await
    };
    match result {
        Ok(snapshot) => Ok(Some(snapshot)),
        Err(error) if exact_worker_not_found(&error, applied.item.agent_mode, worker_id) => {
            Ok(None)
        }
        Err(error) => Err(error),
    }
}

fn exact_worker_not_found(error: &CliError, mode: AgentMode, worker_id: &str) -> bool {
    if error.code() != "KSRCLI090" {
        return false;
    }
    let expected = if mode == AgentMode::Interactive {
        format!("session not active: terminal agent '{worker_id}' not found")
    } else {
        format!("session not active: codex run '{worker_id}' not found")
    };
    error.message() == expected
}

fn recover_same_applied_worker(
    snapshot: ManagedAgentSnapshot,
    applied: &DispatchAppliedTask,
) -> Result<ManagedAgentSnapshot, CliError> {
    if snapshot.session_id() != applied.session_id {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "managed worker '{}' belongs to session '{}', not reclaimed session '{}'",
            snapshot.agent_id(),
            snapshot.session_id(),
            applied.session_id,
        ))
        .into());
    }
    let Some(launch) = applied.read_only_workflow.as_ref() else {
        return Ok(snapshot);
    };
    if validate_task_board_read_only_run_context(&launch.run_context).is_err()
        || launch.run_context.session_id != applied.session_id
    {
        return Err(read_only_recovery_conflict(snapshot.agent_id()));
    }
    let ManagedAgentSnapshot::Codex(run) = &snapshot else {
        return Err(read_only_recovery_conflict(snapshot.agent_id()));
    };
    let expected_request = codex_worker_request(applied, &run.run_id);
    let worktree_matches = run.project_dir == launch.run_context.worktree;
    let matches = run.board_item_id.as_deref() == Some(applied.board_item_id.as_str())
        && run.workflow_execution_id == applied.item.workflow.execution_id
        && run.task_id.is_none()
        && run.mode == expected_request.mode
        && run.prompt == expected_request.prompt
        && run.model == expected_request.model
        && run.effort == expected_request.effort;
    if matches && worktree_matches {
        Ok(snapshot)
    } else {
        Err(read_only_recovery_conflict(&run.run_id))
    }
}

fn read_only_recovery_conflict(worker_id: &str) -> CliError {
    CliErrorKind::session_agent_conflict(format!(
        "managed worker '{worker_id}' contradicts its frozen read-only workflow request"
    ))
    .into()
}

async fn start_worker_by_mode(
    state: &DaemonHttpState,
    applied: &DispatchAppliedTask,
    dispatch_intent_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    match applied.item.agent_mode {
        AgentMode::Interactive => {
            start_interactive_worker(state, applied, dispatch_intent_id).await
        }
        AgentMode::Headless | AgentMode::Planning | AgentMode::Evaluate => {
            start_codex_worker(state, applied, dispatch_intent_id).await
        }
    }
}

/// Block the worker start when the persisted spawn kill switch is engaged. The
/// caller (route executor or recovery loop) surfaces the error so the intent
/// stays unstarted instead of launching a worker the operator has halted.
async fn ensure_spawn_kill_switch_clear(
    state: &DaemonHttpState,
    board_item_id: &str,
) -> Result<(), CliError> {
    let db = require_async_db(state, "task-board worker start kill-switch check")?;
    let workspace = db.load_policy_workspace().await?;
    if workspace.is_some_and(|workspace| workspace.spawn_kill_switch) {
        warn_kill_switch_at_start(board_item_id);
        return Err(CliErrorKind::invalid_transition(
            "spawn kill switch engaged; worker start refused".to_string(),
        )
        .into());
    }
    Ok(())
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing::warn! macro expands into a chain clippy reads as branchy"
)]
fn warn_kill_switch_at_start(board_item_id: &str) {
    tracing::warn!(
        target: "harness::task_board",
        board_item_id = %board_item_id,
        "spawn kill switch engaged at worker start; refusing to launch worker",
    );
}

async fn start_codex_worker(
    state: &DaemonHttpState,
    applied: &DispatchAppliedTask,
    dispatch_intent_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    let session_id = applied.session_id.clone();
    let run_id = codex_worker_id(dispatch_intent_id);
    let request = codex_worker_request(applied, &run_id);
    run_codex_agent_blocking(state, "task-board worker start", move |controller| {
        controller
            .start_run_with_id(&session_id, &request, run_id)
            .map(ManagedAgentSnapshot::Codex)
    })
    .await
}

async fn start_interactive_worker(
    state: &DaemonHttpState,
    applied: &DispatchAppliedTask,
    dispatch_intent_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    let session_id = applied.session_id.clone();
    let tui_id = terminal_worker_id(dispatch_intent_id);
    let request = terminal_worker_request(applied, &tui_id);
    run_terminal_agent_blocking(state, "task-board worker start", move |manager| {
        manager
            .start_with_id(&session_id, &request, tui_id)
            .map(ManagedAgentSnapshot::Terminal)
    })
    .await
}

const fn launch_capability(mode: AgentMode) -> Option<TaskBoardLaunchCapability> {
    match mode {
        AgentMode::Planning | AgentMode::Evaluate => {
            Some(TaskBoardLaunchCapability::ReportReadOnly)
        }
        AgentMode::Headless => Some(TaskBoardLaunchCapability::WorkspaceWrite),
        AgentMode::Interactive => None,
    }
}

fn codex_worker_id(dispatch_intent_id: &str) -> String {
    format!("codex-{dispatch_intent_id}")
}

fn terminal_worker_id(dispatch_intent_id: &str) -> String {
    format!("agent-tui-{dispatch_intent_id}")
}

pub(crate) fn managed_worker_id(applied: &DispatchAppliedTask, dispatch_intent_id: &str) -> String {
    if applied.item.agent_mode == AgentMode::Interactive {
        terminal_worker_id(dispatch_intent_id)
    } else {
        codex_worker_id(dispatch_intent_id)
    }
}

pub(crate) fn managed_admission_owner_id(
    applied: &DispatchAppliedTask,
    dispatch_intent_id: &str,
) -> String {
    applied
        .read_only_workflow
        .as_ref()
        .and(applied.item.workflow.execution_id.as_deref())
        .map_or_else(
            || managed_worker_id(applied, dispatch_intent_id),
            crate::daemon::db::workflow_owner,
        )
}

pub(crate) fn rendered_worker_prompt(
    applied: &DispatchAppliedTask,
    dispatch_intent_id: &str,
) -> String {
    let managed_run_id = managed_worker_id(applied, dispatch_intent_id);
    worker_prompt(applied, &managed_run_id)
}

#[cfg(test)]
#[path = "task_board_managed_agents_test_support.rs"]
mod test_support;

#[cfg(test)]
#[path = "task_board_managed_agents/start_authorization_test_support.rs"]
mod start_authorization_test_support;

#[cfg(test)]
#[path = "task_board_managed_agents/tests.rs"]
mod tests;

#[cfg(test)]
#[path = "task_board_managed_agents/read_only_start_revision_tests.rs"]
mod read_only_start_revision_tests;
