//! Thin wire projection of the orchestrator's status, kept apart from
//! `orchestrator::TaskBoardOrchestratorStatusSnapshot` so the daemon's wire
//! contract never embeds `TaskBoardItem` (the task-board domain entity) or
//! the internal-only `DispatchAppliedTask`/`TaskBoardEvaluationRecord`
//! fields the daemon threads through worker-claim reconciliation. Every
//! consumer that used to read the embedded item off this response only ever
//! needed its id and title; a consumer that needs the full item resolves it
//! through the task-board items list instead, the same way the daemon's own
//! internal deep readers already re-fetch from the database rather than
//! trust this copy.
//!
//! The six wire types below (and `last_run_applied_count`) relocated to
//! `harness_protocol::daemon::task_board::orchestrator_status` (#1145),
//! exactly the pure-data closure this module's own doc comment above already
//! describes. The five `From` impls that build them out of their fat,
//! `harness-task-board`-only counterparts could not come along: each one's
//! `Self` (the moved wire type) is no longer local to this crate, and
//! `harness-protocol` cannot depend back on `harness-task-board` to reach the
//! fat source type, so neither crate can host the impl (see `PolicyDecision`'s
//! module for the general rule). They became free functions instead, kept
//! here next to the fixture-based tests that exercise them.
//! `task_board_orchestrator_status_from_snapshot` is `harness-daemon`'s only
//! external caller, in place of the `Into::into()` it used to reach through
//! the removed `From` impl.

pub use harness_protocol::daemon::task_board::orchestrator_status::{
    TaskBoardOrchestratorAppliedTask, TaskBoardOrchestratorDispatchOutcome,
    TaskBoardOrchestratorEvaluationOutcome, TaskBoardOrchestratorEvaluationRecord,
    TaskBoardOrchestratorRunOutcome, TaskBoardOrchestratorStatus,
};

use crate::dispatch::{DispatchAppliedTask, DispatchExecutionSummary};
use crate::evaluation::{TaskBoardEvaluationRecord, TaskBoardEvaluationSummary};
use crate::orchestrator::{TaskBoardOrchestratorRunSummary, TaskBoardOrchestratorStatusSnapshot};

#[must_use]
pub fn task_board_orchestrator_status_from_snapshot(
    snapshot: TaskBoardOrchestratorStatusSnapshot,
) -> TaskBoardOrchestratorStatus {
    TaskBoardOrchestratorStatus {
        enabled: snapshot.enabled,
        running: snapshot.running,
        step_mode: snapshot.step_mode,
        held_dispatches: snapshot.held_dispatches,
        current_tick: snapshot.current_tick,
        last_run: snapshot
            .last_run
            .map(task_board_orchestrator_run_outcome_from_summary),
        workflow_execution_counts: snapshot.workflow_execution_counts,
        automation: snapshot.automation,
        settings: snapshot.settings,
    }
}

#[must_use]
pub fn task_board_orchestrator_run_outcome_from_summary(
    run: TaskBoardOrchestratorRunSummary,
) -> TaskBoardOrchestratorRunOutcome {
    TaskBoardOrchestratorRunOutcome {
        run_id: run.run_id,
        started_at: run.started_at,
        completed_at: run.completed_at,
        status: run.status,
        dry_run: run.dry_run,
        sync: run.sync,
        audit: run.audit,
        dispatch: run
            .dispatch
            .map(task_board_orchestrator_dispatch_outcome_from_summary),
        evaluation: run
            .evaluation
            .map(task_board_orchestrator_evaluation_outcome_from_summary),
        error: run.error,
        policy_trace_ids: run.policy_trace_ids,
    }
}

#[must_use]
pub fn task_board_orchestrator_dispatch_outcome_from_summary(
    dispatch: DispatchExecutionSummary,
) -> TaskBoardOrchestratorDispatchOutcome {
    TaskBoardOrchestratorDispatchOutcome {
        plans: dispatch.plans,
        applied: dispatch
            .applied
            .into_iter()
            .map(task_board_orchestrator_applied_task_from_dispatch)
            .collect(),
        failures: dispatch.failures,
    }
}

#[must_use]
pub fn task_board_orchestrator_applied_task_from_dispatch(
    applied: DispatchAppliedTask,
) -> TaskBoardOrchestratorAppliedTask {
    TaskBoardOrchestratorAppliedTask {
        board_item_id: applied.board_item_id,
        session_id: applied.session_id,
        workspace_id: applied.workspace_id,
        working_copy_id: applied.working_copy_id,
        work_item_id: applied.work_item_id,
        item_title: applied.item.title,
    }
}

#[must_use]
pub fn task_board_orchestrator_evaluation_outcome_from_summary(
    evaluation: TaskBoardEvaluationSummary,
) -> TaskBoardOrchestratorEvaluationOutcome {
    TaskBoardOrchestratorEvaluationOutcome {
        total: evaluation.total,
        evaluated: evaluation.evaluated,
        updated: evaluation.updated,
        skipped: evaluation.skipped,
        completed: evaluation.completed,
        running: evaluation.running,
        reviewing: evaluation.reviewing,
        blocked: evaluation.blocked,
        failed: evaluation.failed,
        records: evaluation
            .records
            .into_iter()
            .map(task_board_orchestrator_evaluation_record_from_record)
            .collect(),
        signal_failures: evaluation.signal_failures,
    }
}

