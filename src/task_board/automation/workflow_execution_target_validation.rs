use std::collections::BTreeSet;

use super::{
    TaskBoardAttemptState, TaskBoardExecutionAttemptRecord, TaskBoardExecutionPhase,
    TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowExecutionValidationError,
    validate_task_board_attempt_update, validate_task_board_execution_update,
    validate_task_board_workflow_execution,
};

#[path = "workflow_execution_target_legacy.rs"]
mod legacy;
pub use legacy::{
    TASK_BOARD_LEGACY_LOCAL_TARGET_ACTION_RESOURCE,
    TASK_BOARD_LEGACY_LOCAL_TARGET_ADOPTION_RESOURCE, TASK_BOARD_LEGACY_LOCAL_TARGET_ADOPTION_V43,
    TASK_BOARD_LEGACY_LOCAL_TARGET_ATTEMPT_RESOURCE,
    TASK_BOARD_LEGACY_LOCAL_TARGET_IDEMPOTENCY_RESOURCE,
    validate_task_board_legacy_local_target_adoption,
};

pub const TASK_BOARD_EXECUTION_TARGET_RESOURCE: &str = "execution_target";
pub const TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE: &str = "execution_target_action_key";
pub const TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE: &str = "execution_target_attempt";
pub const TASK_BOARD_REMOTE_OFFER_IO_AUTHORITY_RESOURCE: &str = "remote_offer_io_authority";
pub const TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE: &str = "remote_claim_io_authority";
pub const TASK_BOARD_REMOTE_RENEW_IO_AUTHORITY_RESOURCE: &str = "remote_renew_io_authority";
pub const TASK_BOARD_REMOTE_CANCEL_IO_AUTHORITY_RESOURCE: &str = "remote_cancel_io_authority";
pub const TASK_BOARD_REMOTE_CANCEL_INTENT_RESOURCE: &str = "remote_cancel_intent";
pub const TASK_BOARD_REMOTE_CANCEL_INTENT_REASON_RESOURCE: &str = "remote_cancel_intent_reason";
pub const TASK_BOARD_REMOTE_CANCEL_INTENT_AT_RESOURCE: &str = "remote_cancel_intent_at";
pub const TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE: &str =
    "remote_result_import_authority";

/// Return the fenced remote assignment target, if this execution is remote-owned.
#[must_use]
pub fn task_board_remote_execution_target(
    record: &TaskBoardWorkflowExecutionRecord,
) -> Option<&str> {
    record
        .ownership
        .resources
        .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
        .and_then(|target| target.strip_prefix("remote:"))
        .filter(|assignment_id| nonblank(assignment_id))
}

/// Validate the narrow ownership mutation used to fence one local or remote attempt target.
///
/// All ordinary execution fields retain the stricter immutable-update contract. Only the three
/// target resource keys, `host_id`, and the monotonic remote fencing epoch may change.
///
/// # Errors
///
/// Returns an error when non-target execution evidence changes or the target binding is malformed.
pub fn validate_task_board_execution_target_update(
    current: &TaskBoardWorkflowExecutionRecord,
    updated: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    validate_target_update(current, updated, false)
}

/// Like [`validate_task_board_execution_target_update`], but admits a claim binding an attempt that
/// is already `Starting` without a prior target: publish and cleanup skip remote target selection,
/// and pre-target `Starting` attempts survive a schema upgrade. Other target rules are unchanged.
///
/// # Errors
///
/// Returns an error when the bound attempt is not the sole active attempt of the current phase, or
/// the update otherwise violates ordinary execution or target invariants.
pub fn validate_task_board_execution_target_claim(
    current: &TaskBoardWorkflowExecutionRecord,
    updated: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    validate_target_update(current, updated, true)
}

