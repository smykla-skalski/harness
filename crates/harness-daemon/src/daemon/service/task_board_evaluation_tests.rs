use tempfile::{TempDir, tempdir};

use crate::daemon::db::AsyncDaemonDb;
use crate::session::types::{
    ReviewConsensus, ReviewVerdict, TaskQueuePolicy, TaskSeverity, TaskSource, TaskStatus,
};
use crate::task_board::{
    TaskBoardEvaluationOutcome, TaskBoardWorkItemState, TaskBoardWorkflowStatus,
};

use super::*;
use crate::daemon::db_open::AsyncDaemonDbConnect;

const NOW: &str = "2026-05-14T00:00:00Z";

struct Fixture {
    _dir: TempDir,
    db: AsyncDaemonDbHandle,
}

async fn fixture() -> Fixture {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDbHandle(
        AsyncDaemonDb::connect(&dir.path().join("harness.db"))
            .await
            .expect("open database"),
    );
    Fixture { _dir: dir, db }
}

async fn create_item(fixture: &Fixture, id: &str, session_id: Option<&str>) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        id.to_string(),
        "Board item".to_string(),
        "Body".to_string(),
        NOW.to_string(),
    );
    item.status = TaskBoardStatus::InProgress;
    item.session_id = session_id.map(ToString::to_string);
    item.work_item_id = Some(format!("work-{id}"));
    item.workflow.execution_id = Some("workflow-1".to_string());
    item.workflow.status = TaskBoardWorkflowStatus::Running;
    item.workflow.current_step_id = Some("dispatch".to_string());
    item.workflow.attempts = 1;
    fixture
        .db
        .create_task_board_item(item)
        .await
        .expect("create item")
        .item
}

