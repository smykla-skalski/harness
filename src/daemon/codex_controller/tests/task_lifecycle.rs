use tokio::sync::mpsc;

use crate::daemon::protocol::{CodexRunStatus, TaskSubmitForReviewRequest};
use crate::daemon::service as daemon_service;
use crate::session::storage as session_storage;
use crate::session::types::{AgentStatus, SessionRole, SessionStatus, TaskStatus};
use crate::task_board::{TaskBoardItem, TaskBoardStatus, TaskBoardWorkflowStatus};

use super::super::completion_evidence::record_clean_worktree_baseline;
use super::super::worker::CodexRunWorker;
use super::durable_run_request;
use super::test_support::{
    assert_worker_checkpoint, codex_run_snapshot, controller_with_async_session_state,
    controller_with_session_state, sample_session_state_with_open_task,
    sample_session_state_with_open_task_and_codex_agent, with_isolated_async_harness_env,
};

const SESSION_ID: &str = "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc";

fn register_bound_worker(
    controller: &crate::daemon::codex_controller::CodexControllerHandle,
) -> String {
    let mut request = durable_run_request();
    request.task_id = Some("task-1".into());
    controller
        .register_orchestration_agent(SESSION_ID, "codex-run-1", &request, "Codex Worker")
        .expect("register bound worker")
        .agent_id
}

#[test]
fn registration_assigns_bound_task_and_starts_it() {
    let (controller, db, _tempdir) =
        controller_with_session_state(sample_session_state_with_open_task());
    let agent_id = register_bound_worker(&controller);

    let state = db
        .lock()
        .expect("db lock")
        .load_session_state_for_mutation(SESSION_ID)
        .expect("load session")
        .expect("session");
    let task = state.tasks.get("task-1").expect("bound task");
    assert_eq!(task.status, TaskStatus::InProgress);
    assert_eq!(task.assigned_to.as_deref(), Some(agent_id.as_str()));
    assert_eq!(
        state.agents[&agent_id].current_task_id.as_deref(),
        Some("task-1")
    );
}

