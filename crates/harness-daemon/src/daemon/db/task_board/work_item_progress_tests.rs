use sqlx::query;
use tempfile::{TempDir, tempdir};

use super::item_core_queries::ItemCoreQueries;
use super::work_item_progress::TaskBoardWorkItemReportRequest;
use super::work_item_progress_queries::WorkItemProgressQueries;
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::db_open::AsyncDaemonDbConnect;
use crate::task_board::{
    AgentMode, TaskBoardItem, TaskBoardStatus, TaskBoardWorkItemReportRejection,
    TaskBoardWorkItemState, TaskBoardWorkflowStatus,
};

struct Fixture {
    _dir: TempDir,
    db: AsyncDaemonDb,
    item_id: String,
    work_item_id: String,
}

async fn fixture() -> Fixture {
    fixture_with_mode(AgentMode::Headless).await
}

async fn fixture_with_mode(agent_mode: AgentMode) -> Fixture {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("connect");
    let item_id = "board-1".to_string();
    let work_item_id = "task-board-1".to_string();
    let mut item = TaskBoardItem::new(
        item_id.clone(),
        "Dispatched item".to_string(),
        "Body".to_string(),
        "2026-08-08T00:00:00Z".to_string(),
    );
    item.agent_mode = agent_mode;
    item.status = TaskBoardStatus::InProgress;
    item.work_item_id = Some(work_item_id.clone());
    item.workflow.execution_id = Some("workflow-1".to_string());
    item.workflow.status = TaskBoardWorkflowStatus::Running;
    item.workflow.current_step_id = Some("dispatch".to_string());
    db.create_task_board_item(item).await.expect("create item");
    Fixture {
        _dir: dir,
        db,
        item_id,
        work_item_id,
    }
}

async fn seed_intent(fixture: &Fixture, intent_id: &str) {
    query(
        "INSERT INTO task_board_dispatch_intents (
             intent_id, item_id, session_id, work_item_id, workflow_execution_id,
             payload_json, status, available_at, created_at, updated_at, completed_at
         ) VALUES (?1, ?2, '', ?3, 'workflow-1', '{}', 'completed', 'now',
                   '2026-08-08T00:00:00Z', '2026-08-08T00:00:00Z', '2026-08-08T00:00:00Z')",
    )
    .bind(intent_id)
    .bind(&fixture.item_id)
    .bind(&fixture.work_item_id)
    .execute(fixture.db.pool())
    .await
    .expect("seed dispatch intent");
}

fn request(
    fixture: &Fixture,
    state: Option<TaskBoardWorkItemState>,
) -> TaskBoardWorkItemReportRequest {
    TaskBoardWorkItemReportRequest {
        board_item_id: fixture.item_id.clone(),
        actor: "agent-1".to_string(),
        state,
        summary: None,
        progress_percent: None,
        blocked_reason: None,
        sequence: None,
    }
}

#[tokio::test]
async fn first_report_creates_the_record_and_projects_the_lane() {
    let fixture = fixture().await;
    let mut request = request(&fixture, Some(TaskBoardWorkItemState::Running));
    request.summary = Some("started".to_string());
    request.progress_percent = Some(25);

    let result = fixture
        .db
        .report_task_board_work_item_progress(&request)
        .await
        .expect("report progress");

    assert!(result.applied);
    assert_eq!(result.progress.state, TaskBoardWorkItemState::Running);
    assert_eq!(result.progress.progress_percent, Some(25));
    assert_eq!(result.item.status, TaskBoardStatus::InProgress);
    assert_eq!(
        result.item.workflow.current_step_id.as_deref(),
        Some("worker")
    );
    assert_eq!(result.progress.checkpoints.len(), 1);
}

#[tokio::test]
async fn reporting_for_an_undispatched_item_is_refused() {
    let fixture = fixture().await;
    fixture
        .db
        .update_task_board_item(&fixture.item_id, |item| {
            item.work_item_id = None;
            Ok(true)
        })
        .await
        .expect("clear the work item");

    let error = fixture
        .db
        .report_task_board_work_item_progress(&request(
            &fixture,
            Some(TaskBoardWorkItemState::Running),
        ))
        .await
        .expect_err("undispatched item must be refused");

    assert!(
        error.to_string().contains("no dispatched work item"),
        "unexpected error: {error}"
    );
}

