#[cfg(test)]
use std::collections::BTreeMap;
use std::future::Future;

use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{
    TaskBoardExecutionAttemptCas, TaskBoardExecutionAttemptCasOutcome,
    TaskBoardExecutionAttemptCreateOutcome, TaskBoardExecutionAttemptRecord,
    TaskBoardExecutionDiagnostic, TaskBoardPullRequestIdentity, TaskBoardRetrySchedule,
    TaskBoardWorkflowExecutionCas, TaskBoardWorkflowExecutionCasOutcome,
    TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowRevisionGuard,
};
#[cfg(test)]
use crate::task_board::{
    TaskBoardExecutionOwnership, TaskBoardWorkflowExecutionArtifacts,
    TaskBoardWorkflowExecutionCreateOutcome, TaskBoardWorkflowKind, TaskBoardWorkflowSnapshot,
    start_task_board_workflow,
};
use harness_kernel::errors::CliError;
#[cfg(test)]
use harness_kernel::errors::CliErrorKind;
use harness_task_board_workflow_execution::WorkflowExecutionStore;

struct WorkflowExecutionDb<'a>(&'a AsyncDaemonDb);

impl WorkflowExecutionStore for WorkflowExecutionDb<'_> {
    fn workflow_execution(
        &self,
        execution_id: &str,
    ) -> impl Future<Output = Result<Option<TaskBoardWorkflowExecutionRecord>, CliError>> + Send
    {
        self.0.task_board_workflow_execution(execution_id)
    }

    fn compare_and_set_workflow_execution(
        &self,
        expected: &TaskBoardWorkflowExecutionCas,
        updated: &TaskBoardWorkflowExecutionRecord,
    ) -> impl Future<Output = Result<TaskBoardWorkflowExecutionCasOutcome, CliError>> + Send {
        self.0
            .compare_and_set_task_board_workflow_execution(expected, updated)
    }

    fn create_execution_attempt(
        &self,
        proposed: &TaskBoardExecutionAttemptRecord,
    ) -> impl Future<Output = Result<TaskBoardExecutionAttemptCreateOutcome, CliError>> + Send {
        self.0.create_task_board_execution_attempt(proposed)
    }

    fn compare_and_set_execution_attempt(
        &self,
        expected: &TaskBoardExecutionAttemptCas,
        updated: &TaskBoardExecutionAttemptRecord,
    ) -> impl Future<Output = Result<TaskBoardExecutionAttemptCasOutcome, CliError>> + Send {
        self.0
            .compare_and_set_task_board_execution_attempt(expected, updated)
    }
}

#[cfg(test)]
pub(crate) use harness_task_board_workflow_execution::validate_attempt_phase;
pub(crate) use harness_task_board_workflow_execution::{canonical_time, require_human};

#[cfg(test)]
pub(crate) struct TaskBoardWorkflowExecutionCreateRequest {
    pub execution_id: String,
    pub item_id: String,
    pub snapshot: TaskBoardWorkflowSnapshot,
    pub pull_request: Option<TaskBoardPullRequestIdentity>,
    pub exact_head_revision: Option<String>,
    pub created_at: String,
}

#[cfg(test)]
pub(crate) async fn create_or_load_workflow_execution(
    db: &AsyncDaemonDb,
    request: &TaskBoardWorkflowExecutionCreateRequest,
) -> Result<TaskBoardWorkflowExecutionCreateOutcome, CliError> {
    let created_at = canonical_time(&request.created_at)?;
    if !(matches!(
        request.snapshot.workflow_kind,
        TaskBoardWorkflowKind::Review
    ) || request.snapshot.workflow_kind.is_read_only_review())
    {
        return Err(invalid_transition(
            "read-only workflow execution requires Review or PrReview",
        ));
    }
    let transition = start_task_board_workflow(
        request.snapshot.workflow_kind,
        request.pull_request.as_ref(),
        request.exact_head_revision.as_deref(),
    )
    .map_err(|error| invalid_transition(error.to_string()))?;
    let record = TaskBoardWorkflowExecutionRecord {
        execution_id: required(&request.execution_id, "execution id")?,
        item_id: required(&request.item_id, "item id")?,
        snapshot: request.snapshot.clone(),
        resolved_reviewers: request.snapshot.reviewer.clone(),
        transition,
        artifacts: TaskBoardWorkflowExecutionArtifacts::default(),
        ownership: TaskBoardExecutionOwnership {
            host_id: None,
            fencing_epoch: 0,
            resources: BTreeMap::default(),
        },
        available_at: None,
        blocked_reason: None,
        created_at: created_at.clone(),
        updated_at: created_at,
        completed_at: None,
        attempts: Vec::new(),
    };
    db.create_or_load_task_board_workflow_execution(&record)
        .await
}

