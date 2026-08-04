//! Deterministic runtime actions and evidence validation for remote workers.

use std::future::Future;
use std::path::Path;
use std::pin::Pin;

use crate::agents::turn::{AgentTurnRequest, AgentTurnRuntime};
use crate::daemon::agent_acp::{OpenRouterAgentTurnRuntime, OpenRouterRunCorrelation};
use crate::daemon::db::{
    AsyncDaemonDb, TaskBoardRemoteExecutorRun, TaskBoardRemoteExecutorStartIoPermit,
    TaskBoardRemoteRunStatus,
};
use crate::daemon::http::{DaemonHttpState, run_codex_agent_blocking};
use crate::daemon::protocol::{CodexRunRequest, CodexRunSnapshot};
use crate::task_board::TaskBoardRemoteAssignmentState;
use crate::task_board::remote_wire::wire::RemoteOfferRequest;
use harness_kernel::errors::{CliError, CliErrorKind};

use super::RemoteWorkerIdentity;
use crate::daemon::db::prelude::*;
use crate::daemon::db::task_board::prelude::*;

/// The action the loop plans from durable state before it has authority to
/// execute it. Only [`Start`](Self::Start)/[`Probe`](Self::Probe) can reach a
/// prepared executable action; `Cancel`/`Hold` are handled without executor I/O.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum RemoteWorkerAction {
    Start,
    Probe,
    Cancel,
    Hold,
}

/// A fully prepared executor action. A fresh external runtime `Start` is only
/// representable while carrying the [`TaskBoardRemoteExecutorStartIoPermit`]
/// that this process just acquired, so `execute_and_reconcile` can never launch
/// a worker before requiring authority. `Probe` re-reads the deterministic run
/// and never launches; it carries the persisted permit when recovering a
/// Claimed generation whose run is not yet adopted, otherwise none.
pub(super) enum PreparedRemoteWorkerAction {
    Start(TaskBoardRemoteExecutorStartIoPermit),
    Probe(Option<TaskBoardRemoteExecutorStartIoPermit>),
}

impl PreparedRemoteWorkerAction {
    pub(super) fn permit(&self) -> Option<&TaskBoardRemoteExecutorStartIoPermit> {
        match self {
            Self::Start(permit) => Some(permit),
            Self::Probe(permit) => permit.as_ref(),
        }
    }

    /// The acquired permit only when this action performs a fresh external Start.
    /// A `Probe` never launched, so it returns `None` even while carrying a
    /// replayed permit: only a fresh Start can leave an ambiguous no-run failure.
    pub(super) fn fresh_start_permit(&self) -> Option<&TaskBoardRemoteExecutorStartIoPermit> {
        match self {
            Self::Start(permit) => Some(permit),
            Self::Probe(_) => None,
        }
    }
}

pub(super) async fn execute_remote_worker_action(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    offer: &RemoteOfferRequest,
    identity: &RemoteWorkerIdentity,
    action: &PreparedRemoteWorkerAction,
    workspace: &Path,
) -> Result<TaskBoardRemoteExecutorRun, CliError> {
    #[cfg(test)]
    if let Some(snapshot) =
        super::test_seam::execute_runtime_seam(db, offer, identity, action, workspace).await?
    {
        return Ok(snapshot);
    }
    match (offer.launch.runtime.as_str(), action) {
        ("codex", PreparedRemoteWorkerAction::Start(_)) => {
            start_codex_run(state, identity, remote_run_request(offer))
                .await
                .map(TaskBoardRemoteExecutorRun::from)
        }
        ("codex", PreparedRemoteWorkerAction::Probe(_)) => probe_codex_run(state, &identity.run_id)
            .await
            .map(TaskBoardRemoteExecutorRun::from),
        ("openrouter", PreparedRemoteWorkerAction::Start(_)) => {
            start_openrouter_run(state, db, offer, identity, workspace).await
        }
        ("openrouter", PreparedRemoteWorkerAction::Probe(_)) => {
            probe_openrouter_run(state, db, offer, identity, workspace).await
        }
        (runtime, _) => Err(invalid_transition(format!(
            "unsupported remote executor runtime '{runtime}'"
        ))),
    }
}

