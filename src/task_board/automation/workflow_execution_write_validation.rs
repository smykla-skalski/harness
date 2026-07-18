use std::fmt::Display;

use crate::task_board::{
    TaskBoardAttemptResultArtifact, TaskBoardExecutionAttemptRecord, TaskBoardExecutionPhase,
    TaskBoardExecutionState, TaskBoardImplementationResult, TaskBoardWorkflowExecutionRecord,
    TaskBoardWorkflowKind, validate_plan_approval, validate_planning_result,
    validate_task_board_read_only_run_context,
};

use super::TaskBoardWorkflowExecutionValidationError;

pub(super) fn is_write_workflow(kind: TaskBoardWorkflowKind) -> bool {
    matches!(
        kind,
        TaskBoardWorkflowKind::DefaultTask | TaskBoardWorkflowKind::PrFix
    )
}

pub(super) fn validate_write_frozen_contract(
    record: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    if !is_write_workflow(record.snapshot.workflow_kind) {
        return validate_read_only_has_no_write_evidence(record);
    }
    let context = record
        .snapshot
        .read_only_run_context
        .as_ref()
        .ok_or_else(|| {
            field_error(
                "snapshot.read_only_run_context",
                "write workflow has no immutable local run context",
            )
        })?;
    validate_task_board_read_only_run_context(context)
        .map_err(|error| field_error("snapshot.read_only_run_context", error))?;
    validate_phase_evidence(record)
}

pub(super) fn validate_write_attempt_artifact(
    record: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
) -> Result<bool, TaskBoardWorkflowExecutionValidationError> {
    match attempt.artifact.as_ref() {
        Some(TaskBoardAttemptResultArtifact::Planning(result)) => {
            require_write(record, "attempt.artifact.planning")?;
            validate_planning_result(result, &record.snapshot, &record.execution_id)
                .map_err(|error| field_error("attempt.artifact.planning", error))?;
            if attempt.action_key != "plan" {
                return invalid("attempt.artifact.planning", "action key is not plan");
            }
            Ok(true)
        }
        Some(TaskBoardAttemptResultArtifact::Implementation(result)) => {
            require_write(record, "attempt.artifact.implementation")?;
            validate_implementation_result(record, attempt, result)?;
            Ok(true)
        }
        Some(TaskBoardAttemptResultArtifact::Evaluation(result))
            if is_write_workflow(record.snapshot.workflow_kind) =>
        {
            let Some(head) = result.head_revision.as_deref() else {
                return invalid("attempt.artifact.evaluation", "exact head is missing");
            };
            let Some(cycle) = result.revision_cycle else {
                return invalid("attempt.artifact.evaluation", "revision cycle is missing");
            };
            required(head, "attempt.artifact.evaluation")?;
            if cycle == 0
                || cycle > record.artifacts.current_revision_cycle
                || attempt.action_key != format!("evaluate:{cycle}")
                || !head_belongs_to_execution(record, head, cycle)
            {
                return invalid(
                    "attempt.artifact.evaluation",
                    "head or revision cycle contradicts frozen workflow evidence",
                );
            }
            Ok(true)
        }
        _ => Ok(false),
    }
}

fn validate_phase_evidence(
    record: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    let artifacts = &record.artifacts;
    if let Some(result) = artifacts.planning_result.as_ref() {
        validate_planning_result(result, &record.snapshot, &record.execution_id)
            .map_err(|error| field_error("artifacts.planning_result", error))?;
    }
    if let Some(binding) = artifacts.plan_approval.as_ref() {
        let result = artifacts
            .planning_result
            .as_ref()
            .ok_or_else(|| field_error("artifacts.plan_approval", "has no planning result"))?;
        if !validate_plan_approval(binding, result, &record.snapshot, &record.execution_id).valid {
            return invalid("artifacts.plan_approval", "does not match frozen plan");
        }
    }
    validate_approval_invalidations(record)?;
    let phase = record.transition.phase;
    if phase == Some(TaskBoardExecutionPhase::AwaitingApproval)
        && artifacts.planning_result.is_none()
    {
        return invalid(
            "artifacts.planning_result",
            "approval phase has no planning evidence",
        );
    }
    if matches!(
        phase,
        Some(
            TaskBoardExecutionPhase::Implementation
                | TaskBoardExecutionPhase::Review
                | TaskBoardExecutionPhase::Evaluate
                | TaskBoardExecutionPhase::Publish
                | TaskBoardExecutionPhase::Cleanup
                | TaskBoardExecutionPhase::Terminal
        )
    ) && (artifacts.planning_result.is_none() || artifacts.plan_approval.is_none())
    {
        return invalid(
            "artifacts.plan_approval",
            "write phase has no revision-bound approval",
        );
    }
    Ok(())
}

