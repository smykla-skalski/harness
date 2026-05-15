use std::collections::BTreeSet;
use std::path::Path;

use uuid::Uuid;

use crate::errors::CliError;
use crate::infra::io::read_json_typed;
use crate::workspace::utc_now;

use super::super::dispatch::DispatchExecutionSummary;
use super::super::evaluation::TaskBoardEvaluationSummary;
use super::super::machines::Machine;
use super::super::store::TaskBoardStore;
use super::super::summary::{TaskBoardAuditSummary, TaskBoardSyncSummary};
use super::super::types::{TaskBoardItem, TaskBoardStatus, TaskBoardWorkflowStatus};
use super::types::{TaskBoardOrchestratorRunStatus, TaskBoardOrchestratorRunSummary};

pub(super) struct RunRecordInput {
    pub run_id: String,
    pub started_at: String,
    pub dry_run: bool,
    pub sync: TaskBoardSyncSummary,
    pub audit: TaskBoardAuditSummary,
    pub dispatch: Option<DispatchExecutionSummary>,
    pub evaluation: Option<TaskBoardEvaluationSummary>,
    pub error: Option<String>,
}

pub(super) fn run_record(input: RunRecordInput) -> TaskBoardOrchestratorRunSummary {
    let policy_trace_ids = policy_trace_ids(input.dispatch.as_ref(), input.evaluation.as_ref());
    TaskBoardOrchestratorRunSummary {
        run_id: input.run_id,
        started_at: input.started_at,
        completed_at: utc_now(),
        status: if input.error.is_some() {
            TaskBoardOrchestratorRunStatus::Failed
        } else {
            TaskBoardOrchestratorRunStatus::Completed
        },
        dry_run: input.dry_run,
        sync: input.sync,
        audit: input.audit,
        dispatch: input.dispatch,
        evaluation: input.evaluation,
        error: input.error,
        policy_trace_ids,
    }
}

fn policy_trace_ids(
    dispatch: Option<&DispatchExecutionSummary>,
    evaluation: Option<&TaskBoardEvaluationSummary>,
) -> Vec<String> {
    let mut trace_ids = BTreeSet::new();
    if let Some(dispatch) = dispatch {
        for applied in &dispatch.applied {
            trace_ids.extend(applied.item.workflow.policy_trace_ids.iter().cloned());
        }
    }
    if let Some(evaluation) = evaluation {
        for record in &evaluation.records {
            if let Some(item) = &record.item {
                trace_ids.extend(item.workflow.policy_trace_ids.iter().cloned());
            }
        }
    }
    trace_ids.into_iter().collect()
}

pub(super) const fn workflow_statuses() -> [TaskBoardWorkflowStatus; 6] {
    [
        TaskBoardWorkflowStatus::Idle,
        TaskBoardWorkflowStatus::Running,
        TaskBoardWorkflowStatus::Paused,
        TaskBoardWorkflowStatus::Completed,
        TaskBoardWorkflowStatus::Failed,
        TaskBoardWorkflowStatus::Cancelled,
    ]
}

pub(super) fn run_items_for_machine(
    board: &TaskBoardStore,
    item_id: Option<&str>,
    status: Option<TaskBoardStatus>,
    machine: Option<&Machine>,
) -> Result<Vec<TaskBoardItem>, CliError> {
    let items = item_id.map_or_else(
        || board.list(status),
        |id| board.get(id).map(|item| vec![item]),
    )?;
    let Some(machine) = machine else {
        return Ok(items);
    };
    Ok(items
        .into_iter()
        .filter(|item| machine.accepts_any(&item.target_project_types))
        .collect())
}

pub(super) fn read_or_default<T>(path: &Path) -> Result<T, CliError>
where
    T: Default + for<'de> serde::Deserialize<'de>,
{
    if path.exists() {
        read_json_typed(path)
    } else {
        Ok(T::default())
    }
}

pub(super) fn new_run_id() -> String {
    format!("task-board-run-{}", Uuid::new_v4().simple())
}