pub(super) fn remote_run_request(offer: &RemoteOfferRequest) -> CodexRunRequest {
    offer.launch.run_request()
}

async fn start_openrouter_run(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    offer: &RemoteOfferRequest,
    identity: &RemoteWorkerIdentity,
    workspace: &Path,
) -> Result<TaskBoardRemoteExecutorRun, CliError> {
    #[cfg(test)]
    super::test_seam::record_start();
    let runtime = openrouter_runtime(state, offer, identity, workspace)?;
    runtime
        .start(AgentTurnRequest {
            prompt: offer.launch.prompt.clone(),
            requested_model: offer.launch.model.clone(),
            pull_request: None,
        })
        .await?;
    db.task_board_remote_executor_run(offer, &identity.run_id)
        .await?
        .ok_or_else(|| concurrent("remote OpenRouter Start has no durable run"))
}

async fn probe_openrouter_run(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    offer: &RemoteOfferRequest,
    identity: &RemoteWorkerIdentity,
    workspace: &Path,
) -> Result<TaskBoardRemoteExecutorRun, CliError> {
    let run = db
        .agent_turn_run(&identity.run_id)
        .await?
        .ok_or_else(|| concurrent("remote OpenRouter Probe has no durable run"))?;
    openrouter_runtime(state, offer, identity, workspace)?
        .reconcile_correlated_turn(&run)
        .await?;
    db.task_board_remote_executor_run(offer, &identity.run_id)
        .await?
        .ok_or_else(|| concurrent("remote OpenRouter Probe lost its durable run"))
}

fn openrouter_runtime(
    state: &DaemonHttpState,
    offer: &RemoteOfferRequest,
    identity: &RemoteWorkerIdentity,
    workspace: &Path,
) -> Result<OpenRouterAgentTurnRuntime, CliError> {
    let store = state.async_db.get().cloned().ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_io(
            "remote OpenRouter run needs the canonical async database",
        ))
    })?;
    Ok(OpenRouterAgentTurnRuntime::new_correlated(
        state.acp_agent_manager.clone(),
        identity.session_id.clone(),
        Some(workspace.to_string_lossy().into_owned()),
        store,
        OpenRouterRunCorrelation {
            run_id: identity.run_id.clone(),
            board_item_id: Some(offer.launch.board_item_id.clone()),
            workflow_execution_id: Some(offer.launch.workflow_execution_id.clone()),
            task_id: offer.launch.task_id.clone(),
        },
    ))
}

/// A worker Start may only be attempted while both the lease and the deadline are still
/// in the future. This is a pre-permit guard only: once the final Start-I/O permit is
/// acquired it becomes the linearization point and is never re-expired against wall clock.
pub(super) fn start_window_is_open(
    lease_expires_at: &str,
    deadline_at: &str,
    now: &str,
) -> Result<bool, CliError> {
    let now = parse_start_window_instant(now)?;
    Ok(now < parse_start_window_instant(lease_expires_at)?
        && now < parse_start_window_instant(deadline_at)?)
}

fn parse_start_window_instant(value: &str) -> Result<chrono::DateTime<chrono::Utc>, CliError> {
    chrono::DateTime::parse_from_rfc3339(value)
        .map(|instant| instant.with_timezone(&chrono::Utc))
        .map_err(|error| {
            invalid_transition(format!(
                "remote start window time is not canonical: {error}"
            ))
        })
}

async fn start_codex_run(
    state: &DaemonHttpState,
    identity: &RemoteWorkerIdentity,
    request: CodexRunRequest,
) -> Result<CodexRunSnapshot, CliError> {
    #[cfg(test)]
    super::test_seam::record_start();
    let session_id = identity.session_id.clone();
    let run_id = identity.run_id.clone();
    run_codex_agent_blocking(state, "remote Task Board worker start", move |controller| {
        controller.start_run_with_id(&session_id, &request, run_id)
    })
    .await
}

async fn probe_codex_run(
    state: &DaemonHttpState,
    run_id: &str,
) -> Result<CodexRunSnapshot, CliError> {
    let run_id = run_id.to_string();
    run_codex_agent_blocking(state, "remote Task Board worker probe", move |controller| {
        controller.run(&run_id)
    })
    .await
}

