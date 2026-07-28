use super::workflow_write_validation_tests::{implementation_attempt, write_execution};
use super::*;

const NOW: &str = "2026-07-18T10:00:00Z";

#[test]
fn target_is_immutable_for_the_bound_active_attempt() {
    let current = targetable_execution();
    let local = target_candidate(&current, "local", None, 0, "implementation:1", 1);
    validate_task_board_execution_target_update(&current, &local).expect("first local target");

    let mut rebound = local.clone();
    rebound.ownership.resources.insert(
        TASK_BOARD_EXECUTION_TARGET_RESOURCE.into(),
        "remote:assignment-2".into(),
    );
    rebound.ownership.host_id = Some("host-2".into());
    rebound.ownership.fencing_epoch = 1;
    let error = validate_task_board_execution_target_update(&local, &rebound)
        .expect_err("active attempt target must be immutable");
    assert_eq!(
        error,
        TaskBoardWorkflowExecutionValidationError::InvalidField {
            field: "ownership",
            detail: "execution target is immutable once assigned".into(),
        }
    );
}

#[test]
fn target_rejects_a_different_action_or_attempt() {
    let current = targetable_execution();
    let mut wrong_action = target_candidate(&current, "local", None, 0, "implementation:1", 1);
    wrong_action.ownership.resources.insert(
        TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE.into(),
        "evaluate:1".into(),
    );
    assert!(validate_task_board_execution_target_update(&current, &wrong_action).is_err());

    let mut wrong_attempt = target_candidate(&current, "local", None, 0, "implementation:1", 1);
    wrong_attempt.ownership.resources.insert(
        TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE.into(),
        "2".into(),
    );
    assert!(validate_task_board_execution_target_update(&current, &wrong_attempt).is_err());
}

#[test]
fn target_binding_cannot_forge_remote_io_authority() {
    let current = targetable_execution();
    let mut remote = target_candidate(
        &current,
        "remote:assignment-1",
        Some("host-1"),
        1,
        "implementation:1",
        1,
    );
    remote.ownership.resources.insert(
        TASK_BOARD_REMOTE_OFFER_IO_AUTHORITY_RESOURCE.into(),
        "a".repeat(64),
    );

    let error = validate_task_board_execution_target_update(&current, &remote)
        .expect_err("target binding must not mint transport authority");
    assert_eq!(
        error,
        TaskBoardWorkflowExecutionValidationError::InvalidField {
            field: "ownership.resources",
            detail: "target binding cannot claim remote I/O authority".into(),
        }
    );
}

#[test]
fn persisted_remote_io_authority_is_strictly_bound_to_one_starting_target() {
    let current = targetable_execution();
    let mut valid = target_candidate(
        &current,
        "remote:assignment-1",
        Some("host-1"),
        1,
        "implementation:1",
        1,
    );
    valid.ownership.resources.insert(
        TASK_BOARD_REMOTE_OFFER_IO_AUTHORITY_RESOURCE.into(),
        "a".repeat(64),
    );
    validate_task_board_workflow_execution(&valid).expect("valid remote authority");

    let mut malformed = valid.clone();
    malformed.ownership.resources.insert(
        TASK_BOARD_REMOTE_OFFER_IO_AUTHORITY_RESOURCE.into(),
        "ABC".into(),
    );
    assert!(validate_task_board_workflow_execution(&malformed).is_err());

    let mut both = valid.clone();
    both.ownership.resources.insert(
        TASK_BOARD_REMOTE_CLAIM_IO_AUTHORITY_RESOURCE.into(),
        "b".repeat(64),
    );
    assert!(validate_task_board_workflow_execution(&both).is_err());

    let mut running = valid.clone();
    running.transition.execution_state = TaskBoardExecutionState::Running;
    running.attempts[0].state = TaskBoardAttemptState::Running;
    assert!(validate_task_board_workflow_execution(&running).is_err());

    let mut local = valid;
    local
        .ownership
        .resources
        .insert(TASK_BOARD_EXECUTION_TARGET_RESOURCE.into(), "local".into());
    local.ownership.host_id = None;
    assert!(validate_task_board_workflow_execution(&local).is_err());
}

#[test]
fn persisted_remote_io_authority_rejects_a_second_active_attempt() {
    let current = targetable_execution();
    let mut record = target_candidate(
        &current,
        "remote:assignment-1",
        Some("host-1"),
        1,
        "implementation:1",
        1,
    );
    record.ownership.resources.insert(
        TASK_BOARD_REMOTE_OFFER_IO_AUTHORITY_RESOURCE.into(),
        "a".repeat(64),
    );
    record.attempts.push(preparing_attempt(
        &record.execution_id,
        "implementation:1",
        2,
    ));

    let error = validate_task_board_workflow_execution(&record)
        .expect_err("authority must fence one unique active attempt");
    assert_eq!(
        error,
        TaskBoardWorkflowExecutionValidationError::InvalidField {
            field: "ownership.resources",
            detail: "remote I/O authority requires the exact active remote target".into(),
        }
    );
}

