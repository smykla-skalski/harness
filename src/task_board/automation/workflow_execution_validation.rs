use std::{collections::BTreeSet, fmt::Display};

use chrono::{DateTime, Utc};

use crate::task_board::{
    MAX_TASK_BOARD_REVIEW_REVISION_CYCLES, TASK_BOARD_WORKFLOW_EXECUTION_SCHEMA_VERSION,
    TaskBoardAttemptResultArtifact, TaskBoardAttemptState, TaskBoardExecutionAttemptRecord,
    TaskBoardExecutionPhase, TaskBoardExecutionState, TaskBoardFailureClass,
    TaskBoardTerminalOutcomeKind, TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind,
    evaluate_task_board_review_round, validate_task_board_resolved_reviewers,
    validate_task_board_workflow_transition_state,
};

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum TaskBoardWorkflowExecutionValidationError {
    #[error("workflow execution field '{field}' is invalid: {detail}")]
    InvalidField { field: &'static str, detail: String },
    #[error("workflow execution immutable field '{field}' changed")]
    ImmutableField { field: &'static str },
    #[error("workflow execution attempt transition is invalid")]
    InvalidAttemptTransition,
}

/// Validate a persisted workflow execution record and its frozen evidence.
///
/// # Errors
///
/// Returns an error when required fields, timestamps, frozen contracts, artifacts, or attempts are
/// invalid.
pub fn validate_task_board_workflow_execution(
    record: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    required(&record.execution_id, "execution_id")?;
    required(&record.item_id, "item_id")?;
    validate_timestamp(&record.created_at, "created_at")?;
    validate_timestamp(&record.updated_at, "updated_at")?;
    validate_optional_timestamp(record.available_at.as_deref(), "available_at")?;
    validate_optional_timestamp(record.completed_at.as_deref(), "completed_at")?;
    if parse_timestamp(&record.updated_at)? < parse_timestamp(&record.created_at)? {
        return invalid("updated_at", "precedes created_at");
    }
    if let Some(completed_at) = record.completed_at.as_deref()
        && parse_timestamp(completed_at)? < parse_timestamp(&record.updated_at)?
    {
        return invalid("completed_at", "precedes updated_at");
    }
    validate_frozen_contract(record)?;
    validate_artifacts(record)?;
    validate_attempts(record)
}

/// Validate an update to a persisted workflow execution record.
///
/// # Errors
///
/// Returns an error when the updated record is invalid, changes immutable fields, or moves its
/// timestamp backwards.
pub fn validate_task_board_execution_update(
    current: &TaskBoardWorkflowExecutionRecord,
    updated: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    validate_task_board_workflow_execution(updated)?;
    immutable(current.execution_id == updated.execution_id, "execution_id")?;
    immutable(current.item_id == updated.item_id, "item_id")?;
    immutable(current.snapshot == updated.snapshot, "snapshot")?;
    immutable(
        current.resolved_reviewers == updated.resolved_reviewers,
        "resolved_reviewers",
    )?;
    immutable(current.ownership == updated.ownership, "ownership")?;
    immutable(current.created_at == updated.created_at, "created_at")?;
    immutable(current.attempts == updated.attempts, "attempts")?;
    if parse_timestamp(&updated.updated_at)? < parse_timestamp(&current.updated_at)? {
        return invalid("updated_at", "moves backwards");
    }
    Ok(())
}

/// Validate a persisted workflow execution attempt.
///
/// # Errors
///
/// Returns an error when required fields, timestamps, or state-specific evidence are invalid.
pub fn validate_task_board_execution_attempt(
    record: &TaskBoardExecutionAttemptRecord,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    required(&record.execution_id, "attempt.execution_id")?;
    required(&record.action_key, "attempt.action_key")?;
    required(&record.idempotency_key, "attempt.idempotency_key")?;
    if record.attempt == 0 {
        return invalid("attempt.attempt", "must be greater than zero");
    }
    validate_timestamp(&record.started_at, "attempt.started_at")?;
    validate_timestamp(&record.updated_at, "attempt.updated_at")?;
    validate_optional_timestamp(record.available_at.as_deref(), "attempt.available_at")?;
    validate_optional_timestamp(record.completed_at.as_deref(), "attempt.completed_at")?;
    if parse_timestamp(&record.updated_at)? < parse_timestamp(&record.started_at)? {
        return invalid("attempt.updated_at", "precedes started_at");
    }
    if let Some(completed_at) = record.completed_at.as_deref()
        && parse_timestamp(completed_at)? < parse_timestamp(&record.updated_at)?
    {
        return invalid("attempt.completed_at", "precedes updated_at");
    }
    validate_attempt_state(record)
}

/// Validate an update to a persisted workflow execution attempt.
///
/// # Errors
///
/// Returns an error when the updated attempt is invalid, changes identity, moves backwards, or
/// makes a disallowed state transition.
pub fn validate_task_board_attempt_update(
    current: &TaskBoardExecutionAttemptRecord,
    updated: &TaskBoardExecutionAttemptRecord,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    validate_task_board_execution_attempt(updated)?;
    let same_identity = current.execution_id == updated.execution_id
        && current.action_key == updated.action_key
        && current.attempt == updated.attempt
        && current.idempotency_key == updated.idempotency_key
        && current.started_at == updated.started_at;
    immutable(same_identity, "attempt.identity")?;
    if parse_timestamp(&updated.updated_at)? < parse_timestamp(&current.updated_at)? {
        return invalid("attempt.updated_at", "moves backwards");
    }
    if !attempt_transition_allowed(current.state, updated.state) {
        return Err(TaskBoardWorkflowExecutionValidationError::InvalidAttemptTransition);
    }
    if current != updated && attempt_state_is_terminal(current.state) {
        return Err(TaskBoardWorkflowExecutionValidationError::InvalidAttemptTransition);
    }
    Ok(())
}

fn validate_frozen_contract(
    record: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    if record.snapshot.item_revision <= 0 {
        return invalid("snapshot.item_revision", "must be greater than zero");
    }
    if !matches!(
        record.snapshot.workflow_kind,
        TaskBoardWorkflowKind::PrReview | TaskBoardWorkflowKind::Review
    ) {
        return invalid(
            "snapshot.workflow_kind",
            "write and unknown workflows are not admitted by the read-only engine",
        );
    }
    if record.snapshot.workflow_kind != record.transition.workflow_kind {
        return invalid("transition.workflow_kind", "does not match snapshot");
    }
    if record.snapshot.reviewer != record.resolved_reviewers {
        return invalid("resolved_reviewers", "does not match snapshot");
    }
    validate_task_board_resolved_reviewers(&record.resolved_reviewers)
        .map_err(|error| field_error("resolved_reviewers", error))?;
    if record.resolved_reviewers.profiles.len()
        != usize::try_from(record.resolved_reviewers.reviewer_count).unwrap_or(usize::MAX)
    {
        return invalid(
            "resolved_reviewers",
            "profile count does not match reviewer count",
        );
    }
    validate_task_board_workflow_transition_state(&record.transition)
        .map_err(|error| field_error("transition", error))?;
    if record.transition.phase.is_none() {
        return invalid("transition.phase", "read-only workflow has no phase");
    }
    let terminal = matches!(
        record.transition.execution_state,
        TaskBoardExecutionState::Completed
            | TaskBoardExecutionState::Failed
            | TaskBoardExecutionState::Cancelled
    );
    if terminal && record.completed_at.is_none() {
        return invalid("transition", "terminal execution has no completion time");
    }
    if record.transition.execution_state == TaskBoardExecutionState::Completed
        && record.transition.phase != Some(TaskBoardExecutionPhase::Terminal)
    {
        return invalid("transition", "completed execution is not terminal");
    }
    Ok(())
}

fn validate_artifacts(
    record: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    let artifacts = &record.artifacts;
    if artifacts.schema_version != TASK_BOARD_WORKFLOW_EXECUTION_SCHEMA_VERSION {
        return invalid("artifacts.schema_version", "unsupported schema version");
    }
    if artifacts.current_revision_cycle == 0
        || artifacts.current_revision_cycle > record.resolved_reviewers.max_revision_cycles
        || artifacts.current_revision_cycle > MAX_TASK_BOARD_REVIEW_REVISION_CYCLES
    {
        return invalid(
            "artifacts.current_revision_cycle",
            "outside configured range",
        );
    }
    validate_review_cycles(record)?;
    if let Some(retry) = &artifacts.retry {
        required(&retry.action_key, "artifacts.retry.action_key")?;
        if retry.next_attempt == 0 {
            return invalid("artifacts.retry.next_attempt", "must be greater than zero");
        }
        validate_timestamp(&retry.available_at, "artifacts.retry.available_at")?;
    }
    for diagnostic in &artifacts.diagnostics {
        required(&diagnostic.code, "artifacts.diagnostic.code")?;
        required(&diagnostic.message, "artifacts.diagnostic.message")?;
        validate_timestamp(&diagnostic.recorded_at, "artifacts.diagnostic.recorded_at")?;
    }
    validate_terminal_outcome(record)
}

fn validate_review_cycles(
    record: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    let mut cycles = BTreeSet::new();
    for cycle in &record.artifacts.review_cycles {
        if cycle.revision_cycle == 0
            || cycle.revision_cycle > record.artifacts.current_revision_cycle
            || !cycles.insert(cycle.revision_cycle)
        {
            return invalid("artifacts.review_cycles", "cycle sequence is invalid");
        }
        required(&cycle.head_revision, "artifacts.review_cycle.head_revision")?;
        let evaluation = evaluate_task_board_review_round(
            &record.resolved_reviewers,
            &cycle.head_revision,
            cycle.revision_cycle,
            &cycle.outcomes,
        )
        .map_err(|error| field_error("artifacts.review_cycles", error))?;
        if cycle
            .decision
            .is_some_and(|decision| decision != evaluation.decision)
        {
            return invalid(
                "artifacts.review_cycles",
                "stored decision does not match evidence",
            );
        }
    }
    Ok(())
}

fn validate_terminal_outcome(
    record: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    let Some(outcome) = &record.artifacts.terminal_outcome else {
        if matches!(
            record.transition.execution_state,
            TaskBoardExecutionState::Completed
                | TaskBoardExecutionState::Failed
                | TaskBoardExecutionState::Cancelled
        ) {
            return invalid("artifacts.terminal_outcome", "completed without outcome");
        }
        return Ok(());
    };
    required(&outcome.summary, "artifacts.terminal_outcome.summary")?;
    validate_timestamp(
        &outcome.recorded_at,
        "artifacts.terminal_outcome.recorded_at",
    )?;
    let state = record.transition.execution_state;
    let valid = match outcome.kind {
        TaskBoardTerminalOutcomeKind::Succeeded => state == TaskBoardExecutionState::Completed,
        TaskBoardTerminalOutcomeKind::Failed => state == TaskBoardExecutionState::Failed,
        TaskBoardTerminalOutcomeKind::Cancelled => state == TaskBoardExecutionState::Cancelled,
        TaskBoardTerminalOutcomeKind::HumanRequired | TaskBoardTerminalOutcomeKind::Unknown => {
            state == TaskBoardExecutionState::HumanRequired
        }
    };
    if valid {
        Ok(())
    } else {
        invalid("artifacts.terminal_outcome", "contradicts execution state")
    }
}

fn validate_attempts(
    record: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    let mut identities = BTreeSet::new();
    let mut idempotency_keys = BTreeSet::new();
    for attempt in &record.attempts {
        validate_task_board_execution_attempt(attempt)?;
        validate_attempt_artifact(record, attempt)?;
        if attempt.execution_id != record.execution_id
            || !identities.insert((attempt.action_key.as_str(), attempt.attempt))
            || !idempotency_keys.insert(attempt.idempotency_key.as_str())
        {
            return invalid("attempts", "attempt identity is inconsistent or duplicated");
        }
    }
    Ok(())
}

fn validate_attempt_artifact(
    record: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    match attempt.artifact.as_ref() {
        Some(TaskBoardAttemptResultArtifact::Review(outcome)) => {
            let expected_head = record.transition.exact_head_revision.as_deref();
            let configured = record
                .resolved_reviewers
                .profiles
                .iter()
                .any(|profile| profile.id == outcome.profile_id);
            let head = outcome.result.head_revision.trim();
            let historical = record.artifacts.review_cycles.iter().any(|cycle| {
                cycle.head_revision == head && cycle.outcomes.iter().any(|stored| stored == outcome)
            });
            if (expected_head != Some(head) && !historical) || !configured {
                return invalid(
                    "attempt.artifact.review",
                    "does not match the frozen reviewer profile and exact head",
                );
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

fn validate_attempt_state(
    record: &TaskBoardExecutionAttemptRecord,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    match record.state {
        TaskBoardAttemptState::Completed => {
            if record.artifact.is_none() || record.completed_at.is_none() {
                return invalid("attempt.state", "completed attempt lacks result evidence");
            }
        }
        TaskBoardAttemptState::Failed => {
            if record.completed_at.is_none() || record.failure_class.is_none() {
                return invalid(
                    "attempt.state",
                    "failed attempt lacks completion time or failure class",
                );
            }
        }
        TaskBoardAttemptState::Cancelled => {
            if record.completed_at.is_none() {
                return invalid("attempt.state", "terminal attempt lacks completion time");
            }
        }
        TaskBoardAttemptState::RetryWait => {
            if record.available_at.is_none() || record.failure_class.is_none() {
                return invalid("attempt.state", "retry lacks schedule or failure class");
            }
        }
        TaskBoardAttemptState::Unknown => {
            if record.failure_class != Some(TaskBoardFailureClass::UnknownOutcome)
                || record.artifact.is_some()
            {
                return invalid("attempt.state", "unknown outcome cannot claim a result");
            }
        }
        TaskBoardAttemptState::Preparing
        | TaskBoardAttemptState::Starting
        | TaskBoardAttemptState::Running => {
            if record.completed_at.is_some() {
                return invalid("attempt.state", "nonterminal attempt has completion time");
            }
        }
    }
    Ok(())
}

fn attempt_transition_allowed(
    current: TaskBoardAttemptState,
    updated: TaskBoardAttemptState,
) -> bool {
    current == updated
        || matches!(
            (current, updated),
            (
                TaskBoardAttemptState::Preparing,
                TaskBoardAttemptState::Starting
                    | TaskBoardAttemptState::Running
                    | TaskBoardAttemptState::RetryWait
                    | TaskBoardAttemptState::Completed
                    | TaskBoardAttemptState::Failed
                    | TaskBoardAttemptState::Cancelled
                    | TaskBoardAttemptState::Unknown
            ) | (
                TaskBoardAttemptState::Starting,
                TaskBoardAttemptState::Running
                    | TaskBoardAttemptState::RetryWait
                    | TaskBoardAttemptState::Completed
                    | TaskBoardAttemptState::Failed
                    | TaskBoardAttemptState::Cancelled
                    | TaskBoardAttemptState::Unknown
            ) | (
                TaskBoardAttemptState::Running,
                TaskBoardAttemptState::RetryWait
                    | TaskBoardAttemptState::Completed
                    | TaskBoardAttemptState::Failed
                    | TaskBoardAttemptState::Cancelled
                    | TaskBoardAttemptState::Unknown
            )
        )
}

const fn attempt_state_is_terminal(state: TaskBoardAttemptState) -> bool {
    matches!(
        state,
        TaskBoardAttemptState::RetryWait
            | TaskBoardAttemptState::Completed
            | TaskBoardAttemptState::Failed
            | TaskBoardAttemptState::Cancelled
            | TaskBoardAttemptState::Unknown
    )
}

fn required(
    value: &str,
    field: &'static str,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    if value.trim().is_empty() {
        invalid(field, "must not be empty")
    } else {
        Ok(())
    }
}

fn validate_optional_timestamp(
    value: Option<&str>,
    field: &'static str,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    value.map_or(Ok(()), |value| validate_timestamp(value, field))
}

fn validate_timestamp(
    value: &str,
    field: &'static str,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    DateTime::parse_from_rfc3339(value)
        .map(|_| ())
        .map_err(|error| field_error(field, error))
}

fn parse_timestamp(
    value: &str,
) -> Result<DateTime<Utc>, TaskBoardWorkflowExecutionValidationError> {
    DateTime::parse_from_rfc3339(value)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| field_error("timestamp", error))
}

fn immutable(
    unchanged: bool,
    field: &'static str,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    if unchanged {
        Ok(())
    } else {
        Err(TaskBoardWorkflowExecutionValidationError::ImmutableField { field })
    }
}

fn invalid<T>(
    field: &'static str,
    detail: impl Into<String>,
) -> Result<T, TaskBoardWorkflowExecutionValidationError> {
    Err(TaskBoardWorkflowExecutionValidationError::InvalidField {
        field,
        detail: detail.into(),
    })
}

fn field_error(
    field: &'static str,
    error: impl Display,
) -> TaskBoardWorkflowExecutionValidationError {
    TaskBoardWorkflowExecutionValidationError::InvalidField {
        field,
        detail: error.to_string(),
    }
}
