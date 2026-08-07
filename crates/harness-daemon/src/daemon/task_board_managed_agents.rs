use std::path::PathBuf;
use std::time::Duration;

use tokio::task::{JoinHandle, spawn_blocking};
use tokio::time::sleep;

use crate::daemon::db::task_board::prelude::*;
use crate::daemon::db::workflow_owner;
use crate::daemon::db_handle::AsyncDaemonDbHandle;
use crate::daemon::http::{
    DaemonHttpState, require_async_db, run_codex_agent_blocking, run_terminal_agent_blocking,
};
use crate::daemon::agent_tui::WorkspaceTerminalOwner;
use crate::daemon::protocol::ManagedAgentSnapshot;
use crate::daemon::reviews_store::PolicyGraphQueries;
use crate::daemon::service::workspace_checkout;
use crate::task_board::{
    AgentMode, DispatchAppliedTask, TaskBoardLaunchCapability, codex_worker_id, managed_worker_id,
    terminal_worker_id,
};
use harness_daemon_db_queries::{
    AsyncAgentWorkingCopyQueries, WorkspaceManagedAgentKind, WorkspaceMemberRegistration,
};
use harness_kernel::errors::{CliError, CliErrorKind};

const DISPATCH_CLAIM_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(10);
const DISPATCH_WORKER_RUNTIME: &str = "codex";

mod requests;
use requests::{codex_worker_request, terminal_worker_request};

mod workflow_launch;
use workflow_launch::{validate_recovered_workflow_worker, validate_workflow_launch};

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
    db: AsyncDaemonDbHandle,
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
    let owner = worker_lock_owner(applied);
    let worker_id = managed_worker_id(applied, dispatch_intent_id);
    let _guard = state
        .managed_agent_mutation_locks
        .lock(&owner, &worker_id)
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
        return recover_same_applied_worker(snapshot, applied, worker_id)
            .map_err(TaskBoardWorkerStartError::uncertain);
    }
    // Fail-closed recheck at the shared worker-start seam: this guards the
    // claim+start path used by both the route executor and the recovery loop, so
    // an already-prepared intent cannot start while the kill switch is engaged.
    // Transport-agnostic because it runs before stdio/bridge selection.
    ensure_spawn_kill_switch_clear(state, &applied.board_item_id).await?;
    let workflow_revision_fence = validate_workflow_launch(state, applied).await?;
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
            workflow_revision_fence,
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
    resolve_start_failure(start_error, probe, applied, worker_id)
}

fn resolve_start_failure(
    start_error: CliError,
    probe: Result<Option<ManagedAgentSnapshot>, CliError>,
    applied: &DispatchAppliedTask,
    worker_id: &str,
) -> Result<ManagedAgentSnapshot, TaskBoardWorkerStartError> {
    match probe {
        Ok(Some(snapshot)) => recover_same_applied_worker(snapshot, applied, worker_id)
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
    db: &AsyncDaemonDbHandle,
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
    db: &AsyncDaemonDbHandle,
    applied: &DispatchAppliedTask,
    dispatch_intent_id: &str,
    claim_token: &str,
) -> Result<(), CliError> {
    compensate_worker_for_applied_task(state, db, applied, dispatch_intent_id, claim_token, None)
        .await
}

async fn compensate_worker_for_applied_task(
    state: &DaemonHttpState,
    db: &AsyncDaemonDbHandle,
    applied: &DispatchAppliedTask,
    dispatch_intent_id: &str,
    claim_token: &str,
    reason: Option<&str>,
) -> Result<(), CliError> {
    let owner = worker_lock_owner(applied);
    let managed_worker_id = managed_worker_id(applied, dispatch_intent_id);
    let _guard = state
        .managed_agent_mutation_locks
        .lock(&owner, &managed_worker_id)
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
    stop_worker_in_lane(state, applied, managed_worker_id).await?;
    // Only after the runtime is down: releasing while a worker is still shutting
    // down would let the next dispatch claim a directory this one is still in.
    release_worker_workspace_checkout(
        db,
        applied,
        reason.unwrap_or("task-board dispatch compensated"),
    )
    .await;
    Ok(())
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
    worker_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    // A workspace-owned runtime reports its workspace where a session id would
    // go, and a standalone Codex run reports its own run id. Both are the owner
    // the reclaim has to match; comparing anything else would hand this dispatch
    // a worker that belongs to another one.
    let expected = applied_worker_owner(applied, worker_id);
    if !expected
        .iter()
        .any(|owner| owner.as_str() == snapshot.session_id())
    {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "managed worker '{}' belongs to '{}', not reclaimed owner '{}'",
            snapshot.agent_id(),
            snapshot.session_id(),
            expected.join("' or '"),
        ))
        .into());
    }
    validate_recovered_workflow_worker(&snapshot, applied)?;
    Ok(snapshot)
}