#[test]
fn registration_assigns_task_to_session_activating_leader() {
    let mut initial = sample_session_state_with_open_task();
    initial.status = SessionStatus::AwaitingLeader;
    let (controller, db, _tempdir) = controller_with_session_state(initial);
    let mut request = durable_run_request();
    request.role = SessionRole::Leader;
    request.fallback_role = Some(SessionRole::Worker);
    request.task_id = Some("task-1".into());

    let agent_id = controller
        .register_orchestration_agent(SESSION_ID, "codex-run-1", &request, "Codex Leader")
        .expect("register bound session-activating leader")
        .agent_id;

    let state = db
        .lock()
        .expect("db lock")
        .load_session_state_for_mutation(SESSION_ID)
        .expect("load session")
        .expect("session");
    assert_eq!(state.status, SessionStatus::Active);
    assert_eq!(state.leader_id.as_deref(), Some(agent_id.as_str()));
    assert_eq!(state.agents[&agent_id].role, SessionRole::Leader);
    assert_eq!(state.tasks["task-1"].status, TaskStatus::InProgress);
    assert_eq!(
        state.tasks["task-1"].assigned_to.as_deref(),
        Some(agent_id.as_str())
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn registration_mirrors_worker_assignment_to_session_file() {
    with_isolated_async_harness_env(|_| async move {
        let (controller, _db, tempdir) =
            controller_with_async_session_state(sample_session_state_with_open_task()).await;
        let agent_id = register_bound_worker(&controller);
        let layout =
            session_storage::layout_from_project_dir(&tempdir.path().join("project"), SESSION_ID)
                .expect("session layout");

        let state = session_storage::load_state(&layout)
            .expect("load mirrored session")
            .expect("mirrored session state");
        assert_eq!(state.agents.len(), 1);
        assert_eq!(
            state.agents[&agent_id].current_task_id.as_deref(),
            Some("task-1")
        );
        assert_eq!(state.tasks["task-1"].status, TaskStatus::InProgress);
        assert_eq!(
            state.tasks["task-1"].assigned_to.as_deref(),
            Some(agent_id.as_str())
        );
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn registration_mirror_failure_rolls_back_agent_and_task_assignment() {
    with_isolated_async_harness_env(|_| async move {
        let (controller, db, tempdir) =
            controller_with_async_session_state(sample_session_state_with_open_task()).await;
        let layout =
            session_storage::layout_from_project_dir(&tempdir.path().join("project"), SESSION_ID)
                .expect("session layout");
        fs_err::remove_dir_all(layout.session_root()).expect("remove session mirror root");
        fs_err::write(layout.session_root(), "not a directory").expect("block session mirror root");
        let mut request = durable_run_request();
        request.task_id = Some("task-1".into());

        controller
            .register_orchestration_agent(SESSION_ID, "codex-run-1", &request, "Codex Worker")
            .expect_err("session mirror failure must fail registration");

        let resolved = db
            .resolve_session(SESSION_ID)
            .await
            .expect("load session")
            .expect("session");
        assert!(resolved.state.agents.is_empty());
        assert_eq!(resolved.state.tasks["task-1"].status, TaskStatus::Open);
        assert!(resolved.state.tasks["task-1"].assigned_to.is_none());
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn registration_mirror_failure_rolls_back_new_binding_only() {
    with_isolated_async_harness_env(|_| async move {
        let initial = sample_session_state_with_open_task_and_codex_agent();
        let (controller, db, tempdir) = controller_with_async_session_state(initial).await;
        let layout =
            session_storage::layout_from_project_dir(&tempdir.path().join("project"), SESSION_ID)
                .expect("session layout");
        fs_err::remove_dir_all(layout.session_root()).expect("remove session mirror root");
        fs_err::write(layout.session_root(), "not a directory").expect("block session mirror root");

        let mut request = durable_run_request();
        request.task_id = Some("task-1".into());
        controller
            .register_orchestration_agent(SESSION_ID, "codex-run-1", &request, "Codex Worker")
            .expect_err("session mirror failure must fail existing-agent binding");

        let resolved = db
            .resolve_session(SESSION_ID)
            .await
            .expect("load session")
            .expect("session");
        assert_eq!(resolved.state.agents.len(), 1);
        assert_eq!(resolved.state.agents["agent-1"].status, AgentStatus::Active);
        assert!(resolved.state.agents["agent-1"].current_task_id.is_none());
        assert_eq!(resolved.state.tasks["task-1"].status, TaskStatus::Open);
        assert!(resolved.state.tasks["task-1"].assigned_to.is_none());
    })
    .await;
}

#[test]
fn registration_is_idempotent_for_same_managed_run() {
    let (controller, db, _tempdir) =
        controller_with_session_state(sample_session_state_with_open_task());
    let first_agent_id = register_bound_worker(&controller);
    let second_agent_id = register_bound_worker(&controller);

    assert_eq!(second_agent_id, first_agent_id);
    let state = db
        .lock()
        .expect("db lock")
        .load_session_state_for_mutation(SESSION_ID)
        .expect("load session")
        .expect("session");
    assert_eq!(state.agents.len(), 1);
    assert_eq!(state.tasks["task-1"].status, TaskStatus::InProgress);
}

#[test]
fn completed_bound_run_submits_task_for_review() {
    let (controller, db, _tempdir) =
        controller_with_session_state(sample_session_state_with_open_task());
    let agent_id = register_bound_worker(&controller);
    let mut run = codex_run_snapshot(CodexRunStatus::Completed);
    run.task_id = Some("task-1".into());
    run.session_agent_id = Some(agent_id);
    run.final_message = Some("Implemented the requested flow.".into());
    let worktree = tempfile::tempdir().expect("worktree");
    harness_testkit::init_git_repo_with_seed(worktree.path());
    run.project_dir = worktree.path().display().to_string();
    record_clean_worktree_baseline(&mut run);
    fs_err::write(worktree.path().join("implemented.txt"), "done\n").expect("change worktree");

    controller
        .sync_orchestration_status_for_run(&run)
        .expect("bridge completed run");

    let state = db
        .lock()
        .expect("db lock")
        .load_session_state_for_mutation(SESSION_ID)
        .expect("load session")
        .expect("session");
    let task = state.tasks.get("task-1").expect("bound task");
    assert_eq!(task.status, TaskStatus::AwaitingReview);
    assert_eq!(
        task.awaiting_review
            .as_ref()
            .and_then(|review| review.summary.as_deref()),
        Some("Implemented the requested flow.")
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn completed_bound_run_advances_linked_board_item() {
    with_isolated_async_harness_env(|_| async move {
        let (controller, db, _tempdir) =
            controller_with_async_session_state(sample_session_state_with_open_task()).await;
        let mut item = TaskBoardItem::new(
            "board-1".into(),
            "Board task".into(),
            "Implement the board task".into(),
            "2026-04-09T10:00:00Z".into(),
        );
        item.status = TaskBoardStatus::InProgress;
        item.session_id = Some(SESSION_ID.into());
        item.work_item_id = Some("task-1".into());
        item.workflow.execution_id = Some("workflow-1".into());
        item.workflow.status = TaskBoardWorkflowStatus::Running;
        item.workflow.current_step_id = Some("worker".into());
        db.create_task_board_item(item)
            .await
            .expect("create board item");

        let agent_id = register_bound_worker(&controller);
        let mut run = codex_run_snapshot(CodexRunStatus::Completed);
        run.task_id = Some("task-1".into());
        run.board_item_id = Some("board-1".into());
        run.session_agent_id = Some(agent_id);
        run.final_message = Some("Implemented the requested flow.".into());
        let worktree = tempfile::tempdir().expect("worktree");
        harness_testkit::init_git_repo_with_seed(worktree.path());
        run.project_dir = worktree.path().display().to_string();
        record_clean_worktree_baseline(&mut run);
        fs_err::write(worktree.path().join("implemented.txt"), "done\n").expect("change worktree");

        controller
            .sync_orchestration_status_for_run(&run)
            .expect("bridge completed run");

        let item = db.task_board_item("board-1").await.expect("board item");
        assert_eq!(item.status, TaskBoardStatus::ToReview);
        assert_eq!(item.workflow.status, TaskBoardWorkflowStatus::Running);
        assert_eq!(
            item.workflow.current_step_id.as_deref(),
            Some("review_pending")
        );
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn completed_bound_run_advances_board_after_worker_submits_review() {
    with_isolated_async_harness_env(|_| async move {
        let (controller, db, _tempdir) =
            controller_with_async_session_state(sample_session_state_with_open_task()).await;
        let mut item = TaskBoardItem::new(
            "board-1".into(),
            "Board task".into(),
            "Implement the board task".into(),
            "2026-04-09T10:00:00Z".into(),
        );
        item.status = TaskBoardStatus::InProgress;
        item.session_id = Some(SESSION_ID.into());
        item.work_item_id = Some("task-1".into());
        item.workflow.execution_id = Some("workflow-1".into());
        item.workflow.status = TaskBoardWorkflowStatus::Running;
        item.workflow.current_step_id = Some("worker_running".into());
        db.create_task_board_item(item)
            .await
            .expect("create board item");

        let agent_id = register_bound_worker(&controller);
        assert_worker_checkpoint(&db, SESSION_ID, "task-1", &agent_id).await;
        daemon_service::submit_for_review_async(
            SESSION_ID,
            "task-1",
            &TaskSubmitForReviewRequest {
                actor: agent_id.clone(),
                summary: Some("Worker submitted directly.".into()),
                suggested_persona: None,
            },
            &db,
        )
        .await
        .expect("assigned worker submits task through daemon service");
        let mut run = codex_run_snapshot(CodexRunStatus::Running);
        run.task_id = Some("task-1".into());
        run.board_item_id = Some("board-1".into());
        run.session_agent_id = Some(agent_id);
        let (_control, control_rx) = mpsc::unbounded_channel();
        let mut worker = CodexRunWorker::new(controller, run, control_rx);
        worker
            .handle_turn_completed(Some("completed"), None)
            .expect("finish self-submitted worker");

        assert_eq!(worker.snapshot.status, CodexRunStatus::Completed);

        let item = db.task_board_item("board-1").await.expect("board item");
        assert_eq!(item.status, TaskBoardStatus::ToReview);
        assert_eq!(item.workflow.status, TaskBoardWorkflowStatus::Running);
        assert_eq!(
            item.workflow.current_step_id.as_deref(),
            Some("review_pending")
        );
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn blocked_final_without_work_fails_run_and_does_not_advance_board() {
    with_isolated_async_harness_env(|_| async move {
        let (controller, db, tempdir) =
            controller_with_async_session_state(sample_session_state_with_open_task()).await;
        let mut item = TaskBoardItem::new(
            "board-1".into(),
            "Board task".into(),
            "Implement the board task".into(),
            "2026-04-09T10:00:00Z".into(),
        );
        item.status = TaskBoardStatus::InProgress;
        item.session_id = Some(SESSION_ID.into());
        item.work_item_id = Some("task-1".into());
        item.workflow.status = TaskBoardWorkflowStatus::Running;
        item.workflow.current_step_id = Some("worker".into());
        db.create_task_board_item(item)
            .await
            .expect("create board item");

        let agent_id = register_bound_worker(&controller);
        let worktree = tempfile::tempdir().expect("worktree");
        harness_testkit::init_git_repo_with_seed(worktree.path());
        let mut run = codex_run_snapshot(CodexRunStatus::Running);
        run.task_id = Some("task-1".into());
        run.board_item_id = Some("board-1".into());
        run.session_agent_id = Some(agent_id);
        run.project_dir = worktree.path().display().to_string();
        run.final_message =
            Some("Blocked by the execution environment: every command fails before launch.".into());
        record_clean_worktree_baseline(&mut run);
        let (_control, control_rx) = mpsc::unbounded_channel();
        let mut worker = CodexRunWorker::new(controller, run, control_rx);

        worker
            .handle_turn_completed(Some("completed"), None)
            .expect("finish blocked worker");

        assert_eq!(worker.snapshot.status, CodexRunStatus::Failed);
        assert!(
            worker
                .snapshot
                .error
                .as_deref()
                .is_some_and(|error| error.contains("every command fails before launch"))
        );
        let stored = db
            .codex_run("codex-run-1")
            .await
            .expect("load stored run")
            .expect("stored run");
        assert_eq!(stored.status, CodexRunStatus::Failed);
        let session = db
            .resolve_session(SESSION_ID)
            .await
            .expect("load session")
            .expect("session");
        assert_eq!(session.state.tasks["task-1"].status, TaskStatus::Blocked);
        let layout =
            session_storage::layout_from_project_dir(&tempdir.path().join("project"), SESSION_ID)
                .expect("session layout");
        let mirrored = session_storage::load_state(&layout)
            .expect("load mirrored failed session")
            .expect("mirrored failed session");
        assert_eq!(mirrored.tasks["task-1"].status, TaskStatus::Blocked);
        let item = db.task_board_item("board-1").await.expect("board item");
        assert_eq!(item.status, TaskBoardStatus::Failed);
        assert_ne!(item.status, TaskBoardStatus::ToReview);
    })
    .await;
}

#[test]
fn completed_bound_run_skips_when_agent_removed() {
    let (controller, db, _tempdir) =
        controller_with_session_state(sample_session_state_with_open_task());
    let agent_id = register_bound_worker(&controller);
    {
        let db_guard = db.lock().expect("db lock");
        let mut state = db_guard
            .load_session_state_for_mutation(SESSION_ID)
            .expect("load session")
            .expect("session");
        state.agents.remove(&agent_id);
        db_guard
            .save_session_state("project-1", &state)
            .expect("save session without agent");
    }
    let mut run = codex_run_snapshot(CodexRunStatus::Completed);
    run.task_id = Some("task-1".into());
    run.session_agent_id = Some(agent_id);
    run.final_message = Some("Implemented the requested flow.".into());

    controller
        .sync_orchestration_status_for_run(&run)
        .expect("bridge skips removed agent");

    let state = db
        .lock()
        .expect("db lock")
        .load_session_state_for_mutation(SESSION_ID)
        .expect("load session")
        .expect("session");
    assert_eq!(
        state.tasks["task-1"].status,
        TaskStatus::InProgress,
        "task must stay in progress when the bound agent is gone"
    );
}

#[test]
fn failed_bound_run_blocks_task() {
    let (controller, db, _tempdir) =
        controller_with_session_state(sample_session_state_with_open_task());
    let agent_id = register_bound_worker(&controller);
    let mut run = codex_run_snapshot(CodexRunStatus::Failed);
    run.task_id = Some("task-1".into());
    run.session_agent_id = Some(agent_id);
    run.error = Some("transport closed".into());

    controller
        .sync_orchestration_status_for_run(&run)
        .expect("bridge failed run");

    let state = db
        .lock()
        .expect("db lock")
        .load_session_state_for_mutation(SESSION_ID)
        .expect("load session")
        .expect("session");
    let task = state.tasks.get("task-1").expect("bound task");
    assert_eq!(task.status, TaskStatus::Blocked);
    assert_eq!(
        task.blocked_reason.as_deref(),
        Some("Codex run failed: transport closed")
    );
}

#[test]
fn stale_bound_run_blocks_task() {
    let (controller, db, _tempdir) =
        controller_with_session_state(sample_session_state_with_open_task());
    let agent_id = register_bound_worker(&controller);
    let mut run = codex_run_snapshot(CodexRunStatus::Running);
    run.task_id = Some("task-1".into());
    run.session_agent_id = Some(agent_id);

    controller.reconcile_run(run).expect("reconcile stale run");

    let state = db
        .lock()
        .expect("db lock")
        .load_session_state_for_mutation(SESSION_ID)
        .expect("load session")
        .expect("session");
    assert_eq!(state.tasks["task-1"].status, TaskStatus::Blocked);
}
