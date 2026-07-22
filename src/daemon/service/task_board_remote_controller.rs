use std::collections::BTreeSet;
use std::future::Future;
use std::path::PathBuf;
use std::time::Duration;

use chrono::{SecondsFormat, Utc};
use futures_util::future::join_all;
use tokio::sync::Mutex;

use crate::daemon::db::{
    AsyncDaemonDb, TaskBoardRemoteAssignmentRecord, TaskBoardRemoteHostTrustFence,
    TaskBoardRemoteOfferOutcome,
};
use crate::daemon::task_board_remote_transport::controller::{
    RemoteExecutionControllerClient, RemoteExecutionControllerError,
};
use crate::errors::CliError;
use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionAttemptCas, TaskBoardExecutionAttemptRecord,
    TaskBoardExecutionPhase, TaskBoardRemoteAssignmentState, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionRecord, task_board_remote_execution_target,
};

#[path = "task_board_remote_controller/active_poll.rs"]
mod active_poll;
#[path = "task_board_remote_controller/requests.rs"]
mod requests;
#[cfg(test)]
use active_poll::poll_active_assignment_with;
#[path = "task_board_remote_controller/scan.rs"]
mod scan;
#[path = "task_board_remote_controller/source_recovery.rs"]
mod source_recovery;
#[path = "task_board_remote_controller/terminal.rs"]
mod terminal;

const CONTROLLER_CANDIDATE_LIMIT: usize = 16;
const CONTROLLER_SCAN_LIMIT: usize = 64;
const CONTROLLER_REFRESH_BUDGET: Duration = Duration::from_secs(5);
static CONTROLLER_DRIVER: Mutex<()> = Mutex::const_new(());

#[derive(Debug, Default)]
pub(crate) struct TaskBoardRemoteControllerReport {
    pub(crate) refreshed_hosts: usize,
    pub(crate) verified_assignments: usize,
    pub(crate) progressed_assignments: usize,
    pub(crate) offered_attempts: usize,
    pub(crate) scan_incomplete: bool,
    pub(crate) scan_blocked: bool,
    pub(crate) failures: Vec<String>,
    blocked_host_ids: BTreeSet<String>,
}

pub(crate) async fn drive_task_board_remote_controller(
    db: &AsyncDaemonDb,
) -> Result<TaskBoardRemoteControllerReport, CliError> {
    let driver = CONTROLLER_DRIVER.lock().await;
    let mut report = TaskBoardRemoteControllerReport::default();
    Box::pin(scan::progress_existing_assignments(db, &mut report)).await?;
    let blocked_hosts = report.blocked_host_ids.iter().cloned().collect();
    drop(driver);
    if report.scan_blocked {
        refresh_host_ids(db, &mut report, blocked_hosts).await;
        return Ok(report);
    }
    if !report.scan_incomplete {
        refresh_hosts(db, &mut report).await?;
        let _driver = CONTROLLER_DRIVER.lock().await;
        Box::pin(offer_remote_candidates(db, &mut report)).await?;
    }
    Ok(report)
}

pub(crate) async fn drive_task_board_remote_controller_before_local_work(
    db: &AsyncDaemonDb,
) -> Result<TaskBoardRemoteControllerReport, CliError> {
    let report = Box::pin(drive_task_board_remote_controller(db)).await?;
    if report.refreshed_hosts > 0
        || report.progressed_assignments > 0
        || report.offered_attempts > 0
    {
        tracing::debug!(
            refreshed_hosts = report.refreshed_hosts,
            progressed_assignments = report.progressed_assignments,
            offered_attempts = report.offered_attempts,
            "task-board remote controller progression completed"
        );
    }
    for failure in &report.failures {
        tracing::warn!(error = %failure, "task-board remote controller operation failed");
    }
    // A quarantined controller generation is a per-execution concern, not a daemon-wide
    // one. Local work is already fenced per execution by active_remote_assignment_exists_in_tx
    // (target selection and side-effect claim), so an unrelated host's transient failure must
    // not halt every dispatch, settlement, and read-only reconciliation. Surface the pending
    // verification without blocking the callers that only touch unaffected executions.
    if db
        .task_board_remote_controller_progression_is_blocked()
        .await?
    {
        tracing::debug!(
            "remote controller verification is pending; local work proceeds under the \
             per-execution active-assignment fence"
        );
    }
    Ok(report)
}