/// Record the started worker as a member of its workspace team.
///
/// The daemon started this process, so it registers the membership itself
/// rather than waiting for the agent to announce itself the way a Session
/// auto-join does. Idempotent on the managed identity, so a reclaimed start
/// updates the existing member instead of adding a second one.
pub(crate) async fn join_worker_to_workspace(
    db: &AsyncDaemonDbHandle,
    applied: &DispatchAppliedTask,
    worker_id: &str,
) -> Result<(), CliError> {
    let Some(workspace_id) = applied.workspace_id.clone() else {
        return Ok(());
    };
    let kind = if applied.item.agent_mode == AgentMode::Interactive {
        WorkspaceManagedAgentKind::Terminal
    } else {
        WorkspaceManagedAgentKind::Codex
    };
    db.register_workspace_managed_member(&WorkspaceMemberRegistration {
        workspace_id,
        kind,
        managed_agent_id: worker_id.to_string(),
        // Both dispatch modes run Codex today - the terminal one through a PTY,
        // the headless one through the controller - so the runtime family is the
        // same and only the managed kind above tells them apart.
        runtime_kind: DISPATCH_WORKER_RUNTIME.to_string(),
        display_name: format!("Task Board: {}", applied.item.title),
        assignment_id: Some(applied.work_item_id.clone()),
    })
    .await
    .map(|_| ())
}

/// Return a failed dispatch's checkout to the pool and remove it from disk.
///
/// Best effort by design: compensation has already stopped the runtime and
/// finalized the claim, and a checkout that cannot be released is a leaked
/// directory rather than a reason to fail the compensation that just succeeded.
///
/// The row is released first and only once - `release_agent_working_copy`
/// reports whether this call was the one that claimed the cleanup - so two
/// racing compensations cannot both start removing the same worktree.
pub(crate) async fn release_worker_workspace_checkout(
    db: &AsyncDaemonDbHandle,
    applied: &DispatchAppliedTask,
    reason: &str,
) {
    let Some(working_copy_id) = applied.working_copy_id.as_deref() else {
        return;
    };
    let recorded = match db.load_agent_working_copy(working_copy_id).await {
        Ok(recorded) => recorded,
        Err(error) => {
            warn_checkout_cleanup(&applied.board_item_id, working_copy_id, &error);
            return;
        }
    };
    match db.release_agent_working_copy(working_copy_id, reason).await {
        Ok(true) => {}
        Ok(false) => return,
        Err(error) => {
            warn_checkout_cleanup(&applied.board_item_id, working_copy_id, &error);
            return;
        }
    }
    let Some(recorded) = recorded else {
        return;
    };
    let layout = workspace_checkout::recorded_layout(&recorded.project_name, working_copy_id);
    let origin = PathBuf::from(recorded.origin_path);
    let _ = spawn_blocking(move || {
        workspace_checkout::discard_workspace_checkout(&origin, &layout);
    })
    .await;
}

fn warn_checkout_cleanup(board_item_id: &str, working_copy_id: &str, error: &CliError) {
    tracing::warn!(
        board_item_id,
        working_copy_id,
        %error,
        "compensated dispatch left its working copy recorded as live"
    );
}

/// The lane a worker's start and compensation serialize on. Keyed by whichever
/// owner the dispatch actually has, so two dispatches in one workspace still
/// contend and a legacy dispatch keeps contending on its Session.
fn worker_lock_owner(applied: &DispatchAppliedTask) -> String {
    applied
        .workspace_id
        .clone()
        .or_else(|| applied.session_id.clone())
        .unwrap_or_else(|| applied.board_item_id.clone())
}

/// Owner identities a reclaimed worker may legitimately report.
///
/// A workspace-owned Codex run names itself, because `start_standalone_run_with_id`
/// has no owner to name and stamps the run id where a session id would go; the
/// terminal names its workspace. A legacy dispatch accepts only its Session.
fn applied_worker_owner(applied: &DispatchAppliedTask, worker_id: &str) -> Vec<String> {
    let mut owners = Vec::new();
    if let Some(workspace_id) = applied.workspace_id.clone() {
        owners.push(workspace_id);
        owners.push(worker_id.to_string());
    }
    if let Some(session_id) = applied.session_id.clone() {
        owners.push(session_id);
    }
    owners
}

