use crate::daemon::db::AsyncDaemonDb;
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{
    TaskBoardExecutionPhase, TaskBoardExecutionState, TaskBoardReviewCycle,
    TaskBoardReviewRoundDecision, TaskBoardReviewerOutcome, TaskBoardTerminalOutcome,
    TaskBoardTerminalOutcomeKind, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionCasOutcome, TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind,
    advance_task_board_workflow, evaluate_task_board_review_round,
    restart_task_board_workflow_revision,
};

use super::task_board_workflow_execution::{
    canonical_time, guarded_execution, require_human, stale_outcome,
};

pub(crate) async fn record_workflow_reviewer_outcome(
    db: &AsyncDaemonDb,
    expected: &TaskBoardWorkflowExecutionCas,
    outcome: TaskBoardReviewerOutcome,
    updated_at: &str,
) -> Result<TaskBoardWorkflowExecutionCasOutcome, CliError> {
    let Some(mut record) = guarded_execution(db, expected).await? else {
        return stale_outcome(db, expected).await;
    };
    if record.transition.phase != Some(TaskBoardExecutionPhase::Review) {
        return Err(invalid_transition("review outcome requires Review phase"));
    }
    let head_revision = record
        .transition
        .exact_head_revision
        .clone()
        .ok_or_else(|| invalid_transition("review execution has no exact head"))?;
    let cycle_number = record.artifacts.current_revision_cycle;
    let cycle_index = current_cycle_index(
        &mut record.artifacts.review_cycles,
        cycle_number,
        &head_revision,
    )?;
    if let Some(existing) = record.artifacts.review_cycles[cycle_index]
        .outcomes
        .iter()
        .find(|existing| existing.profile_id == outcome.profile_id)
    {
        if existing == &outcome {
            return db
                .compare_and_set_task_board_workflow_execution(expected, &record)
                .await;
        }
        return Err(invalid_transition(
            "reviewer profile submitted conflicting durable outcomes",
        ));
    }
    record.artifacts.review_cycles[cycle_index]
        .outcomes
        .push(outcome);
    let evaluation = evaluate_task_board_review_round(
        &record.resolved_reviewers,
        &head_revision,
        cycle_number,
        &record.artifacts.review_cycles[cycle_index].outcomes,
    )
    .map_err(|error| invalid_transition(error.to_string()))?;
    record.artifacts.review_cycles[cycle_index].decision = Some(evaluation.decision);
    let updated_at = canonical_time(updated_at)?;
    apply_review_decision(&mut record, evaluation.decision, &updated_at)?;
    record.updated_at = updated_at;
    db.compare_and_set_task_board_workflow_execution(expected, &record)
        .await
}

fn current_cycle_index(
    cycles: &mut Vec<TaskBoardReviewCycle>,
    revision_cycle: u32,
    head_revision: &str,
) -> Result<usize, CliError> {
    if let Some(index) = cycles
        .iter()
        .position(|cycle| cycle.revision_cycle == revision_cycle)
    {
        if cycles[index].head_revision != head_revision {
            return Err(invalid_transition(
                "review cycle head contradicts durable transition state",
            ));
        }
        return Ok(index);
    }
    cycles.push(TaskBoardReviewCycle {
        revision_cycle,
        head_revision: head_revision.to_owned(),
        outcomes: Vec::new(),
        decision: None,
    });
    Ok(cycles.len() - 1)
}

fn apply_review_decision(
    record: &mut TaskBoardWorkflowExecutionRecord,
    decision: TaskBoardReviewRoundDecision,
    updated_at: &str,
) -> Result<(), CliError> {
    match decision {
        TaskBoardReviewRoundDecision::AwaitingReviewers => {
            record.transition.execution_state = TaskBoardExecutionState::Pending;
        }
        TaskBoardReviewRoundDecision::Approved => {
            record.transition = advance_task_board_workflow(
                &record.transition,
                record.transition.pull_request.as_ref(),
                record.transition.exact_head_revision.as_deref(),
            )
            .map_err(|error| invalid_transition(error.to_string()))?;
            record.blocked_reason = None;
        }
        TaskBoardReviewRoundDecision::ChangesRequired => {
            if matches!(
                record.snapshot.workflow_kind,
                TaskBoardWorkflowKind::DefaultTask | TaskBoardWorkflowKind::PrFix
            ) && record.artifacts.current_revision_cycle
                < record.resolved_reviewers.max_revision_cycles
            {
                record.transition = restart_task_board_workflow_revision(&record.transition)
                    .map_err(|error| invalid_transition(error.to_string()))?;
                record.artifacts.current_revision_cycle += 1;
                record.blocked_reason = Some("review_changes_required".into());
            } else {
                require_human(record, "review_revision_requires_new_head", updated_at);
                let summary = if matches!(
                    record.snapshot.workflow_kind,
                    TaskBoardWorkflowKind::DefaultTask | TaskBoardWorkflowKind::PrFix
                ) {
                    "review changes exhausted the permitted revision cycles"
                } else {
                    "read-only review requires a new externally supplied head"
                };
                record.artifacts.terminal_outcome = Some(TaskBoardTerminalOutcome {
                    kind: TaskBoardTerminalOutcomeKind::HumanRequired,
                    summary: summary.into(),
                    recorded_at: updated_at.to_owned(),
                });
            }
        }
        TaskBoardReviewRoundDecision::HumanRequired => {
            require_human(record, "review_policy_requires_human", updated_at);
            record.artifacts.terminal_outcome = Some(TaskBoardTerminalOutcome {
                kind: TaskBoardTerminalOutcomeKind::HumanRequired,
                summary: "review evidence could not satisfy policy".into(),
                recorded_at: updated_at.to_owned(),
            });
        }
    }
    Ok(())
}

fn invalid_transition(detail: impl Into<String>) -> CliError {
    CliErrorKind::invalid_transition(detail.into()).into()
}