fn validate_approval_invalidations(
    record: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    let invalidations = &record.artifacts.approval_invalidations;
    if invalidations.is_empty() {
        return Ok(());
    }
    let unique = invalidations
        .iter()
        .enumerate()
        .all(|(index, reason)| !invalidations[..index].contains(reason));
    if !unique
        || record.transition.execution_state != TaskBoardExecutionState::HumanRequired
        || record.blocked_reason.as_deref() != Some("plan_approval_invalidated")
        || record.artifacts.plan_approval.is_none()
    {
        return invalid(
            "artifacts.approval_invalidations",
            "invalidation evidence is duplicated or not fail-closed",
        );
    }
    Ok(())
}

fn validate_read_only_has_no_write_evidence(
    record: &TaskBoardWorkflowExecutionRecord,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    let artifacts = &record.artifacts;
    if artifacts.planning_result.is_some()
        || artifacts.plan_approval.is_some()
        || !artifacts.approval_invalidations.is_empty()
    {
        return invalid("artifacts", "read-only workflow carries write evidence");
    }
    Ok(())
}

fn validate_implementation_result(
    record: &TaskBoardWorkflowExecutionRecord,
    attempt: &TaskBoardExecutionAttemptRecord,
    result: &TaskBoardImplementationResult,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    required(
        &result.base_head_revision,
        "attempt.artifact.implementation",
    )?;
    required(&result.head_revision, "attempt.artifact.implementation")?;
    required(&result.summary, "attempt.artifact.implementation")?;
    if result.revision_cycle == 0
        || result.revision_cycle > record.artifacts.current_revision_cycle
        || attempt.action_key != format!("implementation:{}", result.revision_cycle)
        || result.base_head_revision == result.head_revision
    {
        return invalid(
            "attempt.artifact.implementation",
            "revision cycle, action, or head transition is invalid",
        );
    }
    if result.revision_cycle > 1 {
        let prior_cycle = result.revision_cycle - 1;
        let expected_base = record
            .artifacts
            .review_cycles
            .iter()
            .find(|cycle| cycle.revision_cycle == prior_cycle)
            .map(|cycle| cycle.head_revision.as_str());
        if expected_base != Some(result.base_head_revision.as_str()) {
            return invalid(
                "attempt.artifact.implementation",
                "base head does not match the preceding reviewed cycle",
            );
        }
    }
    Ok(())
}

fn head_belongs_to_execution(
    record: &TaskBoardWorkflowExecutionRecord,
    head: &str,
    cycle: u32,
) -> bool {
    record.transition.exact_head_revision.as_deref() == Some(head)
        || record
            .artifacts
            .review_cycles
            .iter()
            .any(|review| review.revision_cycle == cycle && review.head_revision == head)
}

fn require_write(
    record: &TaskBoardWorkflowExecutionRecord,
    field: &'static str,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    if is_write_workflow(record.snapshot.workflow_kind) {
        Ok(())
    } else {
        invalid(field, "artifact belongs only to a write workflow")
    }
}

fn required(
    value: &str,
    field: &'static str,
) -> Result<(), TaskBoardWorkflowExecutionValidationError> {
    if value.trim().is_empty() || value.trim() != value {
        invalid(field, "field is empty or non-canonical")
    } else {
        Ok(())
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
