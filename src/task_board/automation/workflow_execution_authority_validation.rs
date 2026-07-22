use super::{
    TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE, TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE,
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TASK_BOARD_REMOTE_CANCEL_INTENT_AT_RESOURCE,
    TASK_BOARD_REMOTE_CANCEL_INTENT_REASON_RESOURCE, TASK_BOARD_REMOTE_CANCEL_INTENT_RESOURCE,
    TASK_BOARD_REMOTE_CANCEL_IO_AUTHORITY_RESOURCE, TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE,
    TASK_BOARD_REMOTE_OFFER_IO_AUTHORITY_RESOURCE, TASK_BOARD_REMOTE_RENEW_IO_AUTHORITY_RESOURCE,
    TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE, TaskBoardAttemptState,
    TaskBoardExecutionState, TaskBoardWorkflowExecutionRecord,
    TaskBoardWorkflowExecutionValidationError,
};

pub(super) fn validate_remote_io_authority(
    record: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    let offer = record
        .ownership
        .resources
        .get(TASK_BOARD_REMOTE_OFFER_IO_AUTHORITY_RESOURCE);
    let claim = record
        .ownership
        .resources
        .get(TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE);
    let renew = record
        .ownership
        .resources
        .get(TASK_BOARD_REMOTE_RENEW_IO_AUTHORITY_RESOURCE);
    let cancel = record
        .ownership
        .resources
        .get(TASK_BOARD_REMOTE_CANCEL_IO_AUTHORITY_RESOURCE);
    let cancel_intent = cancel_intent(record)?;
    let result_import = record
        .ownership
        .resources
        .get(TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE);
    let authorities = [offer, claim, renew, cancel, result_import]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>();
    let digest = match authorities.as_slice() {
        [] => return Ok(()),
        [digest] => *digest,
        _ => {
            return invalid("remote I/O authorities are mutually exclusive");
        }
    };
    if digest.len() != 64
        || digest
            .bytes()
            .any(|byte| !byte.is_ascii_digit() && !(b'a'..=b'f').contains(&byte))
    {
        return invalid("remote I/O authority must be a lowercase SHA-256 digest");
    }
    let remote_target = record
        .ownership
        .resources
        .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
        .and_then(|target| target.strip_prefix("remote:"))
        .is_some_and(|assignment| !assignment.trim().is_empty());
    let action = record
        .ownership
        .resources
        .get(TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE);
    let attempt = record
        .ownership
        .resources
        .get(TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE)
        .and_then(|attempt| attempt.parse::<u32>().ok())
        .filter(|attempt| *attempt > 0);
    let running_authority = renew.is_some()
        || (cancel.is_some()
            && record.transition.execution_state == TaskBoardExecutionState::Running);
    let exact_attempt = action.zip(attempt).is_some_and(|(action, attempt)| {
        if result_import.is_some() {
            exact_unique_import_attempt(record, action, attempt)
        } else {
            let required = if running_authority {
                TaskBoardAttemptState::Running
            } else {
                TaskBoardAttemptState::Starting
            };
            exact_unique_active_attempt(record, action, attempt, required)
        }
    });
    let exact_execution_state = if result_import.is_some() {
        matches!(
            record.transition.execution_state,
            TaskBoardExecutionState::Starting | TaskBoardExecutionState::Running
        )
    } else if running_authority {
        record.transition.execution_state == TaskBoardExecutionState::Running
    } else {
        record.transition.execution_state == TaskBoardExecutionState::Starting
    };
    if !exact_execution_state
        || record
            .ownership
            .host_id
            .as_deref()
            .is_none_or(|host| host.trim().is_empty())
        || !remote_target
        || !exact_attempt
    {
        return invalid("remote I/O authority requires the exact active remote target");
    }
    if cancel
        .zip(cancel_intent.as_ref())
        .is_some_and(|(digest, intent)| digest != intent.0)
    {
        return invalid("remote cancel authority must match its exact durable intent");
    }
    Ok(())
}

