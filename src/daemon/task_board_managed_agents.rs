use std::time::Duration;

use tokio::task::JoinHandle;
use tokio::time::sleep;

use crate::daemon::agent_tui::AgentTuiStartRequest;
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::http::{
    DaemonHttpState, require_async_db, run_codex_agent_blocking, run_terminal_agent_blocking,
};
use crate::daemon::protocol::{CodexRunMode, CodexRunRequest, ManagedAgentSnapshot};
use crate::errors::{CliError, CliErrorKind};
use crate::session::types::{CONTROL_PLANE_ACTOR_ID, SessionRole};
use crate::task_board::{
    AgentMode, DispatchAppliedTask, TaskBoardItem, TaskBoardLaunchCapability, WorkerPromptContext,
    render_worker_prompt,
};

const DEFAULT_INTERACTIVE_RUNTIME: &str = "codex";
const DISPATCH_CLAIM_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(10);

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

pub(crate) async fn start_worker_for_applied_task(
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
    // Keep this deterministic probe ahead of every mutable preflight. A claim
    // reclaimed after an uncertain start may already own this exact worker;
    // current item or admission drift cannot safely reject it first.
    let existing = probe_existing_worker(state, applied, &worker_id)
        .await
        .map_err(TaskBoardWorkerStartError::uncertain)?;
    if let Some(snapshot) = existing {
        return recover_same_session_worker(snapshot, &session_id)
            .map_err(TaskBoardWorkerStartError::uncertain);
    }
    // Fail-closed recheck at the shared worker-start seam: this guards the
    // claim+start path used by both the route executor and the recovery loop, so
    // an already-prepared intent cannot start while the kill switch is engaged.
    // Transport-agnostic because it runs before stdio/bridge selection.
    ensure_spawn_kill_switch_clear(state, &applied.board_item_id).await?;
    require_async_db(state, "task-board worker admission check")?
        .validate_task_board_dispatch_admission_start(
            dispatch_intent_id,
            claim_token,
            launch_capability(applied.item.agent_mode),
        )
        .await?;
    start_or_recover_worker(state, applied, dispatch_intent_id, &worker_id, &session_id).await
}

async fn start_or_recover_worker(
    state: &DaemonHttpState,
    applied: &DispatchAppliedTask,
    dispatch_intent_id: &str,
    worker_id: &str,
    session_id: &str,
) -> Result<ManagedAgentSnapshot, TaskBoardWorkerStartError> {
    let start_error = match start_worker_by_mode(state, applied, dispatch_intent_id).await {
        Ok(snapshot) => return Ok(snapshot),
        Err(error) => error,
    };
    let probe = probe_existing_worker(state, applied, worker_id).await;
    resolve_start_failure(start_error, probe, session_id)
}

fn resolve_start_failure(
    start_error: CliError,
    probe: Result<Option<ManagedAgentSnapshot>, CliError>,
    session_id: &str,
) -> Result<ManagedAgentSnapshot, TaskBoardWorkerStartError> {
    match probe {
        Ok(Some(snapshot)) => recover_same_session_worker(snapshot, session_id)
            .map_err(TaskBoardWorkerStartError::uncertain),
        Ok(None) => Err(TaskBoardWorkerStartError::from(start_error)),
        Err(probe_error) => Err(TaskBoardWorkerStartError::uncertain_after_start(
            &start_error,
            &probe_error,
        )),
    }
}

pub(crate) async fn begin_worker_compensation(
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

fn recover_same_session_worker(
    snapshot: ManagedAgentSnapshot,
    expected_session_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    if snapshot.session_id() == expected_session_id {
        return Ok(snapshot);
    }
    Err(CliErrorKind::session_agent_conflict(format!(
        "managed worker '{}' belongs to session '{}', not reclaimed session '{expected_session_id}'",
        snapshot.agent_id(),
        snapshot.session_id(),
    ))
    .into())
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

fn codex_worker_request(applied: &DispatchAppliedTask, managed_run_id: &str) -> CodexRunRequest {
    let mode = match applied.item.agent_mode {
        AgentMode::Planning | AgentMode::Evaluate => CodexRunMode::Report,
        AgentMode::Headless | AgentMode::Interactive => CodexRunMode::WorkspaceWrite,
    };
    CodexRunRequest {
        actor: Some(CONTROL_PLANE_ACTOR_ID.to_string()),
        prompt: worker_prompt(applied, managed_run_id),
        mode,
        // A newly-created task-board session has no leader yet. Requesting the
        // leader role activates that session so lifecycle checkpoints work;
        // existing sessions with a leader resolve to the worker fallback.
        role: SessionRole::Leader,
        fallback_role: Some(SessionRole::Worker),
        capabilities: worker_capabilities(&applied.item),
        name: Some(worker_name(&applied.item)),
        persona: None,
        resume_thread_id: None,
        task_id: Some(applied.work_item_id.clone()),
        board_item_id: Some(applied.board_item_id.clone()),
        workflow_execution_id: applied.item.workflow.execution_id.clone(),
        model: None,
        effort: None,
        allow_custom_model: false,
    }
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

fn terminal_worker_request(
    applied: &DispatchAppliedTask,
    managed_run_id: &str,
) -> AgentTuiStartRequest {
    AgentTuiStartRequest {
        runtime: DEFAULT_INTERACTIVE_RUNTIME.to_string(),
        role: SessionRole::Leader,
        fallback_role: Some(SessionRole::Worker),
        capabilities: worker_capabilities(&applied.item),
        name: Some(worker_name(&applied.item)),
        prompt: Some(worker_prompt(applied, managed_run_id)),
        project_dir: None,
        argv: Vec::new(),
        rows: 24,
        cols: 80,
        persona: None,
        task_id: Some(applied.work_item_id.clone()),
        board_item_id: Some(applied.board_item_id.clone()),
        workflow_execution_id: applied.item.workflow.execution_id.clone(),
        model: None,
        effort: None,
        allow_custom_model: false,
    }
}

fn worker_name(item: &TaskBoardItem) -> String {
    format!("Task Board: {}", item.title)
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

fn worker_capabilities(item: &TaskBoardItem) -> Vec<String> {
    let mut capabilities = vec![
        "task-board".to_string(),
        format!("task-board:item:{}", item.id),
    ];
    capabilities.extend(item.tags.iter().map(|tag| format!("task-board:tag:{tag}")));
    capabilities
}

fn worker_prompt(applied: &DispatchAppliedTask, managed_run_id: &str) -> String {
    render_worker_prompt(
        &applied.item,
        &WorkerPromptContext {
            board_item_id: &applied.board_item_id,
            work_item_id: &applied.work_item_id,
            worktree: applied.item.workflow.worktree.as_deref(),
            session_id: Some(&applied.session_id),
            managed_run_id: Some(managed_run_id),
            status: applied.item.status,
        },
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
#[path = "task_board_managed_agents/tests.rs"]
mod tests;