/// Validate the one pre-claim remote generation reassignment boundary.
///
/// This deliberately does not weaken ordinary target immutability. Persistence may call it only
/// after atomically proving that the predecessor offer has no receipt, lease, claim, worker, or
/// I/O-authority evidence and that the executor durably abandoned that exact generation.
///
/// # Errors
///
/// Returns an error unless the same exact `Starting` attempt moves from one remote assignment to
/// a distinct remote assignment at the next fencing epoch on the same configured host.
pub fn validate_task_board_remote_target_reassignment(
    current: &TaskBoardWorkflowExecutionRecord,
    updated: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    let current_identity = target_identity(current)?.ok_or_else(|| {
        TaskBoardWorkflowExecutionValidationError::InvalidField {
            field: "ownership.resources",
            detail: "remote reassignment requires an existing target".into(),
        }
    })?;
    let updated_identity = target_identity(updated)?.ok_or_else(|| {
        TaskBoardWorkflowExecutionValidationError::InvalidField {
            field: "ownership.resources",
            detail: "remote reassignment requires a replacement target".into(),
        }
    })?;
    let current_target = required_target(current, TASK_BOARD_EXECUTION_TARGET_RESOURCE)?;
    let updated_target = required_target(updated, TASK_BOARD_EXECUTION_TARGET_RESOURCE)?;
    let expected_epoch = current.ownership.fencing_epoch.checked_add(1);
    let exact = current_identity == updated_identity
        && current_target.strip_prefix("remote:").is_some_and(nonblank)
        && updated_target.strip_prefix("remote:").is_some_and(nonblank)
        && current_target != updated_target
        && current.ownership.host_id == updated.ownership.host_id
        && current.ownership.host_id.is_some()
        && Some(updated.ownership.fencing_epoch) == expected_epoch
        && current.transition.execution_state == super::TaskBoardExecutionState::Starting
        && updated.transition.execution_state == super::TaskBoardExecutionState::Starting
        && current.attempts == updated.attempts
        && exact_attempt(current, current_identity.0, current_identity.1)?.state
            == TaskBoardAttemptState::Starting
        && !has_remote_io_authority(current)
        && !has_remote_io_authority(updated);
    if !exact {
        return invalid(
            "ownership",
            "remote reassignment requires one exact unclaimed Starting attempt generation",
        );
    }
    validate_unchanged_resources(current, updated)?;
    let mut ordinary = updated.clone();
    ordinary.ownership = current.ownership.clone();
    validate_task_board_execution_update(current, &ordinary)?;
    validate_task_board_workflow_execution(updated)
}

fn validate_target_update(
    current: &TaskBoardWorkflowExecutionRecord,
    updated: &TaskBoardWorkflowExecutionRecord,
    allow_legacy_starting: bool,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    let mut ordinary_update = updated.clone();
    ordinary_update.ownership = current.ownership.clone();
    ordinary_update.attempts.clone_from(&current.attempts);
    if allow_legacy_starting
        && current.transition.execution_state == super::TaskBoardExecutionState::Running
        && updated.transition.execution_state == super::TaskBoardExecutionState::Starting
    {
        ordinary_update.transition.execution_state = super::TaskBoardExecutionState::Running;
    }
    validate_task_board_execution_update(current, &ordinary_update)?;
    validate_task_board_workflow_execution(updated)?;
    let current_target = target_identity(current)?;
    let updated_target = target_identity(updated)?.ok_or_else(|| {
        TaskBoardWorkflowExecutionValidationError::InvalidField {
            field: "ownership.resources",
            detail: "target binding is required".into(),
        }
    })?;
    if current_target != Some(updated_target) && has_remote_io_authority(updated) {
        return invalid(
            "ownership.resources",
            "target binding cannot claim remote I/O authority",
        );
    }
    if current_target == Some(updated_target) {
        if current.ownership != updated.ownership {
            return invalid("ownership", "execution target is immutable once assigned");
        }
        return validate_bound_attempt(current, updated, false, None, false);
    }
    let previous = if let Some(previous) = current_target {
        let current_prior = exact_attempt(current, previous.0, previous.1)?;
        let updated_prior = exact_attempt(updated, previous.0, previous.1)?;
        validate_task_board_attempt_update(current_prior, updated_prior)?;
        if active(updated_prior) {
            return invalid("ownership", "active attempt target cannot be rebound");
        }
        Some(previous)
    } else {
        None
    };
    validate_unchanged_resources(current, updated)?;
    let target = required_target(updated, TASK_BOARD_EXECUTION_TARGET_RESOURCE)?;
    validate_bound_attempt(current, updated, true, previous, allow_legacy_starting)?;
    if target == "local" {
        validate_local_target(current, updated)
    } else if target.strip_prefix("remote:").is_some_and(nonblank) {
        validate_remote_target(current, updated)
    } else {
        invalid(
            "ownership.resources.execution_target",
            "must be local or a bound remote assignment",
        )
    }
}

fn target_identity(
    record: &TaskBoardWorkflowExecutionRecord,
) -> Result<Option<(&str, u32)>, TaskBoardWorkflowExecutionValidationError> {
    let any = record.ownership.host_id.is_some()
        || [
            TASK_BOARD_EXECUTION_TARGET_RESOURCE,
            TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE,
            TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE,
        ]
        .iter()
        .any(|key| record.ownership.resources.contains_key(*key));
    if !any {
        return Ok(None);
    }
    let action = required_target(record, TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE)?;
    let attempt = parse_target_attempt(record)?;
    required_target(record, TASK_BOARD_EXECUTION_TARGET_RESOURCE)?;
    Ok(Some((action, attempt)))
}

