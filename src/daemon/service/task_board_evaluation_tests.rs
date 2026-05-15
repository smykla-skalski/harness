use tempfile::tempdir;

use crate::errors::CliErrorKind;
use crate::session::types::{TaskQueuePolicy, TaskSeverity, TaskSource, TaskStatus};
use crate::task_board::{TaskBoardEvaluationOutcome, TaskBoardWorkflowStatus};

use super::*;

const NOW: &str = "2026-05-14T00:00:00Z";

fn create_linked_item(store: &TaskBoardStore, id: &str, status: TaskBoardStatus) -> TaskBoardItem {
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

    let summary = evaluate_items_with_loader(
        &store,
        &[item],
        false,
        |session_id, work_item_id| {
            assert_eq!(session_id, "session-1");
            assert_eq!(work_item_id, "work-1");
            Ok(Some(work_item(TaskStatus::Done)))
        },
        |_, _, _| Ok(()),
    )
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

    let summary = evaluate_items_with_loader(
        &store,
        &[item],
        false,
        |_, _| Err(CliErrorKind::workflow_io("session unavailable").into()),
        |_, _, _| Ok(()),
    )
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

    let summary =
        evaluate_items_with_loader(&store, &[item], false, |_, _| Ok(None), |_, _, _| Ok(()))
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
fn review_pending_update_schedules_reviewer_signal() {
    let temp = tempdir().expect("tempdir");
    let store = TaskBoardStore::new(temp.path().join("task-board"));
    let item = create_linked_item(&store, "board-1", TaskBoardStatus::InProgress);
    let mut scheduled = false;

    let summary = evaluate_items_with_loader(
        &store,
        &[item],
        false,
        |_, _| Ok(Some(work_item(TaskStatus::AwaitingReview))),
        |_, task, record| {
            assert_eq!(task.status, TaskStatus::AwaitingReview);
            assert_eq!(record.outcome, TaskBoardEvaluationOutcome::ReviewPending);
            assert!(record.updated);
            scheduled = true;
            Ok(())
        },
    )
    .expect("evaluate item");

    assert!(scheduled);
    assert_eq!(summary.reviewing, 1);
    let stored = store.get("board-1").expect("load updated item");
    assert_eq!(stored.status, TaskBoardStatus::InReview);
    assert_eq!(
        stored.workflow.current_step_id.as_deref(),
        Some("review_pending")
    );
}

#[test]
fn reviewer_signal_failure_keeps_record_in_summary() {
    let temp = tempdir().expect("tempdir");
    let store = TaskBoardStore::new(temp.path().join("task-board"));
    let item_a = create_linked_item(&store, "board-a", TaskBoardStatus::InProgress);
    let mut item_b = create_linked_item(&store, "board-b", TaskBoardStatus::InProgress);
    // Distinct task ids so the loader can decide which to "fail" the signal on.
    item_b.session_id = Some("session-b".into());
    item_b.work_item_id = Some("work-b".into());
    let _ = store.update(
        "board-b",
        TaskBoardItemPatch {
            session_id: crate::task_board::store::OptionalFieldPatch::Set("session-b".into()),
            work_item_id: crate::task_board::store::OptionalFieldPatch::Set("work-b".into()),
            ..TaskBoardItemPatch::default()
        },
    );
    let item_b = store.get("board-b").expect("reload b");

    let summary = evaluate_items_with_loader(
        &store,
        &[item_a, item_b],
        false,
        |_, _| Ok(Some(work_item(TaskStatus::AwaitingReview))),
        |item, _, _| {
            if item.id == "board-b" {
                Err(CliErrorKind::workflow_io("signal write failed").into())
            } else {
                Ok(())
            }
        },
    )
    .expect("evaluate items");

    // Both records must be present even though item-b's signal failed.
    assert_eq!(summary.total, 2, "summary kept both records");
    assert_eq!(summary.reviewing, 2);
    let ids: Vec<&str> = summary
        .records
        .iter()
        .map(|record| record.board_item_id.as_str())
        .collect();
    assert!(ids.contains(&"board-a"));
    assert!(ids.contains(&"board-b"));
    assert_eq!(
        summary.signal_failures.len(),
        1,
        "exactly one signal failure recorded"
    );
    assert_eq!(summary.signal_failures[0].board_item_id, "board-b");
    assert!(
        summary.signal_failures[0]
            .message
            .contains("signal write failed")
    );
}

#[test]
fn dry_run_leaves_sync_item_unchanged() {
    let temp = tempdir().expect("tempdir");
    let store = TaskBoardStore::new(temp.path().join("task-board"));
    let item = create_linked_item(&store, "board-1", TaskBoardStatus::InProgress);
    let before = store.get("board-1").expect("load original item");

    let summary = evaluate_items_with_loader(
        &store,
        &[item],
        true,
        |_, _| Ok(Some(work_item(TaskStatus::Done))),
        |_, _, _| Ok(()),
    )
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
