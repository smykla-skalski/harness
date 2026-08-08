use super::*;

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
async fn an_unrepresentable_report_fence_is_refused() {
    let fixture = fixture().await;
    let mut request = request(&fixture, None);
    request.summary = Some("still working".to_string());
    request.sequence = Some(u64::MAX);

    let error = fixture
        .db
        .report_task_board_work_item_progress(&request)
        .await
        .expect_err("an out-of-range fence must be refused");
    assert!(
        error.to_string().contains("out of range"),
        "unexpected error: {error}"
    );
    assert!(
        fixture
            .db
            .task_board_work_item_progress(&fixture.item_id)
            .await
            .expect("read progress")
            .is_none(),
        "a refused report must not create a record"
    );
}

#[tokio::test]
async fn a_bare_checkpoint_marks_the_item_running() {
    let fixture = fixture().await;
    let mut request = request(&fixture, None);
    request.summary = Some("started".to_string());

    let result = fixture
        .db
        .report_task_board_work_item_progress(&request)
        .await
        .expect("record a checkpoint");
    assert_eq!(result.progress.state, TaskBoardWorkItemState::Running);
    assert_eq!(
        result.item.workflow.current_step_id.as_deref(),
        Some("worker")
    );
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
async fn same_named_session_tasks_keep_independent_progress() {
    let fixture = fixture().await;
    let mut second = TaskBoardItem::new(
        "board-2".to_string(),
        "Second dispatched item".to_string(),
        "Body".to_string(),
        "2026-08-08T00:00:00Z".to_string(),
    );
    second.status = TaskBoardStatus::InProgress;
    second.work_item_id = Some(fixture.work_item_id.clone());
    second.workflow.execution_id = Some("workflow-2".to_string());
    second.workflow.status = TaskBoardWorkflowStatus::Running;
    fixture
        .db
        .create_task_board_item(second)
        .await
        .expect("create second item");

    let mut first_report = request(&fixture, Some(TaskBoardWorkItemState::Running));
    first_report.summary = Some("first item".to_string());
    fixture
        .db
        .report_task_board_work_item_progress(&first_report)
        .await
        .expect("report first item");
    let second_report = TaskBoardWorkItemReportRequest {
        board_item_id: "board-2".to_string(),
        work_item_id: fixture.work_item_id.clone(),
        actor: "agent-2".to_string(),
        state: Some(TaskBoardWorkItemState::AwaitingReview),
        summary: Some("second item".to_string()),
        progress_percent: None,
        blocked_reason: None,
        sequence: None,
    };
    fixture
        .db
        .report_task_board_work_item_progress(&second_report)
        .await
        .expect("report second item");

    let first = fixture
        .db
        .task_board_work_item_progress(&fixture.item_id)
        .await
        .expect("read first progress")
        .expect("first progress exists");
    let second = fixture
        .db
        .task_board_work_item_progress("board-2")
        .await
        .expect("read second progress")
        .expect("second progress exists");
    assert_eq!(first.state, TaskBoardWorkItemState::Running);
    assert_eq!(first.summary.as_deref(), Some("first item"));
    assert_eq!(second.state, TaskBoardWorkItemState::AwaitingReview);
    assert_eq!(second.summary.as_deref(), Some("second item"));
}

#[tokio::test]
async fn a_pure_checkpoint_publishes_without_churning_the_item_revision() {
    let fixture = fixture().await;
    fixture
        .db
        .report_task_board_work_item_progress(&request(
            &fixture,
            Some(TaskBoardWorkItemState::Running),
        ))
        .await
        .expect("land the lane");
    let before = fixture
        .db
        .task_board_item_snapshot(&fixture.item_id)
        .await
        .expect("load snapshot")
        .item_revision;
    let change_before = fixture
        .db
        .current_change_sequence()
        .await
        .expect("load change sequence");
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
    let change_after = fixture
        .db
        .current_change_sequence()
        .await
        .expect("load updated change sequence");
    assert_eq!(before, after);
    assert_eq!(change_after, change_before + 1);
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