async fn refresh_hosts(
    db: &AsyncDaemonDb,
    report: &mut TaskBoardRemoteControllerReport,
) -> Result<(), CliError> {
    let settings = db.task_board_orchestrator_settings_snapshot().await?;
    let host_ids = settings
        .settings
        .execution_hosts
        .iter()
        .filter(|host| host.enabled)
        .map(|host| host.host_id.clone())
        .collect();
    refresh_host_ids(db, report, host_ids).await;
    Ok(())
}

async fn refresh_host_ids(
    db: &AsyncDaemonDb,
    report: &mut TaskBoardRemoteControllerReport,
    host_ids: Vec<String>,
) {
    let refreshes = join_all(host_ids.into_iter().map(|host_id| async move {
        let result = refresh_host(db, &host_id).await;
        (host_id, result)
    }));
    let Ok(results) = tokio::time::timeout(CONTROLLER_REFRESH_BUDGET, refreshes).await else {
        report.failures.push(format!(
            "remote host refresh exceeded its {}s cycle budget",
            CONTROLLER_REFRESH_BUDGET.as_secs()
        ));
        return;
    };
    for (host_id, result) in results {
        match result {
            Ok(()) => report.refreshed_hosts += 1,
            Err(error) => report
                .failures
                .push(format!("remote host '{host_id}' refresh failed: {error}")),
        }
    }
}

async fn refresh_host(db: &AsyncDaemonDb, host_id: &str) -> Result<(), CliError> {
    let trust = db.task_board_remote_host_trust_fence(host_id).await?;
    let client =
        RemoteExecutionControllerClient::connect(&trust).map_err(controller_database_error)?;
    client
        .refresh_observation(db)
        .await
        .map(|_| ())
        .map_err(controller_database_error)
}

async fn progress_assignment(
    db: &AsyncDaemonDb,
    assignment: TaskBoardRemoteAssignmentRecord,
) -> Result<bool, CliError> {
    let client = controller_for_assignment(db, &assignment).await?;
    match assignment.state {
        TaskBoardRemoteAssignmentState::Offered if assignment.lease_id.is_none() => {
            Box::pin(source_recovery::progress_unclaimed_offer(
                db,
                &client,
                &assignment,
            ))
            .await
        }
        TaskBoardRemoteAssignmentState::Offered => {
            let request = requests::claim_request(&assignment)?;
            Box::pin(client.claim(db, &request))
                .await
                .map(|_| true)
                .map_err(controller_database_error)
        }
        TaskBoardRemoteAssignmentState::Claimed
        | TaskBoardRemoteAssignmentState::Started
        | TaskBoardRemoteAssignmentState::Running => {
            Box::pin(active_poll::poll_active_assignment(
                db,
                &client,
                &assignment,
            ))
            .await
        }
        TaskBoardRemoteAssignmentState::Unknown => {
            Box::pin(poll_unknown_assignment(db, &client, &assignment)).await
        }
        TaskBoardRemoteAssignmentState::Completed
        | TaskBoardRemoteAssignmentState::Failed
        | TaskBoardRemoteAssignmentState::Cancelled
        | TaskBoardRemoteAssignmentState::Superseded => {
            Box::pin(terminal::finish_terminal_assignment(
                db,
                &client,
                &assignment,
            ))
            .await
        }
    }
}

