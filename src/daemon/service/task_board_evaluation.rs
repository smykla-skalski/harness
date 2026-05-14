use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::protocol::{
    SessionDetail, TaskBoardEvaluateRequest, TaskBoardEvaluationResponse,
};
use crate::errors::CliError;
use crate::session::types::WorkItem;
use crate::task_board::store::TaskBoardItemPatch;
use crate::task_board::{
    TaskBoardEvaluationRecord, TaskBoardEvaluationSummary, TaskBoardItem, TaskBoardStatus,
    TaskBoardStore, default_board_root, evaluate_task_board_item, failed_workflow,
    missing_session_record, missing_task_record, record_from_decision, skipped_unlinked_record,
};

/// Evaluate linked task-board items against their session work-item state.
///
/// # Errors
/// Returns `CliError` when board items cannot be loaded or updated.
pub fn evaluate_task_board(
    request: &TaskBoardEvaluateRequest,
    db: Option<&DaemonDb>,
) -> Result<TaskBoardEvaluationResponse, CliError> {
    let board = store();
    let items = board.list(request.status)?;
    evaluate_items_with_loader(
        &board,
        &items,
        request.dry_run,
        |session_id, work_item_id| {
            let detail = super::session_detail(session_id, db)?;
            Ok(task_from_detail(detail, work_item_id))
        },
    )
}

/// Evaluate linked task-board items through the async daemon DB.
///
/// # Errors
/// Returns `CliError` when board items cannot be loaded, session state cannot be
/// read, or updated board items cannot be persisted.
pub(crate) async fn evaluate_task_board_async(
    request: &TaskBoardEvaluateRequest,
    async_db: &AsyncDaemonDb,
) -> Result<TaskBoardEvaluationResponse, CliError> {
    let board = store();
    let items = board.list(request.status)?;
    let mut summary = TaskBoardEvaluationSummary::default();
    for item in &items {
        let Some((session_id, work_item_id)) = linked_task(item) else {
            summary.push(skipped_unlinked_record(item));
            continue;
        };
        let task = match super::session_detail_async(session_id, Some(async_db)).await {
            Ok(detail) => task_from_detail(detail, work_item_id),
            Err(error) => {
                let record = failure_record(
                    &board,
                    item,
                    missing_session_record(item, error.to_string()),
                    "missing_session",
                    request.dry_run,
                )?;
                summary.push(record);
                continue;
            }
        };
        let Some(task) = task else {
            let record = failure_record(
                &board,
                item,
                missing_task_record(item, format!("session task '{work_item_id}' was not found")),
                "missing_task",
                request.dry_run,
            )?;
            summary.push(record);
            continue;
        };
        summary.push(evaluate_linked_item(&board, item, &task, request.dry_run)?);
    }
    Ok(summary)
}

fn evaluate_items_with_loader<F>(
    board: &TaskBoardStore,
    items: &[TaskBoardItem],
    dry_run: bool,
    mut load_task: F,
) -> Result<TaskBoardEvaluationSummary, CliError>
where
    F: FnMut(&str, &str) -> Result<Option<WorkItem>, CliError>,
{
    let mut summary = TaskBoardEvaluationSummary::default();
    for item in items {
        let Some((session_id, work_item_id)) = linked_task(item) else {
            summary.push(skipped_unlinked_record(item));
            continue;
        };
        let task = match load_task(session_id, work_item_id) {
            Ok(task) => task,
            Err(error) => {
                summary.push(failure_record(
                    board,
                    item,
                    missing_session_record(item, error.to_string()),
                    "missing_session",
                    dry_run,
                )?);
                continue;
            }
        };
        let Some(task) = task else {
            summary.push(failure_record(
                board,
                item,
                missing_task_record(item, format!("session task '{work_item_id}' was not found")),
                "missing_task",
                dry_run,
            )?);
            continue;
        };
        summary.push(evaluate_linked_item(board, item, &task, dry_run)?);
    }
    Ok(summary)
}

fn linked_task(item: &TaskBoardItem) -> Option<(&str, &str)> {
    Some((item.session_id.as_deref()?, item.work_item_id.as_deref()?))
}

fn task_from_detail(detail: SessionDetail, work_item_id: &str) -> Option<WorkItem> {
    detail
        .tasks
        .into_iter()
        .find(|task| task.task_id == work_item_id && !task.is_deleted())
}