#[cfg(test)]
fn required(value: &str, field: &str) -> Result<String, CliError> {
    let value = value.trim();
    if value.is_empty() {
        Err(invalid_transition(format!("{field} is empty")))
    } else {
        Ok(value.to_owned())
    }
}

#[cfg(test)]
fn invalid_transition(detail: impl Into<String>) -> CliError {
    CliErrorKind::invalid_transition(detail.into()).into()
}

pub(crate) async fn advance_workflow_execution(
    db: &AsyncDaemonDb,
    expected: &TaskBoardWorkflowExecutionCas,
    current_revisions: &TaskBoardWorkflowRevisionGuard,
    observed_pull_request: Option<&TaskBoardPullRequestIdentity>,
    observed_head_revision: Option<&str>,
    updated_at: &str,
) -> Result<TaskBoardWorkflowExecutionCasOutcome, CliError> {
    harness_task_board_workflow_execution::advance_workflow_execution(
        &WorkflowExecutionDb(db),
        expected,
        current_revisions,
        observed_pull_request,
        observed_head_revision,
        updated_at,
    )
    .await
}

pub(crate) async fn schedule_workflow_retry(
    db: &AsyncDaemonDb,
    expected: &TaskBoardWorkflowExecutionCas,
    retry: TaskBoardRetrySchedule,
    diagnostic: TaskBoardExecutionDiagnostic,
    updated_at: &str,
) -> Result<TaskBoardWorkflowExecutionCasOutcome, CliError> {
    harness_task_board_workflow_execution::schedule_workflow_retry(
        &WorkflowExecutionDb(db),
        expected,
        retry,
        diagnostic,
        updated_at,
    )
    .await
}

pub(crate) async fn resume_workflow_retry(
    db: &AsyncDaemonDb,
    expected: &TaskBoardWorkflowExecutionCas,
    resumed_at: &str,
) -> Result<TaskBoardWorkflowExecutionCasOutcome, CliError> {
    harness_task_board_workflow_execution::resume_workflow_retry(
        &WorkflowExecutionDb(db),
        expected,
        resumed_at,
    )
    .await
}

pub(crate) async fn create_workflow_execution_attempt(
    db: &AsyncDaemonDb,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> Result<TaskBoardExecutionAttemptCreateOutcome, CliError> {
    harness_task_board_workflow_execution::create_workflow_execution_attempt(
        &WorkflowExecutionDb(db),
        attempt,
    )
    .await
}

pub(crate) async fn record_workflow_execution_attempt(
    db: &AsyncDaemonDb,
    expected: &TaskBoardExecutionAttemptCas,
    updated: &TaskBoardExecutionAttemptRecord,
) -> Result<TaskBoardExecutionAttemptCasOutcome, CliError> {
    harness_task_board_workflow_execution::record_workflow_execution_attempt(
        &WorkflowExecutionDb(db),
        expected,
        updated,
    )
    .await
}

pub(crate) async fn guarded_execution(
    db: &AsyncDaemonDb,
    expected: &TaskBoardWorkflowExecutionCas,
) -> Result<Option<TaskBoardWorkflowExecutionRecord>, CliError> {
    harness_task_board_workflow_execution::guarded_execution(&WorkflowExecutionDb(db), expected)
        .await
}

pub(crate) async fn stale_outcome(
    db: &AsyncDaemonDb,
    expected: &TaskBoardWorkflowExecutionCas,
) -> Result<TaskBoardWorkflowExecutionCasOutcome, CliError> {
    harness_task_board_workflow_execution::stale_outcome(&WorkflowExecutionDb(db), expected).await
}