#[test]
fn terminal_attempt_allows_a_monotonic_retry_target() {
    let mut current = targetable_execution();
    current.attempts[0].state = TaskBoardAttemptState::Failed;
    current.attempts[0].failure_class = Some(TaskBoardFailureClass::Transient);
    current.attempts[0].completed_at = Some(NOW.into());
    bind_target(&mut current, "local", None, 0, "implementation:1", 1);
    current.attempts.push(preparing_attempt(
        &current.execution_id,
        "implementation:1",
        2,
    ));

    let remote = target_candidate(
        &current,
        "remote:assignment-retry",
        Some("host-retry"),
        1,
        "implementation:1",
        2,
    );

    validate_task_board_execution_target_update(&current, &remote)
        .expect("new attempt gets a new monotonic target");
}

#[test]
fn terminal_phase_target_allows_the_next_phase_attempt() {
    let mut current = write_execution();
    current.transition.phase = Some(TaskBoardExecutionPhase::Review);
    current.transition.execution_state = TaskBoardExecutionState::Preparing;
    current.transition.exact_head_revision = Some("head-result".into());
    current.attempts.push(implementation_attempt(1));
    bind_target(&mut current, "local", None, 0, "implementation:1", 1);
    current.attempts.push(preparing_attempt(
        &current.execution_id,
        "review:reviewer-1",
        1,
    ));

    let review = target_candidate(
        &current,
        "remote:assignment-review",
        Some("host-review"),
        1,
        "review:reviewer-1",
        1,
    );

    validate_task_board_execution_target_update(&current, &review)
        .expect("new phase gets its own target");
}

#[test]
fn rejected_remote_attempt_can_atomically_bind_one_local_fallback() {
    let current = target_candidate(
        &targetable_execution(),
        "remote:assignment-rejected",
        Some("host-rejected"),
        4,
        "implementation:1",
        1,
    );
    let mut updated = current.clone();
    updated.attempts[0].state = TaskBoardAttemptState::Failed;
    updated.attempts[0].failure_class = Some(TaskBoardFailureClass::Transient);
    updated.attempts[0].error = Some("remote offer rejected".into());
    updated.attempts[0].completed_at = Some(NOW.into());
    updated.attempts.push(preparing_attempt(
        &current.execution_id,
        "implementation:1",
        2,
    ));
    updated.attempts[1].state = TaskBoardAttemptState::Starting;
    bind_target(&mut updated, "local", None, 4, "implementation:1", 2);

    validate_task_board_execution_target_update(&current, &updated)
        .expect("rejected remote attempt atomically binds local fallback");
    assert!(updated.ownership.host_id.is_none());
    assert_eq!(updated.ownership.fencing_epoch, 4);
}

#[test]
fn exact_preclaim_remote_generation_can_reassign_without_weakening_ordinary_updates() {
    let current = target_candidate(
        &targetable_execution(),
        "remote:assignment-predecessor",
        Some("host-restarted"),
        4,
        "implementation:1",
        1,
    );
    let mut updated = current.clone();
    updated.ownership.fencing_epoch = 5;
    updated.ownership.resources.insert(
        TASK_BOARD_EXECUTION_TARGET_RESOURCE.into(),
        "remote:assignment-current".into(),
    );

    validate_task_board_execution_target_update(&current, &updated)
        .expect_err("ordinary target update remains immutable");
    validate_task_board_remote_target_reassignment(&current, &updated)
        .expect("dedicated preclaim generation reassignment");

    let mut wrong_attempt = updated.clone();
    wrong_attempt.attempts[0].state = TaskBoardAttemptState::Running;
    validate_task_board_remote_target_reassignment(&current, &wrong_attempt)
        .expect_err("reassignment cannot change or revive the attempt");
}

#[test]
fn legacy_targetless_starting_attempt_has_one_explicit_local_adoption_path() {
    for parent_state in [
        TaskBoardExecutionState::Pending,
        TaskBoardExecutionState::Starting,
        TaskBoardExecutionState::Running,
    ] {
        let mut current = targetable_execution();
        current.transition.execution_state = parent_state;
        current.attempts[0].state = TaskBoardAttemptState::Starting;
        mark_legacy_local_adoption(&mut current, 0);
        let mut updated = target_candidate(&current, "local", None, 0, "implementation:1", 1);
        updated.attempts[0].state = TaskBoardAttemptState::Running;
        clear_legacy_local_adoption(&mut updated);

        validate_task_board_execution_target_update(&current, &updated)
            .expect_err("ordinary target binding stays Preparing-only");
        validate_task_board_legacy_local_target_adoption(&current, &updated)
            .expect("legacy Starting attempt adopts exactly one local target");
    }

    let mut already_bound = targetable_execution();
    already_bound.transition.execution_state = TaskBoardExecutionState::Starting;
    already_bound.attempts[0].state = TaskBoardAttemptState::Starting;
    mark_legacy_local_adoption(&mut already_bound, 0);
    bind_target(
        &mut already_bound,
        "remote:assignment-existing",
        Some("host-existing"),
        1,
        "implementation:1",
        1,
    );
    let mut updated = already_bound.clone();
    updated.attempts[0].state = TaskBoardAttemptState::Running;
    validate_task_board_legacy_local_target_adoption(&already_bound, &updated)
        .expect_err("legacy adoption cannot replace an existing target");

    let mut targetless = targetable_execution();
    targetless.transition.execution_state = TaskBoardExecutionState::Starting;
    targetless.attempts[0].state = TaskBoardAttemptState::Starting;
    let mut unmarked = target_candidate(&targetless, "local", None, 0, "implementation:1", 1);
    unmarked.attempts[0].state = TaskBoardAttemptState::Running;
    validate_task_board_legacy_local_target_adoption(&targetless, &unmarked)
        .expect_err("new targetless Starting attempts have no legacy authority");

    mark_legacy_local_adoption(&mut targetless, 0);
    targetless.ownership.resources.insert(
        TASK_BOARD_LEGACY_LOCAL_TARGET_ATTEMPT_RESOURCE.into(),
        "2".into(),
    );
    let mut wrong_generation =
        target_candidate(&targetless, "local", None, 0, "implementation:1", 1);
    wrong_generation.attempts[0].state = TaskBoardAttemptState::Running;
    clear_legacy_local_adoption(&mut wrong_generation);
    validate_task_board_legacy_local_target_adoption(&targetless, &wrong_generation)
        .expect_err("legacy authority cannot be reused for another attempt generation");
}

