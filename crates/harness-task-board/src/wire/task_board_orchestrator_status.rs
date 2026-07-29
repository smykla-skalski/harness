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

use serde::{Deserialize, Serialize};

use crate::dispatch::{
    DispatchAppliedTask, DispatchExecutionSummary, DispatchFailure, DispatchPlan,
};
use crate::evaluation::{
    EvaluationSignalFailure, TaskBoardEvaluationOutcome, TaskBoardEvaluationRecord,
    TaskBoardEvaluationSummary,
};
use crate::orchestrator::{
    TaskBoardHeldDispatchSummary, TaskBoardOrchestratorRunStatus, TaskBoardOrchestratorRunSummary,
    TaskBoardOrchestratorSettings, TaskBoardOrchestratorStatusSnapshot,
    TaskBoardOrchestratorTickInfo,
};
use crate::summary::{TaskBoardAuditSummary, TaskBoardSyncSummary};
use crate::types::{TaskBoardStatus, TaskBoardWorkflowStatus};
use crate::{TaskBoardAutomationSnapshot, TaskBoardWorkflowExecutionCount};
use harness_session::types::TaskStatus;

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardOrchestratorStatus {
    pub enabled: bool,
    pub running: bool,
    #[serde(default)]
    pub step_mode: bool,
    #[serde(default)]
    pub held_dispatches: TaskBoardHeldDispatchSummary,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_tick: Option<TaskBoardOrchestratorTickInfo>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_run: Option<TaskBoardOrchestratorRunOutcome>,
    pub workflow_execution_counts: Vec<TaskBoardWorkflowExecutionCount>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub automation: Option<TaskBoardAutomationSnapshot>,
    pub settings: TaskBoardOrchestratorSettings,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardOrchestratorRunOutcome {
    pub run_id: String,
    pub started_at: String,
    pub completed_at: String,
    pub status: TaskBoardOrchestratorRunStatus,
    pub dry_run: bool,
    pub sync: TaskBoardSyncSummary,
    pub audit: TaskBoardAuditSummary,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dispatch: Option<TaskBoardOrchestratorDispatchOutcome>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub evaluation: Option<TaskBoardOrchestratorEvaluationOutcome>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub policy_trace_ids: Vec<String>,
}

/// Thin mirror of `DispatchExecutionSummary`. `plans` rides through
/// unchanged: `DispatchPlan` names no `TaskBoardItem`, only a `board_item_id`
/// key, so it carries no domain-entity closure to strip.
#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardOrchestratorDispatchOutcome {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub plans: Vec<DispatchPlan>,
    pub applied: Vec<TaskBoardOrchestratorAppliedTask>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub failures: Vec<DispatchFailure>,
}

/// Thin mirror of `DispatchAppliedTask`: drops the embedded `TaskBoardItem`
/// (keeping only its title, the one field real consumers read off it) and
/// the `lifecycle`/`read_only_workflow`/`write_workflow` fields, which are
/// daemon-internal worker-claim bookkeeping that Swift already omits on
/// decode for the direct dispatch endpoint.
#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardOrchestratorAppliedTask {
    pub board_item_id: String,
    pub session_id: String,
    pub work_item_id: String,
    pub item_title: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardOrchestratorEvaluationOutcome {
    pub total: usize,
    pub evaluated: usize,
    pub updated: usize,
    pub skipped: usize,
    pub completed: usize,
    pub running: usize,
    pub reviewing: usize,
    pub blocked: usize,
    pub failed: usize,
    pub records: Vec<TaskBoardOrchestratorEvaluationRecord>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub signal_failures: Vec<EvaluationSignalFailure>,
}

/// Thin mirror of `TaskBoardEvaluationRecord`: `item: Option<TaskBoardItem>`
/// becomes `item_title: Option<String>`, the only piece of it any consumer of
/// this specific embedding reads.
#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardOrchestratorEvaluationRecord {
    pub board_item_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub work_item_id: Option<String>,
    pub outcome: TaskBoardEvaluationOutcome,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_status: Option<TaskStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub board_status: Option<TaskBoardStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow_status: Option<TaskBoardWorkflowStatus>,
    #[serde(default)]
    pub updated: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item_title: Option<String>,
}

