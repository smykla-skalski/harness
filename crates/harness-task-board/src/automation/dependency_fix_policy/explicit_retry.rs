use super::{
    CliError, TASK_BOARD_DEPENDENCY_FIX_TIMEOUT_REASON, TaskBoardDependencyCheckResumeRecord,
    TaskBoardDependencyFixAuditTrail, TaskBoardDependencyFixAutomationStatus,
    TaskBoardDependencyFixRequest, TaskBoardDependencyFixResult, TaskBoardDependencyFixRun,
    TaskBoardDependencyFixStopReason, parse_error, parse_time, policy_deadline,
    task_board_dependency_fix_retry_request, validate_policy, validate_stopped_audit,
};

/// Authorize one user-requested retry without erasing the stopped audit trail.
///
/// Completion and failed-check evidence must be present for a settled failure. A deadline-cancelled
/// attempt has neither artifact, so its retained timeout audit authorizes the next attempt directly.
///
/// # Errors
///
/// Rejects evidence that does not describe the exact stopped attempt being retried.
pub fn task_board_dependency_fix_explicit_retry_request(
    previous_request: &TaskBoardDependencyFixRequest,
    previous_run: &TaskBoardDependencyFixRun,
    previous_result: Option<&TaskBoardDependencyFixResult>,
    checks: Option<&TaskBoardDependencyCheckResumeRecord>,
    stopped_audit: &TaskBoardDependencyFixAuditTrail,
    authorized_at: &str,
) -> Result<TaskBoardDependencyFixRequest, CliError> {
    validate_policy(&previous_request.attempt_policy)?;
    validate_stopped_audit(previous_request, previous_run, stopped_audit)?;
    let authorized = parse_time(authorized_at, "explicit retry authorization")?;
    if authorized < parse_time(&stopped_audit.updated_at, "audit update")? {
        return Err(parse_error(
            "dependency fixer explicit retry predates its stopped audit",
        ));
    }
    let deadline_cancelled = stopped_audit.stop_reason
        == Some(TaskBoardDependencyFixStopReason::TimeBudgetExhausted)
        && stopped_audit.attempts.last().is_some_and(|attempt| {
            attempt.failure_reason == TASK_BOARD_DEPENDENCY_FIX_TIMEOUT_REASON
        });
    let mut next = if deadline_cancelled {
        if previous_result.is_some() || checks.is_some() {
            return Err(parse_error(
                "deadline-cancelled dependency fixer retry has unexpected completion evidence",
            ));
        }
        timeout_retry_request(previous_request)?
    } else {
        if stopped_audit.stop_reason.is_none() {
            return Err(parse_error(
                "dependency fixer explicit retry has no stop reason",
            ));
        }
        task_board_dependency_fix_retry_request(
            previous_request,
            previous_run,
            previous_result.ok_or_else(|| {
                parse_error("dependency fixer explicit retry has no completion result")
            })?,
            checks.ok_or_else(|| {
                parse_error("dependency fixer explicit retry has no settled check evidence")
            })?,
        )?
    };
    let mut audit = stopped_audit.clone();
    audit.current_attempt = next.attempt;
    audit.status = TaskBoardDependencyFixAutomationStatus::RetryScheduled;
    audit.stop_reason = None;
    audit.deadline_at = policy_deadline(authorized, &previous_request.attempt_policy)?;
    next.audit = Some(audit);
    Ok(next)
}

fn timeout_retry_request(
    previous_request: &TaskBoardDependencyFixRequest,
) -> Result<TaskBoardDependencyFixRequest, CliError> {
    let attempt = previous_request
        .attempt
        .checked_add(1)
        .ok_or_else(|| parse_error("dependency fixer attempt number overflow"))?;
    let mut next = previous_request.clone();
    next.dispatch_id = format!("{}:fix:{attempt}", previous_request.route_id);
    next.attempt = attempt;
    next.retry_evidence = None;
    Ok(next)
}
