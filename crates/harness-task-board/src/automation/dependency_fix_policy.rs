use chrono::{DateTime, SecondsFormat, TimeDelta, Utc};
use harness_kernel::errors::{CliError, CliErrorKind};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::{
    TaskBoardDependencyCheckConclusion, TaskBoardDependencyCheckResumeRecord,
    TaskBoardDependencyFixRequest, TaskBoardDependencyFixResult, TaskBoardDependencyFixRun,
    task_board_dependency_fix_retry_request, valid_head_revision, validate_prior_run,
};

mod explicit_retry;

pub use explicit_retry::task_board_dependency_fix_explicit_retry_request;

pub const TASK_BOARD_DEPENDENCY_FIX_AUDIT_SCHEMA_VERSION: u32 = 1;
const TASK_BOARD_DEPENDENCY_FIX_TIMEOUT_REASON: &str = "automated repair time budget exhausted";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardDependencyFixAttemptPolicy {
    pub max_attempts: u32,
    pub max_elapsed_seconds: u64,
    pub max_equivalent_failures: u32,
}

impl Default for TaskBoardDependencyFixAttemptPolicy {
    fn default() -> Self {
        Self {
            max_attempts: 3,
            max_elapsed_seconds: 3_600,
            max_equivalent_failures: 2,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardDependencyFixAutomationStatus {
    RetryScheduled,
    HumanRequired,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardDependencyFixStopReason {
    RepeatedEquivalentFailure,
    AttemptLimitReached,
    TimeBudgetExhausted,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardDependencyFixAttemptEvidence {
    pub attempt: u32,
    pub run_id: String,
    pub exact_head_revision: String,
    pub started_at: String,
    pub completed_at: String,
    pub failure_reason: String,
    pub failure_fingerprint: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardDependencyFixAuditTrail {
    pub schema_version: u32,
    pub route_id: String,
    pub board_item_id: String,
    pub workflow_execution_id: String,
    pub attempt_count: u32,
    pub current_attempt: u32,
    pub status: TaskBoardDependencyFixAutomationStatus,
    pub failure_reason: String,
    pub first_started_at: String,
    pub deadline_at: String,
    pub updated_at: String,
    pub attempts: Vec<TaskBoardDependencyFixAttemptEvidence>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stop_reason: Option<TaskBoardDependencyFixStopReason>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TaskBoardDependencyFixRetryDecision {
    Retry(Box<TaskBoardDependencyFixRequest>),
    HumanRequired(Box<TaskBoardDependencyFixAuditTrail>),
}

/// Apply the automated repair policy after one fixer attempt settles with failed checks.
///
/// # Errors
///
/// Rejects malformed policy, timestamps, audit history, or retry evidence.
pub fn task_board_dependency_fix_retry_decision(
    policy: &TaskBoardDependencyFixAttemptPolicy,
    previous_request: &TaskBoardDependencyFixRequest,
    previous_run: &TaskBoardDependencyFixRun,
    previous_result: &TaskBoardDependencyFixResult,
    checks: &TaskBoardDependencyCheckResumeRecord,
    completed_at: &str,
) -> Result<TaskBoardDependencyFixRetryDecision, CliError> {
    validate_policy(policy)?;
    let mut next = task_board_dependency_fix_retry_request(
        previous_request,
        previous_run,
        previous_result,
        checks,
    )?;
    let retry_evidence = next
        .retry_evidence
        .as_ref()
        .ok_or_else(|| parse_error("dependency fixer retry request has no failure evidence"))?;
    let mut audit = append_failed_attempt(
        policy,
        previous_request,
        previous_run,
        retry_evidence,
        completed_at,
    )?;
    if let Some(reason) = policy_stop_reason(policy, &audit)? {
        audit.current_attempt = previous_request.attempt;
        audit.status = TaskBoardDependencyFixAutomationStatus::HumanRequired;
        audit.stop_reason = Some(reason);
        return Ok(TaskBoardDependencyFixRetryDecision::HumanRequired(
            Box::new(audit),
        ));
    }
    audit.current_attempt = next.attempt;
    audit.status = TaskBoardDependencyFixAutomationStatus::RetryScheduled;
    next.audit = Some(audit);
    Ok(TaskBoardDependencyFixRetryDecision::Retry(Box::new(next)))
}

/// Validate a complete ticket-visible dependency fixer audit trail.
///
/// # Errors
///
/// Rejects malformed scope, history, timestamps, fingerprints, or status summaries.
pub fn validate_task_board_dependency_fix_audit(
    audit: &TaskBoardDependencyFixAuditTrail,
) -> Result<(), CliError> {
    validate_audit_shape(audit)?;
    let status_matches = match audit.status {
        TaskBoardDependencyFixAutomationStatus::RetryScheduled => {
            audit.stop_reason.is_none()
                && audit.current_attempt == audit.attempt_count.saturating_add(1)
        }
        TaskBoardDependencyFixAutomationStatus::HumanRequired => {
            audit.stop_reason.is_some() && audit.current_attempt == audit.attempt_count
        }
    };
    if !status_matches {
        return Err(parse_error(
            "dependency fixer audit status does not match its attempt summary",
        ));
    }
    Ok(())
}

/// Build the terminal audit recorded when the daemon cancels an attempt at its deadline.
///
/// # Errors
///
/// Rejects malformed request, run, retained audit, or completion timestamps.
pub fn task_board_dependency_fix_timeout_audit(
    request: &TaskBoardDependencyFixRequest,
    run: &TaskBoardDependencyFixRun,
    completed_at: &str,
) -> Result<TaskBoardDependencyFixAuditTrail, CliError> {
    validate_policy(&request.attempt_policy)?;
    validate_prior_run(request, run)?;
    let started = parse_time(&run.started_at, "fixer start")?;
    let completed = parse_time(completed_at, "fixer timeout")?;
    if completed < started {
        return Err(parse_error("dependency fixer timeout precedes its start"));
    }
    let mut audit = prior_audit(&request.attempt_policy, request, run, started)?;
    let failure_reason = TASK_BOARD_DEPENDENCY_FIX_TIMEOUT_REASON.to_string();
    audit.attempts.push(TaskBoardDependencyFixAttemptEvidence {
        attempt: request.attempt,
        run_id: run.run_id.clone(),
        exact_head_revision: request.exact_head_revision.clone(),
        started_at: run.started_at.clone(),
        completed_at: completed_at.to_string(),
        failure_fingerprint: hex::encode(Sha256::digest(failure_reason.as_bytes())),
        failure_reason: failure_reason.clone(),
    });
    audit.attempt_count = u32::try_from(audit.attempts.len())
        .map_err(|_| parse_error("dependency fixer audit attempt count overflow"))?;
    audit.current_attempt = audit.attempt_count;
    audit.status = TaskBoardDependencyFixAutomationStatus::HumanRequired;
    audit.failure_reason = failure_reason;
    audit.updated_at = completed_at.to_string();
    audit.stop_reason = Some(TaskBoardDependencyFixStopReason::TimeBudgetExhausted);
    validate_task_board_dependency_fix_audit(&audit)?;
    Ok(audit)
}

fn append_failed_attempt(
    policy: &TaskBoardDependencyFixAttemptPolicy,
    request: &TaskBoardDependencyFixRequest,
    run: &TaskBoardDependencyFixRun,
    retry: &super::TaskBoardDependencyFixRetryEvidence,
    completed_at: &str,
) -> Result<TaskBoardDependencyFixAuditTrail, CliError> {
    let started = parse_time(&run.started_at, "fixer start")?;
    let completed = parse_time(completed_at, "fixer completion")?;
    if completed < started {
        return Err(parse_error(
            "dependency fixer completion precedes its start",
        ));
    }
    let mut audit = prior_audit(policy, request, run, started)?;
    let (failure_reason, failure_fingerprint) = failure_identity(retry)?;
    audit.attempts.push(TaskBoardDependencyFixAttemptEvidence {
        attempt: request.attempt,
        run_id: run.run_id.clone(),
        exact_head_revision: retry.exact_head_revision.clone(),
        started_at: run.started_at.clone(),
        completed_at: completed_at.to_string(),
        failure_reason: failure_reason.clone(),
        failure_fingerprint,
    });
    audit.attempt_count = u32::try_from(audit.attempts.len())
        .map_err(|_| parse_error("dependency fixer audit attempt count overflow"))?;
    audit.failure_reason = failure_reason;
    audit.updated_at = completed_at.to_string();
    Ok(audit)
}

fn prior_audit(
    policy: &TaskBoardDependencyFixAttemptPolicy,
    request: &TaskBoardDependencyFixRequest,
    run: &TaskBoardDependencyFixRun,
    started: DateTime<Utc>,
) -> Result<TaskBoardDependencyFixAuditTrail, CliError> {
    let Some(audit) = &request.audit else {
        if request.attempt != 1 {
            return Err(parse_error(
                "dependency fixer retry lost its prior audit trail",
            ));
        }
        let deadline = policy_deadline(started, policy)?;
        return Ok(TaskBoardDependencyFixAuditTrail {
            schema_version: TASK_BOARD_DEPENDENCY_FIX_AUDIT_SCHEMA_VERSION,
            route_id: request.route_id.clone(),
            board_item_id: request.board_item_id.clone(),
            workflow_execution_id: request.workflow_execution_id.clone(),
            attempt_count: 0,
            current_attempt: 1,
            status: TaskBoardDependencyFixAutomationStatus::RetryScheduled,
            failure_reason: String::new(),
            first_started_at: run.started_at.clone(),
            deadline_at: deadline,
            updated_at: run.started_at.clone(),
            attempts: Vec::new(),
            stop_reason: None,
        });
    };
    validate_running_audit(request, audit)?;
    if started < parse_time(&audit.updated_at, "audit update")? {
        return Err(parse_error(
            "dependency fixer attempt starts before its retained audit history",
        ));
    }
    Ok(audit.clone())
}

fn policy_deadline(
    started: DateTime<Utc>,
    policy: &TaskBoardDependencyFixAttemptPolicy,
) -> Result<String, CliError> {
    let budget = i64::try_from(policy.max_elapsed_seconds)
        .ok()
        .and_then(TimeDelta::try_seconds)
        .ok_or_else(|| parse_error("dependency fixer time budget is out of range"))?;
    started
        .checked_add_signed(budget)
        .map(|deadline| deadline.to_rfc3339_opts(SecondsFormat::Secs, true))
        .ok_or_else(|| parse_error("dependency fixer deadline is out of range"))
}

fn policy_stop_reason(
    policy: &TaskBoardDependencyFixAttemptPolicy,
    audit: &TaskBoardDependencyFixAuditTrail,
) -> Result<Option<TaskBoardDependencyFixStopReason>, CliError> {
    let latest = audit
        .attempts
        .last()
        .expect("a settled attempt was just appended");
    let equivalent = audit
        .attempts
        .iter()
        .filter(|attempt| attempt.failure_fingerprint == latest.failure_fingerprint)
        .count();
    if equivalent >= usize::try_from(policy.max_equivalent_failures).unwrap_or(usize::MAX) {
        return Ok(Some(
            TaskBoardDependencyFixStopReason::RepeatedEquivalentFailure,
        ));
    }
    if audit.attempt_count >= policy.max_attempts {
        return Ok(Some(TaskBoardDependencyFixStopReason::AttemptLimitReached));
    }
    let first = parse_time(&audit.first_started_at, "first fixer start")?;
    let updated = parse_time(&audit.updated_at, "audit update")?;
    let elapsed: u64 = updated
        .signed_duration_since(first)
        .num_seconds()
        .try_into()
        .map_err(|_| parse_error("dependency fixer audit elapsed time is invalid"))?;
    if elapsed >= policy.max_elapsed_seconds {
        return Ok(Some(TaskBoardDependencyFixStopReason::TimeBudgetExhausted));
    }
    Ok(None)
}

fn failure_identity(
    retry: &super::TaskBoardDependencyFixRetryEvidence,
) -> Result<(String, String), CliError> {
    let mut failed: Vec<_> = retry
        .checks
        .iter()
        .filter(|check| check.conclusion == TaskBoardDependencyCheckConclusion::Failure)
        .map(|check| check.name.as_str())
        .collect();
    failed.sort_unstable();
    if failed.is_empty() {
        return Err(parse_error(
            "dependency fixer audit has no failed check identity",
        ));
    }
    let failure_reason = format!("failed checks: {}", failed.join(", "));
    let fingerprint = hex::encode(Sha256::digest(failure_reason.as_bytes()));
    Ok((failure_reason, fingerprint))
}

fn validate_policy(policy: &TaskBoardDependencyFixAttemptPolicy) -> Result<(), CliError> {
    if policy.max_attempts == 0
        || policy.max_elapsed_seconds == 0
        || policy.max_equivalent_failures == 0
    {
        return Err(parse_error(
            "dependency fixer attempt policy requires positive bounds",
        ));
    }
    Ok(())
}

fn validate_running_audit(
    request: &TaskBoardDependencyFixRequest,
    audit: &TaskBoardDependencyFixAuditTrail,
) -> Result<(), CliError> {
    validate_audit_shape(audit)?;
    if audit.status != TaskBoardDependencyFixAutomationStatus::RetryScheduled
        || audit.stop_reason.is_some()
        || !audit_matches_request(audit, request)
        || audit.current_attempt != request.attempt
        || audit.attempt_count.saturating_add(1) != request.attempt
    {
        return Err(parse_error(
            "dependency fixer retry audit does not authorize the current attempt",
        ));
    }
    Ok(())
}

fn validate_stopped_audit(
    request: &TaskBoardDependencyFixRequest,
    run: &TaskBoardDependencyFixRun,
    audit: &TaskBoardDependencyFixAuditTrail,
) -> Result<(), CliError> {
    validate_audit_shape(audit)?;
    let last = audit
        .attempts
        .last()
        .ok_or_else(|| parse_error("dependency fixer stopped audit has no failed attempt"))?;
    if audit.status != TaskBoardDependencyFixAutomationStatus::HumanRequired
        || audit.stop_reason.is_none()
        || !audit_matches_request(audit, request)
        || audit.current_attempt != request.attempt
        || last.attempt != request.attempt
        || last.run_id != run.run_id
    {
        return Err(parse_error(
            "dependency fixer explicit retry does not match its stopped attempt",
        ));
    }
    Ok(())
}

fn validate_audit_shape(audit: &TaskBoardDependencyFixAuditTrail) -> Result<(), CliError> {
    let attempt_count = u32::try_from(audit.attempts.len())
        .map_err(|_| parse_error("dependency fixer audit attempt count overflow"))?;
    if audit.schema_version != TASK_BOARD_DEPENDENCY_FIX_AUDIT_SCHEMA_VERSION
        || [
            audit.route_id.as_str(),
            audit.board_item_id.as_str(),
            audit.workflow_execution_id.as_str(),
        ]
        .iter()
        .any(|value| value.trim().is_empty() || value.trim() != *value)
        || audit.attempt_count != attempt_count
        || audit.failure_reason.trim().is_empty()
        || audit.failure_reason.trim() != audit.failure_reason
        || !valid_attempt_sequence(&audit.attempts)
    {
        return Err(parse_error("dependency fixer audit trail is invalid"));
    }
    let Some(first) = audit.attempts.first() else {
        return Err(parse_error("dependency fixer audit trail is empty"));
    };
    let Some(last) = audit.attempts.last() else {
        return Err(parse_error("dependency fixer audit trail is empty"));
    };
    let deadline = parse_time(&audit.deadline_at, "fixer deadline")?;
    let first_started = parse_time(&audit.first_started_at, "first fixer start")?;
    if audit.first_started_at != first.started_at
        || audit.updated_at != last.completed_at
        || audit.failure_reason != last.failure_reason
        || deadline <= first_started
    {
        return Err(parse_error(
            "dependency fixer audit summary does not match its attempts",
        ));
    }
    Ok(())
}

fn valid_attempt_sequence(attempts: &[TaskBoardDependencyFixAttemptEvidence]) -> bool {
    let mut prior_completion = None;
    attempts.iter().enumerate().all(|(index, attempt)| {
        let Ok(started) = parse_time(&attempt.started_at, "fixer start") else {
            return false;
        };
        let Ok(completed) = parse_time(&attempt.completed_at, "fixer completion") else {
            return false;
        };
        let chronological = completed >= started
            && prior_completion
                .as_ref()
                .is_none_or(|prior| started >= *prior);
        prior_completion = Some(completed);
        attempt.attempt == u32::try_from(index + 1).unwrap_or(u32::MAX)
            && attempt.run_id.trim() == attempt.run_id
            && !attempt.run_id.is_empty()
            && valid_head_revision(&attempt.exact_head_revision)
            && attempt.failure_reason.trim() == attempt.failure_reason
            && !attempt.failure_reason.is_empty()
            && attempt.failure_fingerprint.len() == 64
            && attempt
                .failure_fingerprint
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit())
            && attempt.failure_fingerprint
                == hex::encode(Sha256::digest(attempt.failure_reason.as_bytes()))
            && chronological
    })
}

fn audit_matches_request(
    audit: &TaskBoardDependencyFixAuditTrail,
    request: &TaskBoardDependencyFixRequest,
) -> bool {
    audit.route_id == request.route_id
        && audit.board_item_id == request.board_item_id
        && audit.workflow_execution_id == request.workflow_execution_id
}

fn parse_time(value: &str, label: &str) -> Result<DateTime<Utc>, CliError> {
    if value.trim().is_empty() || value.trim() != value {
        return Err(parse_error(format!(
            "dependency fixer {label} timestamp is invalid"
        )));
    }
    DateTime::parse_from_rfc3339(value)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| parse_error(format!("dependency fixer {label} timestamp: {error}")))
}

fn parse_error(detail: impl Into<String>) -> CliError {
    CliErrorKind::workflow_parse(detail.into()).into()
}

#[cfg(test)]
mod tests;
