use crate::daemon::db::prelude::*;
use crate::daemon::db::task_board::prelude::*;
use crate::daemon::protocol::{CodexRunMode, CodexRunStatus};
use crate::session::types::TaskStatus;
use crate::task_board::TaskBoardWorkItemState;

use super::admission_recovery::{
    ITEM_ID, SESSION_ID, TASK_ID, WORKER_ID, bound_in_progress_state, ledger_state,
    seed_committed_admission,
};
use super::test_support::{
    codex_run_snapshot, controller_with_async_session_state, with_isolated_async_harness_env,
};

const WORKSPACE_ID: &str = "workspace-legacy-recovery";

#[tokio::test(flavor = "multi_thread")]
async fn legacy_active_worker_recovers_through_its_migrated_workspace_owner() {
    Box::pin(with_isolated_async_harness_env(|_| async move {
        let (controller, db, _tempdir) =
            controller_with_async_session_state(bound_in_progress_state()).await;
        let (intent_id, dispatch) = Box::pin(seed_committed_admission(&db, &["concurrency"])).await;
        seed_selected_legacy_workspace(&db).await;
        let mut run = codex_run_snapshot(CodexRunStatus::Running);
        run.task_id = Some(TASK_ID.into());
        run.board_item_id = Some(ITEM_ID.into());
        run.workflow_execution_id = dispatch.item.workflow.execution_id;
        run.session_agent_id = Some("agent-1".into());
        run.mode = CodexRunMode::WorkspaceWrite;
        run.model = None;
        run.effort = None;
        db.save_codex_run(&run)
            .await
            .expect("persist legacy active worker");

        Box::pin(controller.reconcile_task_board_admission_workers_after_restart())
            .await
            .expect("recover through migrated owner");
        Box::pin(controller.reconcile_task_board_admission_workers_after_restart())
            .await
            .expect("repeat recovery converges");

        let recovered = db
            .codex_run(WORKER_ID)
            .await
            .expect("load recovered run")
            .expect("recovered run");
        assert_eq!(recovered.status, CodexRunStatus::Failed);
        assert_eq!(recovered.session_id, WORKSPACE_ID);
        assert!(recovered.session_agent_id.is_none());
        let progress = db
            .task_board_work_item_progress(ITEM_ID)
            .await
            .expect("load migrated progress")
            .expect("migrated progress");
        assert_eq!(progress.state, TaskBoardWorkItemState::Blocked);
        let item = db
            .task_board_item(ITEM_ID)
            .await
            .expect("load migrated item");
        assert_eq!(item.workspace_id.as_deref(), Some(WORKSPACE_ID));
        let dispatch = db
            .task_board_admission_worker_recoveries()
            .await
            .expect("load settled recoveries");
        assert!(dispatch.is_empty());
        assert_eq!(
            ledger_state(&db, &intent_id, "concurrency").await.0,
            "released"
        );
        let session = db
            .resolve_session(SESSION_ID)
            .await
            .expect("load legacy session")
            .expect("legacy session");
        assert_eq!(session.state.tasks[TASK_ID].status, TaskStatus::InProgress);
    }))
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn legacy_worker_migration_does_not_rebind_a_replacement_execution() {
    Box::pin(with_isolated_async_harness_env(|_| async move {
        let (controller, db, _tempdir) =
            controller_with_async_session_state(bound_in_progress_state()).await;
        let (intent_id, dispatch) = Box::pin(seed_committed_admission(&db, &["concurrency"])).await;
        seed_selected_legacy_workspace(&db).await;
        let mut run = codex_run_snapshot(CodexRunStatus::Running);
        run.task_id = Some(TASK_ID.into());
        run.board_item_id = Some(ITEM_ID.into());
        run.workflow_execution_id = dispatch.item.workflow.execution_id;
        run.session_agent_id = Some("agent-1".into());
        run.mode = CodexRunMode::WorkspaceWrite;
        run.model = None;
        run.effort = None;
        db.save_codex_run(&run)
            .await
            .expect("persist legacy active worker");
        db.update_task_board_item(ITEM_ID, |item| {
            item.work_item_id = Some("replacement-work-item".into());
            item.workflow.execution_id = Some("replacement-execution".into());
            Ok(true)
        })
        .await
        .expect("replace current execution");

        Box::pin(controller.reconcile_task_board_admission_workers_after_restart())
            .await
            .expect("settle historical worker through migrated owner");

        let item = db
            .task_board_item(ITEM_ID)
            .await
            .expect("load replacement item");
        assert_eq!(item.work_item_id.as_deref(), Some("replacement-work-item"));
        assert_eq!(
            item.workflow.execution_id.as_deref(),
            Some("replacement-execution")
        );
        assert!(item.workspace_id.is_none());
        let intent_owner: Option<String> = sqlx::query_scalar(
            "SELECT workspace_id FROM task_board_dispatch_intents WHERE intent_id = ?1",
        )
        .bind(&intent_id)
        .fetch_one(db.pool())
        .await
        .expect("load migrated historical intent");
        assert_eq!(intent_owner.as_deref(), Some(WORKSPACE_ID));
        assert_eq!(
            ledger_state(&db, &intent_id, "concurrency").await.0,
            "released"
        );
    }))
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn restart_refuses_a_runtime_with_the_right_id_and_wrong_execution() {
    Box::pin(with_isolated_async_harness_env(|_| async move {
        let (controller, db, _tempdir) =
            controller_with_async_session_state(bound_in_progress_state()).await;
        let (intent_id, dispatch) = Box::pin(seed_committed_admission(&db, &["concurrency"])).await;
        seed_selected_legacy_workspace(&db).await;
        let mut run = codex_run_snapshot(CodexRunStatus::Running);
        run.task_id = Some(TASK_ID.into());
        run.board_item_id = Some("another-board-item".into());
        run.workflow_execution_id = dispatch.item.workflow.execution_id;
        run.session_agent_id = Some("agent-1".into());
        run.mode = CodexRunMode::WorkspaceWrite;
        run.model = None;
        run.effort = None;
        db.save_codex_run(&run)
            .await
            .expect("persist colliding runtime identity");

        let error = Box::pin(controller.reconcile_task_board_admission_workers_after_restart())
            .await
            .expect_err("mismatched runtime must fail recovery closed");

        assert!(
            error
                .to_string()
                .contains("does not match the reclaimed task")
        );
        let recovered = db
            .codex_run(WORKER_ID)
            .await
            .expect("load rejected runtime")
            .expect("rejected runtime");
        assert_eq!(recovered.session_id, SESSION_ID);
        let members: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM agent_workspace_members WHERE managed_agent_id = ?1",
        )
        .bind(WORKER_ID)
        .fetch_one(db.pool())
        .await
        .expect("count rejected runtime memberships");
        assert_eq!(members, 0);
        assert_eq!(
            ledger_state(&db, &intent_id, "concurrency").await.0,
            "committed"
        );
    }))
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn terminal_snapshot_with_released_admission_replays_progress_after_restart() {
    Box::pin(with_isolated_async_harness_env(|_| async move {
        let (controller, db, _tempdir) =
            controller_with_async_session_state(bound_in_progress_state()).await;
        let (intent_id, dispatch) = Box::pin(seed_committed_admission(&db, &["concurrency"])).await;
        seed_running_progress(&db).await;
        let mut run = codex_run_snapshot(CodexRunStatus::Failed);
        run.task_id = Some(TASK_ID.into());
        run.board_item_id = Some(ITEM_ID.into());
        run.workflow_execution_id = dispatch.item.workflow.execution_id;
        run.session_agent_id = None;
        run.mode = CodexRunMode::WorkspaceWrite;
        run.model = None;
        run.effort = None;
        run.error = Some("worker stopped during restart".into());
        db.save_codex_run(&run)
            .await
            .expect("persist terminal snapshot before projection");
        assert_eq!(
            ledger_state(&db, &intent_id, "concurrency").await.0,
            "released"
        );

        Box::pin(controller.reconcile_task_board_admission_workers_after_restart())
            .await
            .expect("replay terminal progress");

        let progress = db
            .task_board_work_item_progress(ITEM_ID)
            .await
            .expect("load replayed progress")
            .expect("replayed progress");
        assert_eq!(progress.state, TaskBoardWorkItemState::Blocked);
        assert!(
            db.task_board_admission_worker_recoveries()
                .await
                .expect("load settled recoveries")
                .is_empty()
        );
    }))
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn missing_terminal_snapshot_with_released_admission_replays_progress_after_restart() {
    Box::pin(with_isolated_async_harness_env(|_| async move {
        let (controller, db, _tempdir) =
            controller_with_async_session_state(bound_in_progress_state()).await;
        let (intent_id, _) = Box::pin(seed_committed_admission(&db, &["concurrency"])).await;
        seed_running_progress(&db).await;
        assert!(
            db.release_task_board_admission_for_managed_worker(WORKER_ID)
                .await
                .expect("release admission before progress projection")
        );

        Box::pin(controller.reconcile_task_board_admission_workers_after_restart())
            .await
            .expect("recover progress after terminal snapshot loss");

        let progress = db
            .task_board_work_item_progress(ITEM_ID)
            .await
            .expect("load replayed progress")
            .expect("replayed progress");
        assert_eq!(progress.state, TaskBoardWorkItemState::Blocked);
        assert!(
            db.task_board_admission_worker_recoveries()
                .await
                .expect("load settled recoveries")
                .is_empty()
        );
        assert_eq!(
            ledger_state(&db, &intent_id, "concurrency").await.0,
            "released"
        );
    }))
    .await;
}

async fn seed_running_progress(db: &crate::daemon::db_handle::AsyncDaemonDbHandle) {
    sqlx::query(
        "INSERT INTO task_board_work_item_progress (
             item_id, work_item_id, agent_mode, state, attempt_id,
             report_sequence, created_at, updated_at
         ) VALUES (?1, ?2, 'headless', 'running', ?3, 1,
                   '2026-01-01T10:00:00Z', '2026-01-01T10:00:00Z')",
    )
    .bind(ITEM_ID)
    .bind(TASK_ID)
    .bind(WORKER_ID)
    .execute(db.pool())
    .await
    .expect("seed running progress");
}

async fn seed_selected_legacy_workspace(db: &crate::daemon::db_handle::AsyncDaemonDbHandle) {
    sqlx::query(
        "INSERT INTO agent_workspaces (
             workspace_id, daemon_id, project_scope_id, checkout_id, source_project_id,
             project_name, checkout_name, project_dir, repository_root, context_root,
             is_worktree, availability, selected_legacy_session_id,
             manifest_digest, shadow_digest, orchestration_authority, created_at, updated_at
         ) VALUES (?1, 'daemon-test', 'project-1', 'checkout-1', 'project-1',
                   'Project', 'Checkout', '/tmp/project', '/tmp/project', '/tmp/project',
                   0, 'available', ?2, 'manifest', 'shadow', 'legacy_session',
                   '2026-01-01T10:00:00Z', '2026-01-01T10:00:00Z')",
    )
    .bind(WORKSPACE_ID)
    .bind(SESSION_ID)
    .execute(db.pool())
    .await
    .expect("seed migrated workspace");
    sqlx::query(
        "INSERT INTO agent_workspace_legacy_sessions (
             workspace_id, session_id, lifecycle, checkout_availability,
             liveness_evidence, effective_activity_at, session_updated_at,
             session_created_at, source_digest, is_selected
         ) VALUES (?1, ?2, 'active', 'available', 'active runtime',
                   '2026-01-01T10:00:00Z', '2026-01-01T10:00:00Z',
                   '2026-01-01T09:00:00Z', 'source', 1)",
    )
    .bind(WORKSPACE_ID)
    .bind(SESSION_ID)
    .execute(db.pool())
    .await
    .expect("seed legacy workspace provenance");
    sqlx::query(
        "INSERT INTO agent_workspace_teams (
             workspace_id, authority, selected_legacy_session_id, selected_lifecycle,
             source_revision, reconciled_revision, shadow_digest, created_at, updated_at
         ) VALUES (?1, 'workspace', ?2, 'active', 1, 1, 'shadow',
                   '2026-01-01T10:00:00Z', '2026-01-01T10:00:00Z')",
    )
    .bind(WORKSPACE_ID)
    .bind(SESSION_ID)
    .execute(db.pool())
    .await
    .expect("seed migrated workspace team");
}
