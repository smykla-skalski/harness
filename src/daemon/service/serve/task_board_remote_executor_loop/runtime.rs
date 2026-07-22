//! Deterministic Codex runtime actions and evidence validation for remote workers.

use std::path::Path;

use crate::daemon::db::{AsyncDaemonDb, TaskBoardRemoteExecutorStartIoPermit};
use crate::daemon::http::{DaemonHttpState, run_codex_agent_blocking};
use crate::daemon::protocol::{CodexRunRequest, CodexRunSnapshot, CodexRunStatus};
use crate::daemon::task_board_remote_transport::wire::RemoteOfferRequest;
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::TaskBoardRemoteAssignmentState;

use super::RemoteWorkerIdentity;

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

/// A fully prepared executor action. A fresh external Codex `Start` is only
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
) -> Result<CodexRunSnapshot, CliError> {
    #[cfg(test)]
    if let Some(snapshot) = super::test_seam::execute_runtime_seam(
        db, offer, identity, action, workspace,
    )
    .await?
    {
        return Ok(snapshot);
    }
    match action {
        PreparedRemoteWorkerAction::Start(_) => {
            start_codex_run(state, identity, remote_codex_request(offer)).await
        }
        PreparedRemoteWorkerAction::Probe(_) => probe_codex_run(state, &identity.run_id).await,
    }
}

pub(super) fn remote_codex_request(offer: &RemoteOfferRequest) -> CodexRunRequest {
    offer.launch.codex_request()
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
            invalid_transition(format!("remote start window time is not canonical: {error}"))
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

pub(super) async fn stop_codex_run(
    state: &DaemonHttpState,
    run_id: &str,
) -> Result<(), CliError> {
    let run_id = run_id.to_string();
    run_codex_agent_blocking(state, "remote Task Board worker cancel", move |controller| {
        controller.stop(&run_id)
    })
    .await
    .map(|_| ())
}

pub(super) fn validate_run_snapshot(
    snapshot: &CodexRunSnapshot,
    offer: &RemoteOfferRequest,
    identity: &RemoteWorkerIdentity,
    workspace: &Path,
) -> Result<(), CliError> {
    validate_run_identity(snapshot, offer, identity)?;
    if Path::new(&snapshot.project_dir) != workspace {
        return Err(concurrent("remote Codex run uses a different executor worktree"));
    }
    Ok(())
}

pub(super) fn validate_run_identity(
    snapshot: &CodexRunSnapshot,
    offer: &RemoteOfferRequest,
    identity: &RemoteWorkerIdentity,
) -> Result<(), CliError> {
    let expected = remote_codex_request(offer);
    if snapshot.run_id != identity.run_id
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
        return Err(concurrent("remote Codex run identity mismatched"));
    }
    if snapshot
        .thread_id
        .as_deref()
        .is_some_and(|thread_id| thread_id.trim().is_empty())
    {
        return Err(concurrent("remote Codex run has a blank runtime thread id"));
    }
    Ok(())
}

pub(super) const fn worker_action(
    assignment: TaskBoardRemoteAssignmentState,
    run: Option<CodexRunStatus>,
) -> RemoteWorkerAction {
    match (assignment, run) {
        (TaskBoardRemoteAssignmentState::Claimed, None) => RemoteWorkerAction::Start,
        (TaskBoardRemoteAssignmentState::Claimed, Some(_)) => RemoteWorkerAction::Probe,
        (
            TaskBoardRemoteAssignmentState::Started
            | TaskBoardRemoteAssignmentState::Running,
            Some(_),
        ) => RemoteWorkerAction::Probe,
        (TaskBoardRemoteAssignmentState::Cancelled, Some(status)) if status.is_active() => {
            RemoteWorkerAction::Cancel
        }
        (TaskBoardRemoteAssignmentState::Unknown, Some(status)) if status.is_active() => {
            RemoteWorkerAction::Cancel
        }
        _ => RemoteWorkerAction::Hold,
    }
}

fn concurrent(message: &'static str) -> CliError {
    CliErrorKind::concurrent_modification(message.to_string()).into()
}

fn invalid_transition(message: impl Into<String>) -> CliError {
    CliErrorKind::invalid_transition(message.into()).into()
}