fn evaluate_linked_item(
    board: &TaskBoardStore,
    item: &TaskBoardItem,
    task: &WorkItem,
    dry_run: bool,
) -> Result<TaskBoardEvaluationRecord, CliError> {
    let decision = evaluate_task_board_item(item, task);
    let changed = item.status != decision.status || item.workflow != decision.workflow;
    if dry_run || !changed {
        return Ok(record_from_decision(item, &decision, false, None));
    }
    let updated_item = board.update(
        &item.id,
        TaskBoardItemPatch {
            status: Some(decision.status),
            workflow: Some(decision.workflow.clone()),
            ..TaskBoardItemPatch::default()
        },
    )?;
    Ok(record_from_decision(
        item,
        &decision,
        true,
        Some(updated_item),
    ))
}

fn failure_record(
    board: &TaskBoardStore,
    item: &TaskBoardItem,
    mut record: TaskBoardEvaluationRecord,
    step: &str,
    dry_run: bool,
) -> Result<TaskBoardEvaluationRecord, CliError> {
    if dry_run {
        return Ok(record);
    }
    let reason = record.reason.clone().unwrap_or_else(|| step.to_string());
    let workflow = failed_workflow(item, step, reason);
    let changed = item.status != TaskBoardStatus::Blocked || item.workflow != workflow;
    if !changed {
        return Ok(record);
    }
    let updated_item = board.update(
        &item.id,
        TaskBoardItemPatch {
            status: Some(TaskBoardStatus::Blocked),
            workflow: Some(workflow),
            ..TaskBoardItemPatch::default()
        },
    )?;
    record.updated = true;
    record.item = Some(updated_item);
    Ok(record)
}