#[tokio::test]
async fn review_handoff_records_the_dispatched_attempt_and_current_revision() {
    let fixture = fixture().await;
    seed_intent(&fixture, "dispatch-intent-1").await;

    let result = fixture
        .db
        .report_task_board_work_item_progress(&request(
            &fixture,
            Some(TaskBoardWorkItemState::AwaitingReview),
        ))
        .await
        .expect("hand off for review");

    assert_eq!(
        result.progress.attempt_id.as_deref(),
        Some("codex-dispatch-intent-1")
    );
    assert!(result.progress.item_revision.is_some());
    assert_eq!(result.item.status, TaskBoardStatus::ToReview);
}

#[tokio::test]
async fn an_interactive_dispatch_resolves_its_terminal_worker() {
    let fixture = fixture_with_mode(AgentMode::Interactive).await;
    seed_intent(&fixture, "dispatch-intent-1").await;

    let result = fixture
        .db
        .report_task_board_work_item_progress(&request(
            &fixture,
            Some(TaskBoardWorkItemState::AwaitingReview),
        ))
        .await
        .expect("hand off for review");

    assert_eq!(
        result.progress.attempt_id.as_deref(),
        Some("agent-tui-dispatch-intent-1")
    );
}

#[tokio::test]
async fn completion_settles_the_item_and_owes_one_worker_stop() {
    let fixture = fixture().await;
    seed_intent(&fixture, "dispatch-intent-1").await;

    let result = fixture
        .db
        .report_task_board_work_item_progress(&request(
            &fixture,
            Some(TaskBoardWorkItemState::Done),
        ))
        .await
        .expect("settle the work item");

    assert_eq!(result.item.status, TaskBoardStatus::Done);
    assert_eq!(
        result.item.workflow.status,
        TaskBoardWorkflowStatus::Completed
    );
    assert!(result.progress.completed_at.is_some());
    assert_eq!(
        result.pending_worker_settlement.as_deref(),
        Some("codex-dispatch-intent-1")
    );
}

#[tokio::test]
async fn a_settled_worker_is_never_owed_a_second_stop() {
    let fixture = fixture().await;
    seed_intent(&fixture, "dispatch-intent-1").await;
    fixture
        .db
        .report_task_board_work_item_progress(&request(
            &fixture,
            Some(TaskBoardWorkItemState::Done),
        ))
        .await
        .expect("settle the work item");
    fixture
        .db
        .settle_task_board_work_item_worker(&fixture.work_item_id)
        .await
        .expect("settle the worker");

    let repeat = fixture
        .db
        .report_task_board_work_item_progress(&request(
            &fixture,
            Some(TaskBoardWorkItemState::Done),
        ))
        .await
        .expect("repeat the report");

    assert!(!repeat.applied);
    assert_eq!(
        repeat.rejection,
        Some(TaskBoardWorkItemReportRejection::Terminal)
    );
    assert!(repeat.pending_worker_settlement.is_none());
}

#[tokio::test]
async fn an_unfinished_stop_is_still_owed_after_a_repeat_report() {
    let fixture = fixture().await;
    seed_intent(&fixture, "dispatch-intent-1").await;
    fixture
        .db
        .report_task_board_work_item_progress(&request(
            &fixture,
            Some(TaskBoardWorkItemState::Done),
        ))
        .await
        .expect("settle the work item");

    let repeat = fixture
        .db
        .report_task_board_work_item_progress(&request(
            &fixture,
            Some(TaskBoardWorkItemState::Running),
        ))
        .await
        .expect("repeat the report");

    assert!(!repeat.applied);
    assert_eq!(
        repeat.pending_worker_settlement.as_deref(),
        Some("codex-dispatch-intent-1")
    );
}

#[tokio::test]
async fn a_settled_item_never_leaves_its_terminal_lane() {
    let fixture = fixture().await;
    fixture
        .db
        .report_task_board_work_item_progress(&request(
            &fixture,
            Some(TaskBoardWorkItemState::Done),
        ))
        .await
        .expect("settle the work item");

    fixture
        .db
        .report_task_board_work_item_progress(&request(
            &fixture,
            Some(TaskBoardWorkItemState::Running),
        ))
        .await
        .expect("repeat the report");

    let item = fixture
        .db
        .task_board_item(&fixture.item_id)
        .await
        .expect("load item");
    assert_eq!(item.status, TaskBoardStatus::Done);
}