async fn stop_codex_run(state: &DaemonHttpState, run_id: &str) -> Result<(), CliError> {
    let run_id = run_id.to_string();
    run_codex_agent_blocking(
        state,
        "remote Task Board worker cancel",
        move |controller| controller.stop(&run_id),
    )
    .await
    .map(|_| ())
}

pub(super) fn stop_remote_run<'a>(
    state: &'a DaemonHttpState,
    db: &'a AsyncDaemonDb,
    run: &'a TaskBoardRemoteExecutorRun,
) -> Pin<Box<dyn Future<Output = Result<(), CliError>> + Send + 'a>> {
    Box::pin(async move {
        match run.runtime.as_str() {
            "codex" => stop_codex_run(state, &run.run_id).await,
            "openrouter" => {
                let runtime_run_id = run.runtime_thread_id.as_deref().ok_or_else(|| {
                    invalid_transition("active OpenRouter run has no provider turn id")
                })?;
                state.acp_agent_manager.stop(runtime_run_id)?;
                db.cancel_agent_turn_run(&run.run_id).await
            }
            runtime => Err(invalid_transition(format!(
                "unsupported remote executor runtime '{runtime}'"
            ))),
        }
    })
}

pub(super) fn validate_run_snapshot<S>(
    snapshot: &S,
    offer: &RemoteOfferRequest,
    identity: &RemoteWorkerIdentity,
    workspace: &Path,
) -> Result<(), CliError>
where
    S: Clone + Into<TaskBoardRemoteExecutorRun>,
{
    let snapshot = snapshot.clone().into();
    validate_run_identity(&snapshot, offer, identity)?;
    if Path::new(&snapshot.project_dir) != workspace {
        return Err(concurrent(
            "remote runtime run uses a different executor worktree",
        ));
    }
    Ok(())
}

pub(super) fn validate_run_identity<S>(
    snapshot: &S,
    offer: &RemoteOfferRequest,
    identity: &RemoteWorkerIdentity,
) -> Result<(), CliError>
where
    S: Clone + Into<TaskBoardRemoteExecutorRun>,
{
    let snapshot = snapshot.clone().into();
    let expected = remote_run_request(offer);
    if snapshot.run_id != identity.run_id
        || snapshot.runtime != offer.launch.runtime
        || snapshot.session_id != identity.session_id
        || snapshot.task_id != expected.task_id
        || snapshot.board_item_id != expected.board_item_id
        || snapshot.display_name != expected.name
        || snapshot.prompt != expected.prompt
        || snapshot.mode != expected.mode
        || snapshot.workflow_execution_id != expected.workflow_execution_id
        || snapshot.model != expected.model
        || snapshot.effort != expected.effort
    {
        return Err(concurrent("remote runtime run identity mismatched"));
    }
    if snapshot
        .runtime_thread_id
        .as_deref()
        .is_some_and(|thread_id| thread_id.trim().is_empty())
    {
        return Err(concurrent(
            "remote runtime run has a blank runtime thread id",
        ));
    }
    Ok(())
}

pub(super) const fn worker_action(
    assignment: TaskBoardRemoteAssignmentState,
    run: Option<TaskBoardRemoteRunStatus>,
) -> RemoteWorkerAction {
    match (assignment, run) {
        (TaskBoardRemoteAssignmentState::Claimed, None) => RemoteWorkerAction::Start,
        (
            TaskBoardRemoteAssignmentState::Claimed
            | TaskBoardRemoteAssignmentState::Started
            | TaskBoardRemoteAssignmentState::Running,
            Some(_),
        ) => RemoteWorkerAction::Probe,
        (
            TaskBoardRemoteAssignmentState::Cancelled | TaskBoardRemoteAssignmentState::Unknown,
            Some(status),
        ) if status.is_active() => RemoteWorkerAction::Cancel,
        _ => RemoteWorkerAction::Hold,
    }
}

fn concurrent(message: &'static str) -> CliError {
    CliErrorKind::concurrent_modification(message.to_string()).into()
}

fn invalid_transition(message: impl Into<String>) -> CliError {
    CliErrorKind::invalid_transition(message.into()).into()
}