fn validate_bound_attempt(
    current: &TaskBoardWorkflowExecutionRecord,
    updated: &TaskBoardWorkflowExecutionRecord,
    new_binding: bool,
    previous: Option<(&str, u32)>,
    allow_legacy_starting: bool,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    let action = required_target(updated, TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE)?;
    let attempt_number = parse_target_attempt(updated)?;
    let updated_attempt = exact_attempt(updated, action, attempt_number)?;
    let current_attempt = current
        .attempts
        .iter()
        .find(|attempt| attempt.action_key == action && attempt.attempt == attempt_number);
    if let Some(current_attempt) = current_attempt {
        validate_task_board_attempt_update(current_attempt, updated_attempt)?;
        if (new_binding
            && current_attempt.state != TaskBoardAttemptState::Preparing
            && !(allow_legacy_starting && current_attempt.state == TaskBoardAttemptState::Starting))
            || (!new_binding && !active(current_attempt))
        {
            return invalid(
                "ownership.resources",
                "target must bind the exact active attempt in the current phase",
            );
        }
    } else if !new_binding || updated_attempt.state != TaskBoardAttemptState::Starting {
        return invalid(
            "ownership.resources",
            "new local fallback target must be atomically inserted in Starting",
        );
    }
    if !matches!(
        updated_attempt.state,
        TaskBoardAttemptState::Starting | TaskBoardAttemptState::Running
    ) || current
        .attempts
        .iter()
        .filter(|attempt| active(attempt))
        .count()
        != 1
        || updated
            .attempts
            .iter()
            .filter(|attempt| active(attempt))
            .count()
            != 1
        || !action_matches_phase(current, action)
        || !attempt_changes_are_bounded(current, updated, (action, attempt_number), previous)
    {
        return invalid(
            "ownership.resources",
            "target must bind the exact active attempt in the current phase",
        );
    }
    Ok(())
}

fn attempt_changes_are_bounded(
    current: &TaskBoardWorkflowExecutionRecord,
    updated: &TaskBoardWorkflowExecutionRecord,
    target: (&str, u32),
    previous: Option<(&str, u32)>,
) -> bool {
    let inserted_target = !current
        .attempts
        .iter()
        .any(|attempt| identity(attempt) == target);
    if updated.attempts.len() != current.attempts.len() + usize::from(inserted_target) {
        return false;
    }
    current.attempts.iter().all(|before| {
        updated
            .attempts
            .iter()
            .find(|after| identity(after) == identity(before))
            .is_some_and(|after| {
                before == after || identity(before) == target || previous == Some(identity(before))
            })
    }) && updated.attempts.iter().all(|after| {
        current
            .attempts
            .iter()
            .any(|before| identity(before) == identity(after))
            || (inserted_target && identity(after) == target)
    })
}

fn identity(attempt: &TaskBoardExecutionAttemptRecord) -> (&str, u32) {
    (&attempt.action_key, attempt.attempt)
}

fn parse_target_attempt(
    record: &TaskBoardWorkflowExecutionRecord,
) -> Result<u32, TaskBoardWorkflowExecutionValidationError> {
    required_target(record, TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE)?
        .parse::<u32>()
        .ok()
        .filter(|value| *value > 0)
        .ok_or_else(|| TaskBoardWorkflowExecutionValidationError::InvalidField {
            field: "ownership.resources.execution_target_attempt",
            detail: "must be non-zero".into(),
        })
}

fn exact_attempt<'a>(
    record: &'a TaskBoardWorkflowExecutionRecord,
    action: &str,
    attempt: u32,
) -> Result<&'a TaskBoardExecutionAttemptRecord, TaskBoardWorkflowExecutionValidationError> {
    record
        .attempts
        .iter()
        .find(|candidate| candidate.action_key == action && candidate.attempt == attempt)
        .ok_or_else(|| TaskBoardWorkflowExecutionValidationError::InvalidField {
            field: "ownership.resources",
            detail: "target attempt does not exist".into(),
        })
}

const fn active(attempt: &TaskBoardExecutionAttemptRecord) -> bool {
    matches!(
        attempt.state,
        TaskBoardAttemptState::Preparing
            | TaskBoardAttemptState::Starting
            | TaskBoardAttemptState::Running
    )
}

