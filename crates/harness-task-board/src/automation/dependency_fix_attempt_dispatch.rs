use async_trait::async_trait;
use harness_kernel::errors::{CliError, CliErrorKind};

use super::{
    TaskBoardDependencyCheckResumeRecord, TaskBoardDependencyFixAuditTrail,
    TaskBoardDependencyFixLauncher, TaskBoardDependencyFixRequest, TaskBoardDependencyFixResult,
    TaskBoardDependencyFixRetryDecision, TaskBoardDependencyFixRun,
    task_board_dependency_fix_explicit_retry_request, task_board_dependency_fix_retry_decision,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TaskBoardDependencyFixAttemptOutcome {
    RetryScheduled {
        request: Box<TaskBoardDependencyFixRequest>,
        run: TaskBoardDependencyFixRun,
    },
    HumanRequired(Box<TaskBoardDependencyFixAuditTrail>),
}

#[derive(Debug, Clone, Copy)]
pub struct TaskBoardDependencyFixFailedAttempt<'a> {
    pub previous_request: &'a TaskBoardDependencyFixRequest,
    pub previous_run: &'a TaskBoardDependencyFixRun,
    pub previous_result: &'a TaskBoardDependencyFixResult,
    pub checks: &'a TaskBoardDependencyCheckResumeRecord,
    pub completed_at: &'a str,
}

#[derive(Debug, Clone, Copy)]
pub struct TaskBoardDependencyFixExplicitRetry<'a> {
    pub previous_request: &'a TaskBoardDependencyFixRequest,
    pub previous_run: &'a TaskBoardDependencyFixRun,
    pub previous_result: Option<&'a TaskBoardDependencyFixResult>,
    pub checks: Option<&'a TaskBoardDependencyCheckResumeRecord>,
    pub stopped_audit: &'a TaskBoardDependencyFixAuditTrail,
    pub authorized_at: &'a str,
}

#[async_trait]
pub trait TaskBoardDependencyFixAuditSink: Send + Sync {
    /// Persist the complete audit trail into its bound task ticket and workflow execution.
    ///
    /// Implementations must reject scope or history conflicts. Replaying an identical audit is
    /// idempotent.
    ///
    /// # Errors
    ///
    /// Returns a persistence error before a retry is started or human action is reported.
    async fn record(&self, audit: &TaskBoardDependencyFixAuditTrail) -> Result<(), CliError>;
}

/// Apply the attempt policy, persist the ticket-visible result, and start an allowed retry.
///
/// # Errors
///
/// Returns policy, evidence, persistence, or launcher errors. The audit is persisted before any
/// retry starts.
pub async fn continue_task_board_dependency_fix_after_failed_checks(
    failed: TaskBoardDependencyFixFailedAttempt<'_>,
    audit_sink: &dyn TaskBoardDependencyFixAuditSink,
    launcher: &dyn TaskBoardDependencyFixLauncher,
) -> Result<TaskBoardDependencyFixAttemptOutcome, CliError> {
    match task_board_dependency_fix_retry_decision(
        &failed.previous_request.attempt_policy,
        failed.previous_request,
        failed.previous_run,
        failed.previous_result,
        failed.checks,
        failed.completed_at,
    )? {
        TaskBoardDependencyFixRetryDecision::Retry(request) => {
            let audit = request.audit.as_ref().ok_or_else(|| {
                CliErrorKind::workflow_parse(
                    "dependency fixer retry decision has no ticket audit trail",
                )
            })?;
            audit_sink.record(audit).await?;
            let run = launcher.start(&request).await?;
            Ok(TaskBoardDependencyFixAttemptOutcome::RetryScheduled { request, run })
        }
        TaskBoardDependencyFixRetryDecision::HumanRequired(audit) => {
            audit_sink.record(&audit).await?;
            Ok(TaskBoardDependencyFixAttemptOutcome::HumanRequired(audit))
        }
    }
}

/// Persist and start one explicit retry without resetting its stopped audit history.
///
/// # Errors
///
/// Returns evidence, persistence, or launcher errors. The continued audit is persisted before the
/// retry starts.
pub async fn dispatch_explicit_task_board_dependency_fix_retry(
    retry: TaskBoardDependencyFixExplicitRetry<'_>,
    audit_sink: &dyn TaskBoardDependencyFixAuditSink,
    launcher: &dyn TaskBoardDependencyFixLauncher,
) -> Result<TaskBoardDependencyFixAttemptOutcome, CliError> {
    let request = task_board_dependency_fix_explicit_retry_request(
        retry.previous_request,
        retry.previous_run,
        retry.previous_result,
        retry.checks,
        retry.stopped_audit,
        retry.authorized_at,
    )?;
    let audit = request.audit.as_ref().ok_or_else(|| {
        CliErrorKind::workflow_parse("explicit dependency fixer retry has no ticket audit trail")
    })?;
    audit_sink.record(audit).await?;
    let run = launcher.start(&request).await?;
    Ok(TaskBoardDependencyFixAttemptOutcome::RetryScheduled {
        request: Box::new(request),
        run,
    })
}

#[cfg(test)]
mod tests;