fn store() -> TaskBoardStore {
    TaskBoardStore::new(default_board_root())
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;

    use crate::errors::CliErrorKind;
    use crate::session::types::{TaskQueuePolicy, TaskSeverity, TaskSource, TaskStatus};
    use crate::task_board::{TaskBoardEvaluationOutcome, TaskBoardWorkflowStatus};

    use super::*;

    const NOW: &str = "2026-05-14T00:00:00Z";

    fn create_linked_item(
        store: &TaskBoardStore,
        id: &str,
        status: TaskBoardStatus,
    ) -> TaskBoardItem {
        let mut item = TaskBoardItem::new(
            id.to_string(),
            "Board item".to_string(),
            "Body".to_string(),
            NOW.to_string(),
        );
        item.status = status;
        item.session_id = Some("session-1".to_string());
        item.work_item_id = Some("work-1".to_string());
        item.workflow.execution_id = Some("workflow-1".to_string());
        item.workflow.status = TaskBoardWorkflowStatus::Running;
        item.workflow.current_step_id = Some("dispatch".to_string());
        item.workflow.attempts = 1;
        store
            .create("Board item", "Body", item)
            .expect("create item")
    }

    fn work_item(status: TaskStatus) -> WorkItem {
        WorkItem {
            task_id: "work-1".to_string(),
            title: "Session task".to_string(),
            context: None,
            severity: TaskSeverity::Medium,
            status,
            assigned_to: None,
            queue_policy: TaskQueuePolicy::Locked,
            queued_at: None,
            created_at: NOW.to_string(),
            updated_at: NOW.to_string(),
            created_by: None,
            notes: Vec::new(),
            suggested_fix: None,
            source: TaskSource::Manual,
            observe_issue_id: None,
            blocked_reason: None,
            completed_at: None,
            checkpoint_summary: None,
            awaiting_review: None,
            review_claim: None,
            consensus: None,
            review_history: Vec::new(),
            review_round: 0,
            arbitration: None,
            suggested_persona: None,
            deleted_at: None,
        }
    }

    #[test]
    fn linked_item_update_persists_task_decision() {
        let temp = tempdir().expect("tempdir");
        let store = TaskBoardStore::new(temp.path().join("task-board"));
        let item = create_linked_item(&store, "board-1", TaskBoardStatus::InProgress);

        let summary =
            evaluate_items_with_loader(&store, &[item], false, |session_id, work_item_id| {
                assert_eq!(session_id, "session-1");
                assert_eq!(work_item_id, "work-1");
                Ok(Some(work_item(TaskStatus::Done)))
            })
            .expect("evaluate item");

        assert_eq!(summary.total, 1);
        assert_eq!(summary.evaluated, 1);
        assert_eq!(summary.completed, 1);
        assert_eq!(summary.updated, 1);
        let record = &summary.records[0];
        assert_eq!(record.outcome, TaskBoardEvaluationOutcome::Completed);
        assert!(record.updated);
        assert_eq!(record.board_status, Some(TaskBoardStatus::Done));
        assert_eq!(
            record.workflow_status,
            Some(TaskBoardWorkflowStatus::Completed)
        );
        assert_eq!(
            record.item.as_ref().map(|updated| updated.status),
            Some(TaskBoardStatus::Done)
        );

        let stored = store.get("board-1").expect("load updated item");
        assert_eq!(stored.status, TaskBoardStatus::Done);
        assert_eq!(stored.workflow.status, TaskBoardWorkflowStatus::Completed);
        assert_eq!(
            stored.workflow.current_step_id.as_deref(),
            Some("completed")
        );
        assert_eq!(stored.workflow.execution_id.as_deref(), Some("workflow-1"));
    }

    #[test]
    fn missing_session_marks_linked_item_blocked() {
        let temp = tempdir().expect("tempdir");
        let store = TaskBoardStore::new(temp.path().join("task-board"));
        let item = create_linked_item(&store, "board-1", TaskBoardStatus::InProgress);

        let summary = evaluate_items_with_loader(&store, &[item], false, |_, _| {
            Err(CliErrorKind::workflow_io("session unavailable").into())
        })
        .expect("evaluate item");

        assert_eq!(summary.total, 1);
        assert_eq!(summary.failed, 1);
        assert_eq!(summary.updated, 1);
        let record = &summary.records[0];
        assert_eq!(record.outcome, TaskBoardEvaluationOutcome::MissingSession);
        assert!(record.updated);
        assert_eq!(
            record.reason.as_deref(),
            Some("[WORKFLOW_IO] session unavailable")
        );
        assert_eq!(record.board_status, Some(TaskBoardStatus::Blocked));
        assert_eq!(
            record.workflow_status,
            Some(TaskBoardWorkflowStatus::Failed)
        );

        let stored = store.get("board-1").expect("load failed item");
        assert_eq!(stored.status, TaskBoardStatus::Blocked);
        assert_eq!(stored.workflow.status, TaskBoardWorkflowStatus::Failed);
        assert_eq!(
            stored.workflow.current_step_id.as_deref(),
            Some("missing_session")
        );
        assert_eq!(
            stored.workflow.last_error.as_deref(),
            Some("[WORKFLOW_IO] session unavailable")
        );
    }

    #[test]
    fn missing_task_marks_linked_item_blocked() {
        let temp = tempdir().expect("tempdir");
        let store = TaskBoardStore::new(temp.path().join("task-board"));
        let item = create_linked_item(&store, "board-1", TaskBoardStatus::InProgress);

        let summary = evaluate_items_with_loader(&store, &[item], false, |_, _| Ok(None))
            .expect("evaluate item");

        assert_eq!(summary.total, 1);
        assert_eq!(summary.failed, 1);
        assert_eq!(summary.updated, 1);
        let record = &summary.records[0];
        assert_eq!(record.outcome, TaskBoardEvaluationOutcome::MissingTask);
        assert!(record.updated);
        assert_eq!(
            record.reason.as_deref(),
            Some("session task 'work-1' was not found")
        );
        assert_eq!(record.board_status, Some(TaskBoardStatus::Blocked));
        assert_eq!(
            record.workflow_status,
            Some(TaskBoardWorkflowStatus::Failed)
        );

        let stored = store.get("board-1").expect("load failed item");
        assert_eq!(stored.status, TaskBoardStatus::Blocked);
        assert_eq!(stored.workflow.status, TaskBoardWorkflowStatus::Failed);
        assert_eq!(
            stored.workflow.current_step_id.as_deref(),
            Some("missing_task")
        );
        assert_eq!(
            stored.workflow.last_error.as_deref(),
            Some("session task 'work-1' was not found")
        );
    }

    #[test]
    fn dry_run_leaves_sync_item_unchanged() {
        let temp = tempdir().expect("tempdir");
        let store = TaskBoardStore::new(temp.path().join("task-board"));
        let item = create_linked_item(&store, "board-1", TaskBoardStatus::InProgress);
        let before = store.get("board-1").expect("load original item");

        let summary = evaluate_items_with_loader(&store, &[item], true, |_, _| {
            Ok(Some(work_item(TaskStatus::Done)))
        })
        .expect("evaluate item");

        assert_eq!(summary.total, 1);
        assert_eq!(summary.evaluated, 1);
        assert_eq!(summary.completed, 1);
        assert_eq!(summary.updated, 0);
        let record = &summary.records[0];
        assert_eq!(record.outcome, TaskBoardEvaluationOutcome::Completed);
        assert!(!record.updated);
        assert_eq!(record.board_status, Some(TaskBoardStatus::Done));
        assert!(record.item.is_none());

        let after = store.get("board-1").expect("load item after dry run");
        assert_eq!(after.status, before.status);
        assert_eq!(after.workflow, before.workflow);
        assert_eq!(after.updated_at, before.updated_at);
    }
}