#[must_use]
pub fn task_board_orchestrator_evaluation_record_from_record(
    record: TaskBoardEvaluationRecord,
) -> TaskBoardOrchestratorEvaluationRecord {
    TaskBoardOrchestratorEvaluationRecord {
        board_item_id: record.board_item_id,
        session_id: record.session_id,
        work_item_id: record.work_item_id,
        outcome: record.outcome,
        task_status: record.task_status,
        board_status: record.board_status,
        workflow_status: record.workflow_status,
        updated: record.updated,
        reason: record.reason,
        item_title: record.item.map(|item| item.title),
    }
}

#[cfg(test)]
mod tests {
    use harness_protocol::daemon::task_board::evaluation::TaskBoardEvaluationOutcome;
    use harness_protocol::daemon::task_board::orchestrator::TaskBoardOrchestratorRunStatus;

    use super::*;
    use crate::dispatch::{
        DispatchLifecycle, DispatchLifecyclePhase, DispatchLifecycleStatus, DispatchLifecycleStep,
    };
    use crate::orchestrator::{TaskBoardHeldDispatchSummary, TaskBoardOrchestratorSettings};
    use crate::summary::{TaskBoardAuditSummary, TaskBoardSyncSummary};
    use crate::types::TaskBoardItem;

    fn sample_item(id: &str) -> TaskBoardItem {
        TaskBoardItem::new(
            id.to_string(),
            format!("{id} title"),
            String::new(),
            "now".into(),
        )
    }

    fn minimal_lifecycle() -> DispatchLifecycle {
        let step = DispatchLifecycleStep {
            phase: DispatchLifecyclePhase::Worker,
            status: DispatchLifecycleStatus::Planned,
            mode: None,
            suggested_persona: None,
            required_consensus: None,
            native_signal: None,
        };
        DispatchLifecycle {
            worker: step.clone(),
            reviewer: step.clone(),
            evaluator: step,
        }
    }

    #[test]
    fn applied_task_projection_keeps_the_title_and_drops_the_item() {
        let full = DispatchAppliedTask {
            board_item_id: "board-1".into(),
            session_id: Some("session-1".into()),
            workspace_id: None,
            working_copy_id: None,
            work_item_id: "work-1".into(),
            lifecycle: minimal_lifecycle(),
            item: sample_item("board-1"),
            read_only_workflow: None,
            write_workflow: None,
        };

        let thin = task_board_orchestrator_applied_task_from_dispatch(full);

        assert_eq!(thin.board_item_id, "board-1");
        assert_eq!(thin.session_id.as_deref(), Some("session-1"));
        assert_eq!(thin.work_item_id, "work-1");
        assert_eq!(thin.item_title, "board-1 title");
    }

    #[test]
    fn evaluation_record_projection_keeps_the_title_when_an_item_is_present() {
        let full = TaskBoardEvaluationRecord {
            board_item_id: "board-2".into(),
            session_id: None,
            work_item_id: None,
            outcome: TaskBoardEvaluationOutcome::Completed,
            task_status: None,
            board_status: None,
            workflow_status: None,
            updated: true,
            reason: None,
            item: Some(sample_item("board-2")),
        };

        let thin = task_board_orchestrator_evaluation_record_from_record(full);

        assert_eq!(thin.item_title.as_deref(), Some("board-2 title"));
    }

    #[test]
    fn evaluation_record_projection_stays_none_without_an_item() {
        let full = TaskBoardEvaluationRecord {
            board_item_id: "board-3".into(),
            session_id: None,
            work_item_id: None,
            outcome: TaskBoardEvaluationOutcome::SkippedUnlinked,
            task_status: None,
            board_status: None,
            workflow_status: None,
            updated: false,
            reason: None,
            item: None,
        };

        assert!(
            task_board_orchestrator_evaluation_record_from_record(full)
                .item_title
                .is_none()
        );
    }

    #[test]
    fn last_run_applied_count_sums_sync_dispatch_and_evaluation() {
        let status = TaskBoardOrchestratorStatus {
            enabled: true,
            running: true,
            step_mode: false,
            held_dispatches: TaskBoardHeldDispatchSummary::default(),
            current_tick: None,
            last_run: Some(TaskBoardOrchestratorRunOutcome {
                run_id: "run-1".into(),
                started_at: "now".into(),
                completed_at: "now".into(),
                status: TaskBoardOrchestratorRunStatus::Completed,
                dry_run: false,
                sync: TaskBoardSyncSummary {
                    total: 0,
                    providers: Vec::new(),
                    operations: Vec::new(),
                },
                audit: TaskBoardAuditSummary {
                    total: 0,
                    ready: 0,
                    blocked: 0,
                    deleted: 0,
                    by_status: Vec::new(),
                },
                dispatch: Some(TaskBoardOrchestratorDispatchOutcome {
                    plans: Vec::new(),
                    applied: vec![TaskBoardOrchestratorAppliedTask {
                        board_item_id: "board-1".into(),
                        session_id: Some("session-1".into()),
                        workspace_id: None,
                        working_copy_id: None,
                        work_item_id: "work-1".into(),
                        item_title: "title".into(),
                    }],
                    failures: Vec::new(),
                }),
                evaluation: Some(TaskBoardOrchestratorEvaluationOutcome {
                    total: 1,
                    evaluated: 1,
                    updated: 1,
                    skipped: 0,
                    completed: 1,
                    running: 0,
                    reviewing: 0,
                    blocked: 0,
                    failed: 0,
                    records: Vec::new(),
                    signal_failures: Vec::new(),
                }),
                error: None,
                policy_trace_ids: Vec::new(),
            }),
            workflow_execution_counts: Vec::new(),
            automation: None,
            settings: TaskBoardOrchestratorSettings::default(),
        };

        assert_eq!(status.last_run_applied_count(), 2);
    }
}