fn mark_legacy_local_adoption(record: &mut TaskBoardWorkflowExecutionRecord, index: usize) {
    let attempt = &record.attempts[index];
    record.ownership.resources.insert(
        TASK_BOARD_LEGACY_LOCAL_TARGET_ADOPTION_RESOURCE.into(),
        TASK_BOARD_LEGACY_LOCAL_TARGET_ADOPTION_V43.into(),
    );
    record.ownership.resources.insert(
        TASK_BOARD_LEGACY_LOCAL_TARGET_ACTION_RESOURCE.into(),
        attempt.action_key.clone(),
    );
    record.ownership.resources.insert(
        TASK_BOARD_LEGACY_LOCAL_TARGET_ATTEMPT_RESOURCE.into(),
        attempt.attempt.to_string(),
    );
    record.ownership.resources.insert(
        TASK_BOARD_LEGACY_LOCAL_TARGET_IDEMPOTENCY_RESOURCE.into(),
        attempt.idempotency_key.clone(),
    );
}

fn clear_legacy_local_adoption(record: &mut TaskBoardWorkflowExecutionRecord) {
    for key in [
        TASK_BOARD_LEGACY_LOCAL_TARGET_ADOPTION_RESOURCE,
        TASK_BOARD_LEGACY_LOCAL_TARGET_ACTION_RESOURCE,
        TASK_BOARD_LEGACY_LOCAL_TARGET_ATTEMPT_RESOURCE,
        TASK_BOARD_LEGACY_LOCAL_TARGET_IDEMPOTENCY_RESOURCE,
    ] {
        record.ownership.resources.remove(key);
    }
}

fn targetable_execution() -> TaskBoardWorkflowExecutionRecord {
    let mut record = write_execution();
    record.transition.execution_state = TaskBoardExecutionState::Preparing;
    record.attempts.push(preparing_attempt(
        &record.execution_id,
        "implementation:1",
        1,
    ));
    record
}

fn preparing_attempt(
    execution_id: &str,
    action_key: &str,
    attempt: u32,
) -> TaskBoardExecutionAttemptRecord {
    TaskBoardExecutionAttemptRecord {
        execution_id: execution_id.into(),
        action_key: action_key.into(),
        attempt,
        idempotency_key: format!("target-{action_key}-{attempt}"),
        state: TaskBoardAttemptState::Preparing,
        failure_class: None,
        available_at: None,
        error: None,
        artifact: None,
        started_at: NOW.into(),
        updated_at: NOW.into(),
        completed_at: None,
    }
}

fn target_candidate(
    current: &TaskBoardWorkflowExecutionRecord,
    target: &str,
    host_id: Option<&str>,
    epoch: u64,
    action: &str,
    attempt: u32,
) -> TaskBoardWorkflowExecutionRecord {
    let mut updated = current.clone();
    updated.transition.execution_state = TaskBoardExecutionState::Starting;
    updated
        .attempts
        .iter_mut()
        .find(|candidate| candidate.action_key == action && candidate.attempt == attempt)
        .expect("target attempt")
        .state = TaskBoardAttemptState::Starting;
    bind_target(&mut updated, target, host_id, epoch, action, attempt);
    updated
}

fn bind_target(
    record: &mut TaskBoardWorkflowExecutionRecord,
    target: &str,
    host_id: Option<&str>,
    epoch: u64,
    action: &str,
    attempt: u32,
) {
    record.ownership.host_id = host_id.map(str::to_owned);
    record.ownership.fencing_epoch = epoch;
    record
        .ownership
        .resources
        .insert(TASK_BOARD_EXECUTION_TARGET_RESOURCE.into(), target.into());
    record.ownership.resources.insert(
        TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE.into(),
        action.into(),
    );
    record.ownership.resources.insert(
        TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE.into(),
        attempt.to_string(),
    );
}
