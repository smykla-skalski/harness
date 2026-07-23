use chrono::{DateTime, SecondsFormat, Utc};
use serde_json::json;
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::daemon::audit_events::{broadcast_audit_event, persist_audit_event_once_strict};
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{
    HarnessMonitorAuditEvent, TaskBoardAutomationForceCancelDisposition,
    TaskBoardAutomationForceCancelRequest, TaskBoardAutomationForceCancelResponse,
};
use crate::errors::{CliError, CliErrorKind};
use crate::feature_flags::task_board_automation_v2_enabled_from_env;
use crate::infra::io::validate_safe_segment;
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE, TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE,
    TASK_BOARD_REMOTE_CANCEL_INTENT_REASON_RESOURCE, TaskBoardAttemptState,
    TaskBoardAutomationCancelTarget, TaskBoardExecutionAttemptCas, TaskBoardExecutionState,
    TaskBoardTerminalOutcome, TaskBoardTerminalOutcomeKind, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionRecord, task_board_remote_execution_target,
};
use crate::workspace::utc_now;

pub(crate) async fn force_cancel_task_board_automation_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardAutomationForceCancelRequest,
) -> Result<TaskBoardAutomationForceCancelResponse, CliError> {
    if !task_board_automation_v2_enabled_from_env() {
        return Err(CliErrorKind::invalid_transition(
            "task board automation v2 force cancel is disabled",
        )
        .into());
    }
    let success_audit = audit_event(request, AuditOutcome::Success);
    match Box::pin(force_cancel(db, request, &success_audit)).await {
        Ok(outcome) => {
            if outcome.audit_inserted {
                broadcast_audit_event(&success_audit);
            }
            Ok(TaskBoardAutomationForceCancelResponse {
                disposition: outcome.disposition,
            })
        }
        Err(error) => {
            let rejected = audit_event(request, AuditOutcome::Rejected(error.code()));
            persist_audit_event_once_strict(db, &rejected).await?;
            Err(error)
        }
    }
}

async fn force_cancel(
    db: &AsyncDaemonDb,
    request: &TaskBoardAutomationForceCancelRequest,
    success_audit: &HarnessMonitorAuditEvent,
) -> Result<ForceCancelOutcome, CliError> {
    let reason = validate_request(request)?;
    let current = db
        .task_board_workflow_execution(&request.target.execution_id)
        .await?
        .ok_or_else(|| {
            CliErrorKind::path_not_found(format!(
                "workflow execution '{}'",
                request.target.execution_id
            ))
        })?;
    if let Some(disposition) = replay_disposition(&current, &request.target, reason) {
        return replay_outcome(db, success_audit, disposition).await;
    }
    reject_terminal(&current)?;
    let Some(current_target) = db
        .task_board_automation_cancel_target(&request.target.execution_id)
        .await?
    else {
        return replay_after_race(
            db,
            &request.target,
            reason,
            success_audit,
            "remote cancellation target is no longer available",
        )
        .await;
    };
    if current_target.cancel_pending {
        return replay_after_race(
            db,
            &request.target,
            reason,
            success_audit,
            "remote cancellation target already has a different intent",
        )
        .await;
    }
    if current_target != request.target {
        return Err(concurrent("remote cancellation target generation changed"));
    }
    Box::pin(apply_cancel(
        db,
        current,
        &request.target,
        reason,
        success_audit,
    ))
    .await
}

