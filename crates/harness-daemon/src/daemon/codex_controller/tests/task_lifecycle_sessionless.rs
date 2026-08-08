use crate::daemon::db::task_board::prelude::*;
use crate::daemon::protocol::CodexRunStatus;
use crate::task_board::{
    TaskBoardItem, TaskBoardStatus, TaskBoardWorkItemState, TaskBoardWorkflowStatus,
};

use super::super::completion_evidence::record_clean_worktree_baseline;
use super::test_support::{
    codex_run_snapshot, controller_with_async_session_state, sample_session_state_with_open_task,
    with_isolated_async_harness_env,
};

#[tokio::test(flavor = "multi_thread")]
async fn sessionless_completion_hands_off_the_exact_work_item_once() {
    Box::pin(with_isolated_async_harness_env(|_| async move {
        let (controller, db, _tempdir) =
            controller_with_async_session_state(sample_session_state_with_open_task()).await;
        let mut item = TaskBoardItem::new(
            "board-sessionless".into(),
            "Sessionless task".into(),
            "Implement the task".into(),
            "2026-08-08T00:00:00Z".into(),
        );
        item.status = TaskBoardStatus::InProgress;
        item.work_item_id = Some("work-sessionless".into());
        item.workflow.execution_id = Some("dispatch-sessionless".into());
        item.workflow.status = TaskBoardWorkflowStatus::Running;
        item.workflow.current_step_id = Some("worker".into());
        db.create_task_board_item(item)
            .await
            .expect("create sessionless board item");

        let worktree = tempfile::tempdir().expect("worktree");
        harness_testkit::init_git_repo_with_seed(worktree.path());
        let mut run = codex_run_snapshot(CodexRunStatus::Completed);
        run.task_id = Some("work-sessionless".into());
        run.board_item_id = Some("board-sessionless".into());
        run.session_agent_id = None;
        run.project_dir = worktree.path().display().to_string();
        run.final_message = Some("Implemented the requested flow.".into());
        record_clean_worktree_baseline(&mut run);
        fs_err::write(worktree.path().join("implemented.txt"), "done\n").expect("change worktree");

        controller
            .sync_orchestration_status_for_run(&run)
            .expect("settle sessionless run");
        let first = db
            .task_board_work_item_progress("board-sessionless")
            .await
            .expect("read worker progress")
            .expect("completion created progress");
        assert_eq!(first.state, TaskBoardWorkItemState::AwaitingReview);
        assert_eq!(first.report_sequence, 1);

        controller
            .sync_orchestration_status_for_run(&run)
            .expect("repeat terminal callback");
        let repeated = db
            .task_board_work_item_progress("board-sessionless")
            .await
            .expect("read repeated progress")
            .expect("progress remains available");
        assert_eq!(repeated.report_sequence, 1);
        assert_eq!(repeated.checkpoints.len(), 1);
    }))
    .await;
}