async fn poll_unknown_assignment(
    db: &AsyncDaemonDb,
    client: &RemoteExecutionControllerClient,
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> Result<bool, CliError> {
    Box::pin(poll_unknown_assignment_with(
        db,
        assignment,
        |request| async move {
            Box::pin(client.status(db, &request))
                .await
                .map(|_| ())
                .map_err(controller_database_error)
        },
        |current| async move {
            Box::pin(terminal::finish_terminal_assignment(db, client, &current)).await
        },
    ))
    .await
}

async fn poll_unknown_assignment_with<Status, StatusFuture, FinishTerminal, FinishFuture>(
    db: &AsyncDaemonDb,
    assignment: &TaskBoardRemoteAssignmentRecord,
    status: Status,
    finish_terminal: FinishTerminal,
) -> Result<bool, CliError>
where
    Status: FnOnce(
        crate::daemon::task_board_remote_transport::wire::RemoteStatusRequest,
    ) -> StatusFuture,
    StatusFuture: Future<Output = Result<(), CliError>>,
    FinishTerminal: FnOnce(TaskBoardRemoteAssignmentRecord) -> FinishFuture,
    FinishFuture: Future<Output = Result<bool, CliError>>,
{
    if assignment.cleanup_completed_at.is_some() {
        return Ok(false);
    }
    if db
        .task_board_remote_settlement_receipt(&assignment.assignment_id)
        .await?
        .is_some()
    {
        return finish_terminal(assignment.clone()).await;
    }
    if !db
        .task_board_remote_assignment_has_settlement_handoff(
            &assignment.assignment_id,
            assignment.fencing_epoch,
        )
        .await?
    {
        status(requests::status_request(assignment)?).await?;
        return Ok(true);
    }
    status(requests::status_request(assignment)?).await?;
    let current = db
        .task_board_remote_assignment(&assignment.assignment_id)
        .await?
        .ok_or_else(missing_execution)?;
    if !db
        .task_board_remote_assignment_has_settlement_handoff(
            &current.assignment_id,
            current.fencing_epoch,
        )
        .await?
    {
        return Ok(true);
    }
    finish_terminal(current).await
}

async fn offer_remote_candidates(
    db: &AsyncDaemonDb,
    report: &mut TaskBoardRemoteControllerReport,
) -> Result<(), CliError> {
    let candidates = db
        .remote_candidate_task_board_workflow_executions(CONTROLLER_CANDIDATE_LIMIT)
        .await?;
    for execution in candidates {
        let Some(attempt) = remote_preparing_attempt(&execution) else {
            continue;
        };
        let Some(phase) = execution.transition.phase else {
            continue;
        };
        let now = canonical_now();
        let prior_bundle = if requests::requires_prior_bundle(&execution, phase) {
            db.task_board_remote_prior_phase_bundle(&execution, phase)
                .await?
        } else {
            None
        };
        let Some(prepared_source) =
            prepare_candidate_source(&execution, phase, prior_bundle.as_ref()).await?
        else {
            select_local_target(db, &execution, attempt, &now).await?;
            continue;
        };
        let source_repository = prepared_source.repository().to_owned();
        let host = db
            .resolve_task_board_remote_host(&execution, &source_repository, phase, "codex", &now)
            .await?;
        let Some(host) = host else {
            select_local_target(db, &execution, attempt, &now).await?;
            continue;
        };
        let Some(prepared) =
            requests::prepare_offer(&execution, attempt, &host, prepared_source, &now)?
        else {
            select_local_target(db, &execution, attempt, &now).await?;
            continue;
        };
        match Box::pin(db.offer_task_board_remote_assignment_with_source(
            &TaskBoardWorkflowExecutionCas::from(&execution),
            &crate::task_board::TaskBoardExecutionAttemptCas::from(attempt),
            &prepared.request,
            prepared.source_content.as_deref(),
            &host.config.host_id,
            &prepared.offered_at,
            &prepared.lease_expires_at,
            &prepared.deadline_at,
        ))
        .await?
        {
            TaskBoardRemoteOfferOutcome::Created(_) | TaskBoardRemoteOfferOutcome::Replayed(_) => {
                report.offered_attempts += 1;
            }
            // AcceptedReplay/Rejected carry executor-inbox receipts and are produced only by the
            // executor offer inbox, never by offer_task_board_remote_assignment_with_source
            // (Created/Replayed/Stale/Unavailable only). Fail closed rather than silently falling
            // back to local at this pre-I/O offer boundary if that provenance invariant is broken.
            TaskBoardRemoteOfferOutcome::AcceptedReplay(_)
            | TaskBoardRemoteOfferOutcome::Rejected(_) => {
                return Err(crate::errors::CliErrorKind::concurrent_modification(
                    "controller offer creation returned an executor-inbox receipt outcome",
                )
                .into());
            }
            TaskBoardRemoteOfferOutcome::Unavailable | TaskBoardRemoteOfferOutcome::Stale => {}
        }
    }
    Ok(())
}

async fn prepare_candidate_source(
    execution: &TaskBoardWorkflowExecutionRecord,
    phase: TaskBoardExecutionPhase,
    prior_bundle: Option<&crate::daemon::db::TaskBoardRemotePriorPhaseBundle>,
) -> Result<Option<requests::PreparedRemoteSource>, CliError> {
    if let Some(identity) = requests::initial_snapshot_identity(execution, phase)? {
        let worktree = PathBuf::from(identity.0);
        let repository = identity.1.to_owned();
        let revision = identity.2.to_owned();
        let exported = tokio::task::spawn_blocking(move || {
            crate::git::source_bundle_export::GitSourceBundleExportPlan::for_revision(
                &worktree, repository, revision,
            )?
            .export(crate::git::bundle_contract::MAX_REMOTE_GIT_BUNDLE_BYTES)
        })
        .await;
        return match exported {
            Ok(Ok(export)) => requests::PreparedRemoteSource::repository_snapshot(export).map(Some),
            Ok(Err(error)) => {
                tracing::warn!(%error, "portable initial remote source export is unavailable");
                Ok(None)
            }
            Err(error) => {
                tracing::warn!(%error, "portable initial remote source export task failed");
                Ok(None)
            }
        };
    }
    requests::prepare_source(execution, phase, prior_bundle)
}

async fn select_local_target(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    now: &str,
) -> Result<(), CliError> {
    db.select_task_board_local_execution_target(
        &TaskBoardWorkflowExecutionCas::from(execution),
        &TaskBoardExecutionAttemptCas::from(attempt),
        now,
    )
    .await
    .map(|_| ())
}

async fn controller_for_assignment(
    db: &AsyncDaemonDb,
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> Result<RemoteExecutionControllerClient, CliError> {
    let trust: TaskBoardRemoteHostTrustFence = db
        .task_board_remote_host_trust_fence(&assignment.host_id)
        .await?;
    RemoteExecutionControllerClient::connect(&trust).map_err(controller_database_error)
}

fn remote_preparing_attempt(
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Option<&TaskBoardExecutionAttemptRecord> {
    if !matches!(
        execution.transition.phase,
        Some(
            TaskBoardExecutionPhase::Implementation
                | TaskBoardExecutionPhase::Review
                | TaskBoardExecutionPhase::Evaluate
        )
    ) || task_board_remote_execution_target(execution).is_some()
    {
        return None;
    }
    let mut active = execution.attempts.iter().filter(|attempt| {
        matches!(
            attempt.state,
            TaskBoardAttemptState::Preparing
                | TaskBoardAttemptState::Starting
                | TaskBoardAttemptState::Running
        )
    });
    let first = active.next();
    if active.next().is_none() {
        first.filter(|attempt| attempt.state == TaskBoardAttemptState::Preparing)
    } else {
        None
    }
}

fn canonical_now() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::AutoSi, true)
}

fn controller_database_error(error: RemoteExecutionControllerError) -> CliError {
    match error {
        RemoteExecutionControllerError::Database(error) => error,
        RemoteExecutionControllerError::Transport(error) => {
            crate::errors::CliErrorKind::workflow_io(error.to_string()).into()
        }
    }
}

fn missing_execution() -> CliError {
    crate::errors::CliErrorKind::concurrent_modification(
        "remote execution disappeared during controller progression",
    )
    .into()
}

#[cfg(test)]
#[path = "task_board_remote_controller_tests.rs"]
mod tests;