pub(super) async fn apply_cancel(
    db: &AsyncDaemonDb,
    current: TaskBoardWorkflowExecutionRecord,
    target: &TaskBoardAutomationCancelTarget,
    reason: &str,
    success_audit: &HarnessMonitorAuditEvent,
) -> Result<ForceCancelOutcome, CliError> {
    let attempt = current
        .attempts
        .iter()
        .find(|attempt| target_matches_attempt(target, attempt))
        .cloned()
        .ok_or_else(|| concurrent("remote cancellation attempt generation changed"))?;
    let completed_at = cancellation_time(&current, &attempt);
    let mut stopped = current.clone();
    stopped.transition.execution_state = TaskBoardExecutionState::Cancelled;
    stopped.available_at = None;
    stopped.blocked_reason = None;
    stopped.updated_at.clone_from(&completed_at);
    stopped.completed_at = Some(completed_at.clone());
    stopped.artifacts.terminal_outcome = Some(TaskBoardTerminalOutcome {
        kind: TaskBoardTerminalOutcomeKind::Cancelled,
        summary: reason.into(),
        recorded_at: completed_at.clone(),
    });
    let mut cancelled_attempt = attempt.clone();
    cancelled_attempt.state = TaskBoardAttemptState::Cancelled;
    cancelled_attempt.failure_class = None;
    cancelled_attempt.available_at = None;
    cancelled_attempt.error = Some(reason.into());
    cancelled_attempt.artifact = None;
    cancelled_attempt.updated_at = completed_at.clone();
    cancelled_attempt.completed_at = Some(completed_at);
    let persisted = db
        .compare_and_set_task_board_remote_cancel_with_audit(
            &TaskBoardWorkflowExecutionCas::from(&current),
            target,
            &stopped,
            &TaskBoardExecutionAttemptCas::from(&attempt),
            &cancelled_attempt,
            success_audit,
        )
        .await?;
    let Some(record) = persisted.record else {
        return replay_after_race(
            db,
            target,
            reason,
            success_audit,
            "remote cancellation target generation changed",
        )
        .await;
    };
    let disposition = if record.transition.execution_state == TaskBoardExecutionState::Cancelled {
        TaskBoardAutomationForceCancelDisposition::Cancelled
    } else if pending_reason(&record) == Some(reason) {
        TaskBoardAutomationForceCancelDisposition::AcceptedPending
    } else {
        return Err(concurrent(
            "remote cancellation did not persist an exact outcome",
        ));
    };
    Ok(ForceCancelOutcome {
        disposition,
        audit_inserted: persisted.audit_inserted,
    })
}

async fn replay_after_race(
    db: &AsyncDaemonDb,
    target: &TaskBoardAutomationCancelTarget,
    reason: &str,
    success_audit: &HarnessMonitorAuditEvent,
    stale_message: &'static str,
) -> Result<ForceCancelOutcome, CliError> {
    let latest = db
        .task_board_workflow_execution(&target.execution_id)
        .await?;
    let disposition = latest.as_ref().and_then(|record| {
        replay_disposition(record, target, reason).or_else(|| {
            (pending_reason(record) == Some(reason) && target_matches_record(target, record))
                .then_some(TaskBoardAutomationForceCancelDisposition::ReplayedPending)
        })
    });
    match disposition {
        Some(disposition) => replay_outcome(db, success_audit, disposition).await,
        None => Err(concurrent(stale_message)),
    }
}

async fn replay_outcome(
    db: &AsyncDaemonDb,
    success_audit: &HarnessMonitorAuditEvent,
    disposition: TaskBoardAutomationForceCancelDisposition,
) -> Result<ForceCancelOutcome, CliError> {
    Ok(ForceCancelOutcome {
        disposition,
        audit_inserted: db.insert_audit_event_if_absent(success_audit).await?,
    })
}

fn validate_request(request: &TaskBoardAutomationForceCancelRequest) -> Result<&str, CliError> {
    validate_safe_segment(&request.target.execution_id)?;
    validate_safe_segment(&request.target.assignment_id)?;
    if !lower_hex_digest(&request.target.expected_record_sha256) {
        return Err(CliErrorKind::workflow_parse(
            "force-cancel target record digest must be lowercase SHA-256",
        )
        .into());
    }
    if request.target.cancel_pending {
        return Err(concurrent(
            "force-cancel request must target a non-pending cancellation",
        ));
    }
    let reason = request.reason.trim();
    if reason.is_empty() || reason.chars().count() > 1_024 {
        return Err(CliErrorKind::workflow_parse(
            "force-cancel reason must contain 1 to 1024 characters",
        )
        .into());
    }
    Ok(reason)
}

fn replay_disposition(
    current: &TaskBoardWorkflowExecutionRecord,
    target: &TaskBoardAutomationCancelTarget,
    reason: &str,
) -> Option<TaskBoardAutomationForceCancelDisposition> {
    if current.transition.execution_state == TaskBoardExecutionState::Cancelled
        && current
            .artifacts
            .terminal_outcome
            .as_ref()
            .is_some_and(|outcome| outcome.summary == reason)
        && target_matches_record(target, current)
    {
        return Some(TaskBoardAutomationForceCancelDisposition::ReplayedCancelled);
    }
    None
}

fn reject_terminal(current: &TaskBoardWorkflowExecutionRecord) -> Result<(), CliError> {
    if matches!(
        current.transition.execution_state,
        TaskBoardExecutionState::Completed
            | TaskBoardExecutionState::Failed
            | TaskBoardExecutionState::Cancelled
            | TaskBoardExecutionState::HumanRequired
    ) {
        return Err(CliErrorKind::invalid_transition(format!(
            "workflow execution '{}' is already terminal",
            current.execution_id
        ))
        .into());
    }
    Ok(())
}