async fn start_worker_by_mode(
    state: &DaemonHttpState,
    applied: &DispatchAppliedTask,
    dispatch_intent_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    let snapshot = match applied.item.agent_mode {
        AgentMode::Interactive => {
            start_interactive_worker(state, applied, dispatch_intent_id).await
        }
        AgentMode::Headless | AgentMode::Planning | AgentMode::Evaluate => {
            start_codex_worker(state, applied, dispatch_intent_id).await
        }
    }?;
    crate::daemon::automation_kill_switch::fence_started_managed_agent(state, snapshot).await
}

/// Block the worker start when the persisted automation kill switch is engaged. The
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
            "automation kill switch engaged; worker start refused".to_string(),
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
        "automation kill switch engaged at worker start; refusing to launch worker",
    );
}

async fn start_codex_worker(
    state: &DaemonHttpState,
    applied: &DispatchAppliedTask,
    dispatch_intent_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    let run_id = codex_worker_id(dispatch_intent_id);
    let request = codex_worker_request(applied, &run_id)?;
    if applied.workspace_id.is_some() {
        // No owning Session, so the run identifies itself: `start_standalone_run_with_id`
        // stamps the run id where a session id would go and takes the checkout
        // directly, which is exactly what a workspace-owned worker has.
        let project_dir = worker_checkout(applied)?;
        return run_codex_agent_blocking(state, "task-board worker start", move |controller| {
            controller
                .start_standalone_run_with_id(&project_dir, &request, run_id)
                .map(ManagedAgentSnapshot::Codex)
        })
        .await;
    }
    let session_id = legacy_session_id(applied)?;
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
    let tui_id = terminal_worker_id(dispatch_intent_id);
    let request = terminal_worker_request(applied, &tui_id)?;
    if let Some(workspace_id) = applied.workspace_id.clone() {
        let project_dir = worker_checkout(applied)?;
        return run_terminal_agent_blocking(state, "task-board worker start", move |manager| {
            manager
                .start_in_workspace_with_id(
                    &WorkspaceTerminalOwner {
                        workspace_id: &workspace_id,
                        project_dir: &project_dir,
                    },
                    &request,
                    tui_id,
                )
                .map(ManagedAgentSnapshot::Terminal)
        })
        .await;
    }
    let session_id = legacy_session_id(applied)?;
    run_terminal_agent_blocking(state, "task-board worker start", move |manager| {
        manager
            .start_with_id(&session_id, &request, tui_id)
            .map(ManagedAgentSnapshot::Terminal)
    })
    .await
}

/// The checkout a workspace-owned worker runs in. Completion writes it onto the
/// ticket, so an applied task missing it never had a working copy and must not
/// be started against whatever directory the daemon happens to be in.
fn worker_checkout(applied: &DispatchAppliedTask) -> Result<String, CliError> {
    applied.item.workflow.worktree.clone().ok_or_else(|| {
        CliErrorKind::workflow_io(format!(
            "task-board item '{}' has no working copy to start its worker in",
            applied.board_item_id
        ))
        .into()
    })
}

fn legacy_session_id(applied: &DispatchAppliedTask) -> Result<String, CliError> {
    applied.session_id.clone().ok_or_else(|| {
        CliErrorKind::workflow_io(format!(
            "task-board dispatch for item '{}' has neither a workspace nor a Session owner",
            applied.board_item_id
        ))
        .into()
    })
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

pub(crate) fn managed_admission_owner_id(
    applied: &DispatchAppliedTask,
    dispatch_intent_id: &str,
) -> String {
    let workflow = applied.read_only_workflow.is_some() || applied.write_workflow.is_some();
    if workflow && let Some(execution_id) = applied.item.workflow.execution_id.as_deref() {
        workflow_owner(execution_id)
    } else {
        managed_worker_id(applied, dispatch_intent_id)
    }
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

#[cfg(test)]
#[path = "task_board_managed_agents/workflow_prepared_terminal_started_tests.rs"]
mod workflow_prepared_terminal_started_tests;
#[cfg(test)]
#[path = "task_board_managed_agents/workflow_prepared_terminal_tests.rs"]
mod workflow_prepared_terminal_tests;