impl TaskBoardOrchestratorStatus {
    #[must_use]
    pub fn last_run_applied_count(&self) -> usize {
        self.last_run.as_ref().map_or(0, |run| {
            let synced = run
                .sync
                .operations
                .iter()
                .filter(|operation| operation.applied)
                .count();
            let dispatched = run
                .dispatch
                .as_ref()
                .map_or(0, |dispatch| dispatch.applied.len());
            let evaluated = run
                .evaluation
                .as_ref()
                .map_or(0, |evaluation| evaluation.updated);
            synced + dispatched + evaluated
        })
    }
}

impl From<TaskBoardOrchestratorStatusSnapshot> for TaskBoardOrchestratorStatus {
    fn from(snapshot: TaskBoardOrchestratorStatusSnapshot) -> Self {
        Self {
            enabled: snapshot.enabled,
            running: snapshot.running,
            step_mode: snapshot.step_mode,
            held_dispatches: snapshot.held_dispatches,
            current_tick: snapshot.current_tick,
            last_run: snapshot.last_run.map(Into::into),
            workflow_execution_counts: snapshot.workflow_execution_counts,
            automation: snapshot.automation,
            settings: snapshot.settings,
        }
    }
}

impl From<TaskBoardOrchestratorRunSummary> for TaskBoardOrchestratorRunOutcome {
    fn from(run: TaskBoardOrchestratorRunSummary) -> Self {
        Self {
            run_id: run.run_id,
            started_at: run.started_at,
            completed_at: run.completed_at,
            status: run.status,
            dry_run: run.dry_run,
            sync: run.sync,
            audit: run.audit,
            dispatch: run.dispatch.map(Into::into),
            evaluation: run.evaluation.map(Into::into),
            error: run.error,
            policy_trace_ids: run.policy_trace_ids,
        }
    }
}

impl From<DispatchExecutionSummary> for TaskBoardOrchestratorDispatchOutcome {
    fn from(dispatch: DispatchExecutionSummary) -> Self {
        Self {
            plans: dispatch.plans,
            applied: dispatch.applied.into_iter().map(Into::into).collect(),
            failures: dispatch.failures,
        }
    }
}

impl From<DispatchAppliedTask> for TaskBoardOrchestratorAppliedTask {
    fn from(applied: DispatchAppliedTask) -> Self {
        Self {
            board_item_id: applied.board_item_id,
            session_id: applied.session_id,
            work_item_id: applied.work_item_id,
            item_title: applied.item.title,
        }
    }
}

impl From<TaskBoardEvaluationSummary> for TaskBoardOrchestratorEvaluationOutcome {
    fn from(evaluation: TaskBoardEvaluationSummary) -> Self {
        Self {
            total: evaluation.total,
            evaluated: evaluation.evaluated,
            updated: evaluation.updated,
            skipped: evaluation.skipped,
            completed: evaluation.completed,
            running: evaluation.running,
            reviewing: evaluation.reviewing,
            blocked: evaluation.blocked,
            failed: evaluation.failed,
            records: evaluation.records.into_iter().map(Into::into).collect(),
            signal_failures: evaluation.signal_failures,
        }
    }
}

impl From<TaskBoardEvaluationRecord> for TaskBoardOrchestratorEvaluationRecord {
    fn from(record: TaskBoardEvaluationRecord) -> Self {
        Self {
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dispatch::{
        DispatchLifecycle, DispatchLifecyclePhase, DispatchLifecycleStatus, DispatchLifecycleStep,
    };
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
            session_id: "session-1".into(),
            work_item_id: "work-1".into(),
            lifecycle: minimal_lifecycle(),
            item: sample_item("board-1"),
            read_only_workflow: None,
            write_workflow: None,
        };

        let thin = TaskBoardOrchestratorAppliedTask::from(full);

        assert_eq!(thin.board_item_id, "board-1");
        assert_eq!(thin.session_id, "session-1");
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

        let thin = TaskBoardOrchestratorEvaluationRecord::from(full);

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
            TaskBoardOrchestratorEvaluationRecord::from(full)
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
                        session_id: "session-1".into(),
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