fn target_matches_record(
    target: &TaskBoardAutomationCancelTarget,
    record: &TaskBoardWorkflowExecutionRecord,
) -> bool {
    target.execution_id == record.execution_id
        && target.item_id == record.item_id
        && target.workflow_kind == record.snapshot.workflow_kind
        && target.host_id.as_str() == record.ownership.host_id.as_deref().unwrap_or("")
        && target.fencing_epoch == record.ownership.fencing_epoch
        && task_board_remote_execution_target(record) == Some(target.assignment_id.as_str())
        && record
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE)
            == Some(&target.action_key)
        && record
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE)
            .is_some_and(|attempt| attempt == &target.attempt.to_string())
        && record
            .attempts
            .iter()
            .any(|attempt| target_matches_attempt(target, attempt))
}

fn target_matches_attempt(
    target: &TaskBoardAutomationCancelTarget,
    attempt: &crate::task_board::TaskBoardExecutionAttemptRecord,
) -> bool {
    attempt.action_key == target.action_key
        && attempt.attempt == target.attempt
        && attempt.idempotency_key == target.idempotency_key
}

fn pending_reason(record: &TaskBoardWorkflowExecutionRecord) -> Option<&str> {
    record
        .ownership
        .resources
        .get(TASK_BOARD_REMOTE_CANCEL_INTENT_REASON_RESOURCE)
        .map(String::as_str)
}

fn cancellation_time(
    record: &TaskBoardWorkflowExecutionRecord,
    attempt: &crate::task_board::TaskBoardExecutionAttemptRecord,
) -> String {
    let now = Utc::now();
    [&record.updated_at, &attempt.updated_at]
        .into_iter()
        .filter_map(|value| DateTime::parse_from_rfc3339(value).ok())
        .map(|value| value.with_timezone(&Utc))
        .fold(now, std::cmp::max)
        .to_rfc3339_opts(SecondsFormat::AutoSi, true)
}

fn lower_hex_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn concurrent(message: &'static str) -> CliError {
    CliErrorKind::concurrent_modification(message).into()
}

pub(super) fn audit_event(
    request: &TaskBoardAutomationForceCancelRequest,
    result: AuditOutcome<'_>,
) -> HarnessMonitorAuditEvent {
    let (outcome, severity, error_kind) = match result {
        AuditOutcome::Success => ("success", "warning", None),
        AuditOutcome::Rejected(error_kind) => ("rejected", "error", Some(error_kind)),
    };
    let id = if matches!(result, AuditOutcome::Success) {
        format!(
            "audit-task-board-force-cancel-{}",
            exact_target_digest(&request.target)
        )
    } else {
        format!("audit-{}", Uuid::new_v4().simple())
    };
    HarnessMonitorAuditEvent {
        id,
        recorded_at: utc_now(),
        source: "taskBoard".into(),
        category: "automation".into(),
        kind: "task_board.automation.execution.force_cancel".into(),
        severity: severity.into(),
        outcome: outcome.into(),
        title: "Task Board automation execution force cancel".into(),
        summary: format!(
            "Force cancel for workflow execution {} was {outcome}",
            request.target.execution_id
        ),
        subject: Some(request.target.execution_id.clone()),
        actor: request.actor.clone(),
        correlation_id: Some(request.target.execution_id.clone()),
        action_key: Some("task_board.automation.execution.force_cancel".into()),
        payload_json: Some(json!({
            "execution_id": request.target.execution_id,
            "assignment_id": request.target.assignment_id,
            "fencing_epoch": request.target.fencing_epoch,
            "action_key": request.target.action_key,
            "attempt": request.target.attempt,
            "outcome": outcome,
            "error_kind": error_kind,
        })),
        legacy_message: None,
        related_urls: Vec::new(),
    }
}

#[derive(Debug)]
pub(super) struct ForceCancelOutcome {
    disposition: TaskBoardAutomationForceCancelDisposition,
    audit_inserted: bool,
}

#[derive(Clone, Copy)]
pub(super) enum AuditOutcome<'a> {
    Success,
    Rejected(&'a str),
}

fn exact_target_digest(target: &TaskBoardAutomationCancelTarget) -> String {
    let identity = format!(
        "{}\0{}\0{}\0{}\0{}\0{}\0{}",
        target.execution_id,
        target.assignment_id,
        target.host_id,
        target.fencing_epoch,
        target.action_key,
        target.attempt,
        target.idempotency_key
    );
    hex::encode(Sha256::digest(identity.as_bytes()))
}