#[tokio::test]
async fn an_out_of_order_report_leaves_the_record_untouched() {
    let fixture = fixture().await;
    let mut first = request(&fixture, Some(TaskBoardWorkItemState::Running));
    first.sequence = Some(4);
    first.summary = Some("current".to_string());
    fixture
        .db
        .report_task_board_work_item_progress(&first)
        .await
        .expect("first report");
    let mut stale = request(&fixture, Some(TaskBoardWorkItemState::AwaitingReview));
    stale.sequence = Some(2);
    stale.summary = Some("stale".to_string());

    let result = fixture
        .db
        .report_task_board_work_item_progress(&stale)
        .await
        .expect("stale report");

    assert_eq!(
        result.rejection,
        Some(TaskBoardWorkItemReportRejection::StaleSequence)
    );
    assert_eq!(result.progress.state, TaskBoardWorkItemState::Running);
    assert_eq!(result.progress.checkpoints.len(), 1);
    assert_eq!(result.item.status, TaskBoardStatus::InProgress);
}

#[tokio::test]
async fn checkpoints_persist_in_order_across_reports() {
    let fixture = fixture().await;
    for summary in ["first", "second", "third"] {
        let mut request = request(&fixture, None);
        request.summary = Some(summary.to_string());
        fixture
            .db
            .report_task_board_work_item_progress(&request)
            .await
            .expect("record checkpoint");
    }

    let progress = fixture
        .db
        .task_board_work_item_progress(&fixture.item_id)
        .await
        .expect("read progress")
        .expect("record exists");

    let summaries: Vec<&str> = progress
        .checkpoints
        .iter()
        .map(|checkpoint| checkpoint.summary.as_str())
        .collect();
    assert_eq!(summaries, ["first", "second", "third"]);
    assert_eq!(progress.report_sequence, 3);
}

#[tokio::test]
async fn reading_an_unknown_item_is_refused() {
    let fixture = fixture().await;

    let error = fixture
        .db
        .task_board_work_item_progress("board-missing")
        .await
        .expect_err("unknown item must be refused");

    assert!(
        error.to_string().contains("not found"),
        "unexpected error: {error}"
    );
}

#[tokio::test]
async fn reading_an_undispatched_item_returns_no_record() {
    let fixture = fixture().await;
    fixture
        .db
        .update_task_board_item(&fixture.item_id, |item| {
            item.work_item_id = None;
            Ok(true)
        })
        .await
        .expect("clear the work item");

    let progress = fixture
        .db
        .task_board_work_item_progress(&fixture.item_id)
        .await
        .expect("read progress");

    assert!(progress.is_none());
}

#[tokio::test]
async fn a_pure_checkpoint_does_not_churn_the_item_revision() {
    let fixture = fixture().await;
    let before = fixture
        .db
        .task_board_item_snapshot(&fixture.item_id)
        .await
        .expect("load snapshot")
        .item_revision;
    let mut request = request(&fixture, None);
    request.summary = Some("still working".to_string());

    fixture
        .db
        .report_task_board_work_item_progress(&request)
        .await
        .expect("record checkpoint");

    let after = fixture
        .db
        .task_board_item_snapshot(&fixture.item_id)
        .await
        .expect("load snapshot")
        .item_revision;
    assert_eq!(before, after);
}

#[tokio::test]
async fn blocking_surfaces_the_reason_on_the_board_item() {
    let fixture = fixture().await;
    let mut request = request(&fixture, Some(TaskBoardWorkItemState::Blocked));
    request.blocked_reason = Some("needs a human decision".to_string());

    let result = fixture
        .db
        .report_task_board_work_item_progress(&request)
        .await
        .expect("block the work item");

    assert_eq!(result.item.status, TaskBoardStatus::Failed);
    assert_eq!(result.item.workflow.status, TaskBoardWorkflowStatus::Failed);
    assert_eq!(
        result.item.workflow.last_error.as_deref(),
        Some("needs a human decision")
    );
}