fn work_item(status: TaskStatus) -> WorkItem {
    WorkItem {
        task_id: "work-board-1".to_string(),
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

async fn seed_active_dispatch_reservation(db: &AsyncDaemonDbHandle, item_id: &str) {
    sqlx::query(
        "INSERT INTO task_board_dispatch_intents (
             intent_id, item_id, session_id, work_item_id, workflow_execution_id,
             payload_json, status, attempts, available_at, claim_token, claimed_at,
             created_at, updated_at
         ) VALUES ('intent-1', ?1, 'session-1', ?2, 'workflow-1', '{}',
                   'pending', 0, ?3, NULL, NULL, ?3, ?3)",
    )
    .bind(item_id)
    .bind(format!("work-{item_id}"))
    .bind(NOW)
    .execute(db.pool())
    .await
    .expect("seed dispatch reservation");
}

#[tokio::test]
async fn a_translated_session_task_moves_the_item_through_the_durable_record() {
    let fixture = fixture().await;
    let item = create_item(&fixture, "board-1", Some("session-1")).await;

    let record = translate_session_task(&fixture.db, &item, &work_item(TaskStatus::Done), false)
        .await
        .expect("translate the session task");

    assert!(record.updated);
    assert_eq!(record.outcome, TaskBoardEvaluationOutcome::Completed);
    assert_eq!(record.task_status, Some(TaskStatus::Done));
    assert_eq!(record.work_item_state, Some(TaskBoardWorkItemState::Done));
    let stored = fixture
        .db
        .task_board_item(&item.id)
        .await
        .expect("reload item");
    assert_eq!(stored.status, TaskBoardStatus::Done);
    assert_eq!(stored.workflow.status, TaskBoardWorkflowStatus::Completed);
    assert_eq!(
        stored.workflow.current_step_id.as_deref(),
        Some("completed")
    );
    assert_eq!(stored.workflow.execution_id.as_deref(), Some("workflow-1"));
}

#[tokio::test]
async fn translation_creates_no_session_task() {
    let fixture = fixture().await;
    let item = create_item(&fixture, "board-1", Some("session-1")).await;

    translate_session_task(
        &fixture.db,
        &item,
        &work_item(TaskStatus::InProgress),
        false,
    )
    .await
    .expect("translate the session task");

    let tasks: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM tasks")
        .fetch_one(fixture.db.pool())
        .await
        .expect("count session tasks");
    assert_eq!(tasks, 0, "translation must not mint a Session task");
}

#[tokio::test]
async fn rerunning_translation_on_settled_work_reports_it_unchanged() {
    let fixture = fixture().await;
    let item = create_item(&fixture, "board-1", Some("session-1")).await;
    translate_session_task(&fixture.db, &item, &work_item(TaskStatus::Done), false)
        .await
        .expect("settle the work item");
    let settled = fixture
        .db
        .task_board_item(&item.id)
        .await
        .expect("reload item");

    let record = translate_session_task(
        &fixture.db,
        &settled,
        &work_item(TaskStatus::InProgress),
        false,
    )
    .await
    .expect("rerun the translation");

    assert!(!record.updated, "settled work must report as unchanged");
    assert_eq!(record.outcome, TaskBoardEvaluationOutcome::Completed);
    let stored = fixture
        .db
        .task_board_item(&item.id)
        .await
        .expect("reload item");
    assert_eq!(stored.status, TaskBoardStatus::Done);
}

#[tokio::test]
async fn a_dry_run_translation_leaves_the_item_and_record_alone() {
    let fixture = fixture().await;
    let item = create_item(&fixture, "board-1", Some("session-1")).await;

    let record = translate_session_task(&fixture.db, &item, &work_item(TaskStatus::Done), true)
        .await
        .expect("translate as a dry run");

    assert!(!record.updated);
    assert_eq!(record.outcome, TaskBoardEvaluationOutcome::Completed);
    assert_eq!(record.board_status, Some(TaskBoardStatus::Done));
    assert!(record.item.is_none());
    let stored = fixture
        .db
        .task_board_item(&item.id)
        .await
        .expect("reload item");
    assert_eq!(stored.status, TaskBoardStatus::InProgress);
    assert!(
        fixture
            .db
            .task_board_work_item_progress(&item.id)
            .await
            .expect("read progress")
            .is_none()
    );
}

#[tokio::test]
async fn a_review_handoff_is_what_schedules_the_reviewer_signal() {
    let fixture = fixture().await;
    let item = create_item(&fixture, "board-1", Some("session-1")).await;
    let task = work_item(TaskStatus::AwaitingReview);

    let record = translate_session_task(&fixture.db, &item, &task, false)
        .await
        .expect("hand off for review");

    assert!(should_materialize_reviewer_signal(&task, &record));
    let stored = fixture
        .db
        .task_board_item(&item.id)
        .await
        .expect("reload item");
    assert_eq!(stored.status, TaskBoardStatus::ToReview);
    assert_eq!(
        stored.workflow.current_step_id.as_deref(),
        Some("review_pending")
    );
}

#[tokio::test]
async fn an_unchanged_review_handoff_schedules_nothing() {
    let fixture = fixture().await;
    let item = create_item(&fixture, "board-1", Some("session-1")).await;
    let task = work_item(TaskStatus::AwaitingReview);
    translate_session_task(&fixture.db, &item, &task, false)
        .await
        .expect("hand off for review");
    let handed_off = fixture
        .db
        .task_board_item(&item.id)
        .await
        .expect("reload item");

    let repeat = translate_session_task(&fixture.db, &handed_off, &task, false)
        .await
        .expect("rerun the handoff");

    // The record still advances - every evaluation pass takes a fresh sequence -
    // but the item is already in the review lane, so nothing moved and the
    // reviewer is not signalled again. Without that distinction every pass over
    // an awaiting-review item would re-spawn its reviewer.
    assert!(
        !repeat.updated,
        "an unmoved item must not report as updated"
    );
    assert!(!should_materialize_reviewer_signal(&task, &repeat));
}

#[tokio::test]
async fn evaluation_defers_its_item_write_until_the_dispatch_claims() {
    let fixture = fixture().await;
    let item = create_item(&fixture, "board-1", Some("session-1")).await;
    let before = fixture
        .db
        .task_board_item_snapshot(&item.id)
        .await
        .expect("load item before evaluation");
    seed_active_dispatch_reservation(&fixture.db, &item.id).await;

    translate_session_task(&fixture.db, &item, &work_item(TaskStatus::Open), false)
        .await
        .expect("evaluate the reserved item");

    let reserved = fixture
        .db
        .task_board_item_snapshot(&item.id)
        .await
        .expect("reload reserved item");
    assert_eq!(reserved.item_revision, before.item_revision);
    assert_eq!(reserved.item, before.item);

    sqlx::query(
        "UPDATE task_board_dispatch_intents
         SET status = 'completed', completed_at = ?1 WHERE intent_id = 'intent-1'",
    )
    .bind(NOW)
    .execute(fixture.db.pool())
    .await
    .expect("complete dispatch reservation");
    translate_session_task(
        &fixture.db,
        &reserved.item,
        &work_item(TaskStatus::Open),
        false,
    )
    .await
    .expect("evaluate the claimed item");

    let evaluated = fixture
        .db
        .task_board_item_snapshot(&item.id)
        .await
        .expect("reload evaluated item");
    assert_eq!(evaluated.item_revision, before.item_revision + 1);
    assert_eq!(
        evaluated.item.workflow.current_step_id.as_deref(),
        Some("worker_pending")
    );
}

#[tokio::test]
async fn a_review_asking_for_changes_reports_the_reason_it_sent_back() {
    let fixture = fixture().await;
    let item = create_item(&fixture, "board-1", Some("session-1")).await;
    let mut task = work_item(TaskStatus::InReview);
    task.consensus = Some(ReviewConsensus {
        verdict: ReviewVerdict::RequestChanges,
        summary: "Needs one fix".to_string(),
        points: Vec::new(),
        closed_at: NOW.to_string(),
        reviewer_agent_ids: vec!["reviewer-1".to_string()],
    });

    let record = translate_session_task(&fixture.db, &item, &task, false)
        .await
        .expect("translate the session task");

    assert_eq!(
        record.outcome,
        TaskBoardEvaluationOutcome::ReviewChangesRequested
    );
    assert_eq!(record.reason.as_deref(), Some("Needs one fix"));
    let stored = fixture
        .db
        .task_board_item(&item.id)
        .await
        .expect("reload item");
    assert_eq!(
        stored.workflow.last_error.as_deref(),
        Some("Needs one fix"),
        "the board item must carry what the reviewer sent it back for"
    );
}

#[tokio::test]
async fn a_dry_run_reports_the_same_reason_as_a_real_run() {
    let fixture = fixture().await;
    let item = create_item(&fixture, "board-1", Some("session-1")).await;
    let mut task = work_item(TaskStatus::InReview);
    task.consensus = Some(ReviewConsensus {
        verdict: ReviewVerdict::RequestChanges,
        summary: "Needs one fix".to_string(),
        points: Vec::new(),
        closed_at: NOW.to_string(),
        reviewer_agent_ids: vec!["reviewer-1".to_string()],
    });

    let dry_run = translate_session_task(&fixture.db, &item, &task, true)
        .await
        .expect("dry run");
    let real = translate_session_task(&fixture.db, &item, &task, false)
        .await
        .expect("real run");

    assert_eq!(dry_run.reason, real.reason);
    assert_eq!(dry_run.outcome, real.outcome);
    assert_eq!(dry_run.board_status, real.board_status);
}

#[tokio::test]
async fn a_sessionless_item_reports_its_durable_record_without_writing() {
    let fixture = fixture().await;
    let item = create_item(&fixture, "board-1", None).await;
    fixture
        .db
        .report_task_board_work_item_progress(&TaskBoardWorkItemReportRequest {
            board_item_id: item.id.clone(),
            actor: "agent-1".to_string(),
            state: Some(TaskBoardWorkItemState::AwaitingReview),
            summary: Some("ready for review".to_string()),
            progress_percent: None,
            blocked_reason: None,
            sequence: None,
        })
        .await
        .expect("report progress");
    let before = fixture
        .db
        .task_board_item_snapshot(&item.id)
        .await
        .expect("load item after the report");

    let record = sessionless_record(&fixture.db, &before.item)
        .await
        .expect("evaluate the sessionless item");

    assert_eq!(record.outcome, TaskBoardEvaluationOutcome::ReviewPending);
    assert_eq!(record.task_status, None);
    assert_eq!(
        record.work_item_state,
        Some(TaskBoardWorkItemState::AwaitingReview)
    );
    assert!(!record.updated);
    let after = fixture
        .db
        .task_board_item_snapshot(&item.id)
        .await
        .expect("reload item");
    assert_eq!(after.item_revision, before.item_revision);
}

#[tokio::test]
async fn a_sessionless_item_that_never_reported_is_skipped() {
    let fixture = fixture().await;
    let item = create_item(&fixture, "board-1", None).await;

    let record = sessionless_record(&fixture.db, &item)
        .await
        .expect("evaluate the sessionless item");

    assert_eq!(record.outcome, TaskBoardEvaluationOutcome::SkippedUnlinked);
}

#[tokio::test]
async fn an_undispatched_item_is_skipped() {
    let fixture = fixture().await;
    let item = create_item(&fixture, "board-1", None).await;
    fixture
        .db
        .update_task_board_item(&item.id, |item| {
            item.work_item_id = None;
            Ok(true)
        })
        .await
        .expect("clear the work item");

    let summary = evaluate_task_board_async(
        &TaskBoardEvaluateRequest {
            item_id: Some(item.id.clone()),
            ..TaskBoardEvaluateRequest::default()
        },
        &fixture.db,
    )
    .await
    .expect("evaluate the board");

    assert_eq!(summary.total, 1);
    assert_eq!(summary.skipped, 1);
    assert_eq!(
        summary.records[0].outcome,
        TaskBoardEvaluationOutcome::SkippedUnlinked
    );
}

#[tokio::test]
async fn a_missing_session_marks_its_linked_item_failed() {
    let fixture = fixture().await;
    let item = create_item(&fixture, "board-1", Some("session-missing")).await;

    let summary = evaluate_task_board_async(
        &TaskBoardEvaluateRequest {
            item_id: Some(item.id.clone()),
            ..TaskBoardEvaluateRequest::default()
        },
        &fixture.db,
    )
    .await
    .expect("evaluate the board");

    let record = &summary.records[0];
    assert_eq!(record.outcome, TaskBoardEvaluationOutcome::MissingSession);
    assert!(record.updated);
    assert_eq!(record.board_status, Some(TaskBoardStatus::Failed));
    let stored = fixture
        .db
        .task_board_item(&item.id)
        .await
        .expect("reload item");
    assert_eq!(stored.status, TaskBoardStatus::Failed);
    assert_eq!(
        stored.workflow.current_step_id.as_deref(),
        Some("missing_session")
    );
}

#[tokio::test]
async fn a_missing_session_leaves_the_item_alone_on_a_dry_run() {
    let fixture = fixture().await;
    let item = create_item(&fixture, "board-1", Some("session-missing")).await;

    let summary = evaluate_task_board_async(
        &TaskBoardEvaluateRequest {
            item_id: Some(item.id.clone()),
            dry_run: true,
            ..TaskBoardEvaluateRequest::default()
        },
        &fixture.db,
    )
    .await
    .expect("evaluate the board");

    assert!(!summary.records[0].updated);
    let stored = fixture
        .db
        .task_board_item(&item.id)
        .await
        .expect("reload item");
    assert_eq!(stored.status, TaskBoardStatus::InProgress);
}