fn action_matches_phase(record: &TaskBoardWorkflowExecutionRecord, action: &str) -> bool {
    match record.transition.phase {
        Some(TaskBoardExecutionPhase::Implementation) => {
            action == format!("implementation:{}", record.artifacts.current_revision_cycle)
        }
        Some(TaskBoardExecutionPhase::Review) => action.starts_with("review:") && action.len() > 7,
        Some(TaskBoardExecutionPhase::Evaluate) => {
            action == "evaluate"
                || action == format!("evaluate:{}", record.artifacts.current_revision_cycle)
        }
        Some(TaskBoardExecutionPhase::Publish) => action == "publish",
        Some(TaskBoardExecutionPhase::Cleanup) => action == "cleanup",
        _ => false,
    }
}

fn validate_unchanged_resources(
    current: &TaskBoardWorkflowExecutionRecord,
    updated: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    let target_keys = BTreeSet::from([
        TASK_BOARD_EXECUTION_TARGET_RESOURCE,
        TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE,
        TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE,
        TASK_BOARD_LEGACY_LOCAL_TARGET_ADOPTION_RESOURCE,
        TASK_BOARD_LEGACY_LOCAL_TARGET_ACTION_RESOURCE,
        TASK_BOARD_LEGACY_LOCAL_TARGET_ATTEMPT_RESOURCE,
        TASK_BOARD_LEGACY_LOCAL_TARGET_IDEMPOTENCY_RESOURCE,
        TASK_BOARD_REMOTE_OFFER_IO_AUTHORITY_RESOURCE,
        TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE,
        TASK_BOARD_REMOTE_RENEW_IO_AUTHORITY_RESOURCE,
        TASK_BOARD_REMOTE_CANCEL_IO_AUTHORITY_RESOURCE,
        TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE,
    ]);
    let keys = current
        .ownership
        .resources
        .keys()
        .chain(updated.ownership.resources.keys())
        .map(String::as_str)
        .filter(|key| !target_keys.contains(key))
        .collect::<BTreeSet<_>>();
    if keys
        .iter()
        .any(|key| current.ownership.resources.get(*key) != updated.ownership.resources.get(*key))
    {
        return invalid("ownership.resources", "non-target ownership changed");
    }
    Ok(())
}

fn required_target<'a>(
    record: &'a TaskBoardWorkflowExecutionRecord,
    key: &'static str,
) -> Result<&'a str, TaskBoardWorkflowExecutionValidationError> {
    record
        .ownership
        .resources
        .get(key)
        .map(String::as_str)
        .filter(|value| nonblank(value))
        .ok_or_else(|| TaskBoardWorkflowExecutionValidationError::InvalidField {
            field: "ownership.resources",
            detail: format!("target binding '{key}' is required"),
        })
}

fn validate_local_target(
    current: &TaskBoardWorkflowExecutionRecord,
    updated: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    if updated.ownership.host_id.is_some()
        || updated.ownership.fencing_epoch != current.ownership.fencing_epoch
    {
        return invalid(
            "ownership",
            "local target cannot claim a host or change the fencing epoch",
        );
    }
    Ok(())
}

fn validate_remote_target(
    current: &TaskBoardWorkflowExecutionRecord,
    updated: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    if updated
        .ownership
        .host_id
        .as_deref()
        .is_none_or(|host| !nonblank(host))
        || current
            .ownership
            .fencing_epoch
            .checked_add(1)
            .is_none_or(|epoch| updated.ownership.fencing_epoch != epoch)
    {
        return invalid(
            "ownership",
            "new remote target requires a host and the next fencing epoch",
        );
    }
    Ok(())
}

fn nonblank(value: &str) -> bool {
    !value.trim().is_empty()
}

fn has_remote_io_authority(record: &TaskBoardWorkflowExecutionRecord) -> bool {
    record
        .ownership
        .resources
        .contains_key(TASK_BOARD_REMOTE_OFFER_IO_AUTHORITY_RESOURCE)
        || record
            .ownership
            .resources
            .contains_key(TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE)
        || record
            .ownership
            .resources
            .contains_key(TASK_BOARD_REMOTE_RENEW_IO_AUTHORITY_RESOURCE)
        || record
            .ownership
            .resources
            .contains_key(TASK_BOARD_REMOTE_CANCEL_IO_AUTHORITY_RESOURCE)
        || record
            .ownership
            .resources
            .contains_key(TASK_BOARD_REMOTE_RESULT_IMPORT_AUTHORITY_RESOURCE)
}

fn invalid<T>(
    field: &'static str,
    detail: &'static str,
) -> Result<T, TaskBoardWorkflowExecutionValidationError> {
    Err(TaskBoardWorkflowExecutionValidationError::InvalidField {
        field,
        detail: detail.into(),
    })
}