fn cancel_intent(
    record: &TaskBoardWorkflowExecutionRecord,
) -> Result<Option<(&str, &str, &str)>, TaskBoardWorkflowExecutionValidationError> {
    let digest = record
        .ownership
        .resources
        .get(TASK_BOARD_REMOTE_CANCEL_INTENT_RESOURCE)
        .map(String::as_str);
    let reason = record
        .ownership
        .resources
        .get(TASK_BOARD_REMOTE_CANCEL_INTENT_REASON_RESOURCE)
        .map(String::as_str);
    let requested_at = record
        .ownership
        .resources
        .get(TASK_BOARD_REMOTE_CANCEL_INTENT_AT_RESOURCE)
        .map(String::as_str);
    let intent = match (digest, reason, requested_at) {
        (None, None, None) => return Ok(None),
        (Some(digest), Some(reason), Some(requested_at)) => (digest, reason, requested_at),
        _ => return invalid("remote cancel intent evidence must be all present or all absent"),
    };
    if !lower_hex_digest(intent.0) {
        return invalid("remote cancel intent must be a lowercase SHA-256 digest");
    }
    if intent.1.trim().is_empty() || intent.1.len() > 4_096 {
        return invalid("remote cancel intent reason must be nonblank and bounded");
    }
    if chrono::DateTime::parse_from_rfc3339(intent.2).is_err() {
        return invalid("remote cancel intent time must be RFC 3339");
    }
    if record.transition.execution_state != TaskBoardExecutionState::Running
        || !exact_target_attempt(record, TaskBoardAttemptState::Running)
    {
        return invalid("remote cancel intent requires the exact running remote target");
    }
    Ok(Some(intent))
}

fn exact_target_attempt(
    record: &TaskBoardWorkflowExecutionRecord,
    required_state: TaskBoardAttemptState,
) -> bool {
    let action = record
        .ownership
        .resources
        .get(TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE);
    let attempt = record
        .ownership
        .resources
        .get(TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE)
        .and_then(|value| value.parse::<u32>().ok());
    action.zip(attempt).is_some_and(|(action, attempt)| {
        exact_unique_active_attempt(record, action, attempt, required_state)
    })
}

fn lower_hex_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn exact_unique_import_attempt(
    record: &TaskBoardWorkflowExecutionRecord,
    action: &str,
    attempt: u32,
) -> bool {
    let mut active = record.attempts.iter().filter(|candidate| {
        matches!(
            candidate.state,
            TaskBoardAttemptState::Preparing
                | TaskBoardAttemptState::Starting
                | TaskBoardAttemptState::Running
        )
    });
    active.next().is_some_and(|candidate| {
        candidate.action_key == action
            && candidate.attempt == attempt
            && matches!(
                candidate.state,
                TaskBoardAttemptState::Starting | TaskBoardAttemptState::Running
            )
            && action.starts_with("implementation:")
    }) && active.next().is_none()
}

fn exact_unique_active_attempt(
    record: &TaskBoardWorkflowExecutionRecord,
    action: &str,
    attempt: u32,
    required_state: TaskBoardAttemptState,
) -> bool {
    let mut active = record.attempts.iter().filter(|candidate| {
        matches!(
            candidate.state,
            TaskBoardAttemptState::Preparing
                | TaskBoardAttemptState::Starting
                | TaskBoardAttemptState::Running
        )
    });
    active.next().is_some_and(|candidate| {
        candidate.action_key == action
            && candidate.attempt == attempt
            && candidate.state == required_state
    }) && active.next().is_none()
}

fn invalid<T>(detail: &'static str) -> Result<T, TaskBoardWorkflowExecutionValidationError> {
    Err(TaskBoardWorkflowExecutionValidationError::InvalidField {
        field: "ownership.resources",
        detail: detail.into(),
    })
}
