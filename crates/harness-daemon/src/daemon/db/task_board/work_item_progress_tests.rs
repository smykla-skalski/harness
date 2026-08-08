use harness_daemon_db_queries::AsyncChangeTrackingQueries;
use sqlx::query;
use tempfile::{TempDir, tempdir};

use super::item_core_queries::ItemCoreQueries;
use super::work_item_progress::TaskBoardWorkItemReportRequest;
use super::work_item_progress_queries::{TaskBoardRuntimeTerminalReport, WorkItemProgressQueries};
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::db_open::AsyncDaemonDbConnect;
use crate::task_board::{
    AgentMode, TaskBoardItem, TaskBoardStatus, TaskBoardWorkItemReportRejection,
    TaskBoardWorkItemState, TaskBoardWorkflowStatus,
};

#[path = "work_item_progress_read_tests.rs"]
mod read_tests;

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

async fn seed_workflow_execution(fixture: &Fixture) {
    query(
        "INSERT INTO task_board_workflow_executions (
             execution_id, item_id, workflow_kind, phase, state, item_revision,
             configuration_revision, snapshot_json, resolved_reviewer_json,
             diagnostics_json, resource_ownership_json, created_at, updated_at
         ) VALUES ('workflow-1', ?1, 'pr_fix', 'executing', 'running', 1, 1,
                   '{}', '{}', '{}', '{}', 'now', 'now')",
    )
    .bind(&fixture.item_id)
    .execute(fixture.db.pool())
    .await
    .expect("seed workflow execution");
}

fn request(
    fixture: &Fixture,
    state: Option<TaskBoardWorkItemState>,
) -> TaskBoardWorkItemReportRequest {
    TaskBoardWorkItemReportRequest {
        board_item_id: fixture.item_id.clone(),
        work_item_id: fixture.work_item_id.clone(),
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
async fn a_report_from_an_old_dispatch_cannot_mutate_the_current_work_item() {
    let fixture = fixture().await;
    fixture
        .db
        .update_task_board_item(&fixture.item_id, |item| {
            item.work_item_id = Some("task-board-2".to_string());
            Ok(true)
        })
        .await
        .expect("redispatch item");

    let error = fixture
        .db
        .report_task_board_work_item_progress(&request(
            &fixture,
            Some(TaskBoardWorkItemState::Done),
        ))
        .await
        .expect_err("stale dispatch report must be refused");

    assert!(error.to_string().contains("not 'task-board-1'"));
    assert!(
        fixture
            .db
            .task_board_work_item_progress(&fixture.item_id)
            .await
            .expect("read current progress")
            .is_none()
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
        result
            .pending_worker_settlement
            .as_ref()
            .map(|settlement| settlement.worker_id.as_str()),
        Some("codex-dispatch-intent-1")
    );
}

#[tokio::test]
async fn workflow_owned_completion_requires_the_workflow_result_contract() {
    let fixture = fixture().await;
    seed_intent(&fixture, "dispatch-intent-1").await;
    seed_workflow_execution(&fixture).await;

    let error = fixture
        .db
        .report_task_board_work_item_progress(&request(
            &fixture,
            Some(TaskBoardWorkItemState::Done),
        ))
        .await
        .expect_err("workflow-owned completion must be refused");

    assert!(error.to_string().contains("workflow result contract"));
}

#[tokio::test]
async fn prepared_workflow_owns_terminal_progress_before_its_execution_row_exists() {
    let fixture = fixture().await;
    seed_intent(&fixture, "dispatch-intent-prepared-workflow").await;
    query(
        "UPDATE task_board_dispatch_intents
         SET payload_json = '{\"write_workflow\":{}}'
         WHERE intent_id = 'dispatch-intent-prepared-workflow'",
    )
    .execute(fixture.db.pool())
    .await
    .expect("mark intent as workflow-owned");

    let error = fixture
        .db
        .report_task_board_work_item_progress(&request(
            &fixture,
            Some(TaskBoardWorkItemState::Done),
        ))
        .await
        .expect_err("prepared workflow terminal report must be refused");

    assert!(error.to_string().contains("workflow result contract"));
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
        .settle_task_board_work_item_worker(&fixture.item_id, &fixture.work_item_id)
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
        repeat
            .pending_worker_settlement
            .as_ref()
            .map(|settlement| settlement.worker_id.as_str()),
        Some("codex-dispatch-intent-1")
    );
}

#[tokio::test]
async fn blocked_work_requires_a_new_dispatch_before_it_can_run_again() {
    let fixture = fixture().await;
    seed_intent(&fixture, "dispatch-intent-1").await;
    let mut blocked = request(&fixture, Some(TaskBoardWorkItemState::Blocked));
    blocked.blocked_reason = Some("needs a human decision".to_string());
    fixture
        .db
        .report_task_board_work_item_progress(&blocked)
        .await
        .expect("block the work item");
    fixture
        .db
        .settle_task_board_work_item_worker(&fixture.item_id, &fixture.work_item_id)
        .await
        .expect("settle the worker");

    let resumed = fixture
        .db
        .report_task_board_work_item_progress(&request(
            &fixture,
            Some(TaskBoardWorkItemState::Running),
        ))
        .await
        .expect("refuse reopening the work item");

    assert!(!resumed.applied);
    assert_eq!(
        resumed.rejection,
        Some(TaskBoardWorkItemReportRejection::Terminal)
    );
    assert!(resumed.progress.completed_at.is_some());
    assert!(resumed.pending_worker_settlement.is_none());
    assert_eq!(resumed.item.status, TaskBoardStatus::Failed);
}

#[tokio::test]
async fn worker_settlement_uses_the_dispatch_time_agent_mode() {
    let fixture = fixture().await;
    seed_intent(&fixture, "dispatch-intent-1").await;
    fixture
        .db
        .report_task_board_work_item_progress(&request(
            &fixture,
            Some(TaskBoardWorkItemState::Running),
        ))
        .await
        .expect("start progress");
    fixture
        .db
        .update_task_board_item(&fixture.item_id, |item| {
            item.agent_mode = AgentMode::Interactive;
            Ok(true)
        })
        .await
        .expect("change mutable item mode");

    let result = fixture
        .db
        .report_task_board_work_item_progress(&request(
            &fixture,
            Some(TaskBoardWorkItemState::Done),
        ))
        .await
        .expect("settle progress");

    let settlement = result
        .pending_worker_settlement
        .expect("worker stop remains due");
    assert_eq!(settlement.agent_mode, AgentMode::Headless);
    assert_eq!(settlement.worker_id, "codex-dispatch-intent-1");
}
