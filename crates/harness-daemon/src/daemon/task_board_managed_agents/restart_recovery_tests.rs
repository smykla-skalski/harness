use crate::daemon::db::task_board::prelude::*;
use crate::task_board::{AgentMode, TaskBoardWorkItemState};
use harness_daemon_managed_agents::{AgentTuiStatus, AsyncAgentTuiStorage};

use super::managed_worker_id;
use super::restart_recovery::reconcile_interactive_workers_after_restart;
use super::test_support::{
    applied_task, seed_owner_session, seed_workspace_owner, terminal_snapshot, test_http_state,
    test_http_state_with_sandboxed,
};

const INTENT_ID: &str = "dispatch-interactive-restart";
const WORKSPACE_ID: &str = "workspace-interactive-restart";
const WORKING_COPY_ID: &str = "working-copy-interactive-restart";

#[tokio::test]
async fn restart_recovers_interactive_worker_once_without_a_session() {
    let state = test_http_state();
    let db = state.async_db.get().cloned().expect("test async db");
    let mut applied = applied_task(AgentMode::Interactive);
    applied.session_id = None;
    applied.workspace_id = Some(WORKSPACE_ID.into());
    applied.working_copy_id = Some(WORKING_COPY_ID.into());
    applied.item.session_id = None;
    applied.item.workspace_id = applied.workspace_id.clone();
    applied.item.working_copy_id = applied.working_copy_id.clone();
    applied.item.work_item_id = Some(applied.work_item_id.clone());
    let worker_id = managed_worker_id(&applied, INTENT_ID);
    seed_workspace(&db).await;
    seed_dispatch(&db, &applied, &worker_id).await;
    let mut snapshot = terminal_snapshot(AgentTuiStatus::Running, WORKSPACE_ID);
    snapshot.tui_id.clone_from(&worker_id);
    snapshot.session_id = WORKSPACE_ID.into();
    snapshot.workspace_id = Some(WORKSPACE_ID.into());
    snapshot.agent_id.clear();
    db.save_agent_tui(&snapshot)
        .await
        .expect("persist interrupted interactive runtime");

    reconcile_interactive_workers_after_restart(&state)
        .await
        .expect("recover interactive worker");
    reconcile_interactive_workers_after_restart(&state)
        .await
        .expect("repeat recovery converges");

    let recovered = db
        .agent_tui(&worker_id)
        .await
        .expect("load recovered runtime")
        .expect("recovered runtime");
    assert_eq!(recovered.status, AgentTuiStatus::Exited);
    let progress = db
        .task_board_work_item_progress(&applied.board_item_id)
        .await
        .expect("load recovered progress")
        .expect("recovered progress");
    assert_eq!(progress.state, TaskBoardWorkItemState::Blocked);
    let ledger: String = sqlx::query_scalar(
        "SELECT state FROM task_board_dispatch_admission_ledger
         WHERE ledger_id = 'ledger-interactive-restart'",
    )
    .fetch_one(db.pool())
    .await
    .expect("load recovered admission");
    assert_eq!(ledger, "released");
    let members: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM agent_workspace_members
         WHERE workspace_id = ?1 AND managed_agent_id = ?2",
    )
    .bind(WORKSPACE_ID)
    .bind(&worker_id)
    .fetch_one(db.pool())
    .await
    .expect("count recovered members");
    assert_eq!(members, 1);
}

#[tokio::test]
async fn restart_defers_a_live_interactive_worker_until_the_bridge_returns() {
    let daemon_root = tempfile::tempdir().expect("daemon root");
    let host_home = tempfile::tempdir().expect("host home");
    Box::pin(temp_env::async_with_vars(
        [
            ("HARNESS_DAEMON_DATA_HOME", daemon_root.path().to_str()),
            ("HARNESS_APP_GROUP_ID", None),
            ("XDG_DATA_HOME", None),
            ("HARNESS_HOST_HOME", host_home.path().to_str()),
            ("HOME", host_home.path().to_str()),
        ],
        async {
            let state = test_http_state_with_sandboxed(true);
            let db = state.async_db.get().cloned().expect("test async db");
            let mut applied = applied_task(AgentMode::Interactive);
            applied.session_id = None;
            applied.workspace_id = Some(WORKSPACE_ID.into());
            applied.working_copy_id = Some(WORKING_COPY_ID.into());
            applied.item.session_id = None;
            applied.item.workspace_id = applied.workspace_id.clone();
            applied.item.working_copy_id = applied.working_copy_id.clone();
            applied.item.work_item_id = Some(applied.work_item_id.clone());
            let worker_id = managed_worker_id(&applied, INTENT_ID);
            seed_workspace(&db).await;
            seed_dispatch(&db, &applied, &worker_id).await;
            let mut snapshot = terminal_snapshot(AgentTuiStatus::Running, WORKSPACE_ID);
            snapshot.tui_id.clone_from(&worker_id);
            snapshot.workspace_id = Some(WORKSPACE_ID.into());
            snapshot.agent_id.clear();
            db.save_agent_tui(&snapshot)
                .await
                .expect("persist bridge-hosted runtime");

            reconcile_interactive_workers_after_restart(&state)
                .await
                .expect("defer recovery until the bridge returns");

            tokio::time::sleep(std::time::Duration::from_millis(300)).await;

            assert!(
                state
                    .agent_tui_manager
                    .is_tui_active(&worker_id)
                    .expect("load recovered active state")
            );
            let recovered = db
                .agent_tui(&worker_id)
                .await
                .expect("load deferred runtime")
                .expect("deferred runtime");
            assert_eq!(recovered.status, AgentTuiStatus::Running);
            let ledger: String = sqlx::query_scalar(
                "SELECT state FROM task_board_dispatch_admission_ledger
                 WHERE ledger_id = 'ledger-interactive-restart'",
            )
            .fetch_one(db.pool())
            .await
            .expect("load deferred admission");
            assert_eq!(ledger, "committed");
            let _ = state
                .agent_tui_manager
                .remove_active(&worker_id)
                .expect("stop deferred refresh");
        },
    ))
    .await;
}

#[tokio::test]
async fn restart_defers_a_session_owned_worker_until_the_bridge_returns() {
    let daemon_root = tempfile::tempdir().expect("daemon root");
    let host_home = tempfile::tempdir().expect("host home");
    Box::pin(temp_env::async_with_vars(
        [
            ("HARNESS_DAEMON_DATA_HOME", daemon_root.path().to_str()),
            ("HARNESS_APP_GROUP_ID", None),
            ("XDG_DATA_HOME", None),
            ("HARNESS_HOST_HOME", host_home.path().to_str()),
            ("HOME", host_home.path().to_str()),
        ],
        async {
            let state = test_http_state_with_sandboxed(true);
            let db = state.async_db.get().cloned().expect("test async db");
            let mut applied = applied_task(AgentMode::Interactive);
            applied.item.session_id.clone_from(&applied.session_id);
            applied.item.work_item_id = Some(applied.work_item_id.clone());
            let worker_id = managed_worker_id(&applied, INTENT_ID);
            seed_owner_session(&db, &applied).await;
            seed_dispatch(&db, &applied, &worker_id).await;
            let mut snapshot = terminal_snapshot(AgentTuiStatus::Running, "session-1");
            snapshot.tui_id.clone_from(&worker_id);
            db.save_agent_tui(&snapshot)
                .await
                .expect("persist bridge-hosted runtime");

            reconcile_interactive_workers_after_restart(&state)
                .await
                .expect("defer Session-owned recovery until the bridge returns");

            tokio::time::sleep(std::time::Duration::from_millis(300)).await;

            assert!(
                state
                    .agent_tui_manager
                    .is_tui_active(&worker_id)
                    .expect("load recovered active state")
            );
            let recovered = db
                .agent_tui(&worker_id)
                .await
                .expect("load deferred runtime")
                .expect("deferred runtime");
            assert_eq!(recovered.status, AgentTuiStatus::Running);
            assert_eq!(recovered.session_id, "session-1");
            assert!(recovered.workspace_id.is_none());
            let ledger: String = sqlx::query_scalar(
                "SELECT state FROM task_board_dispatch_admission_ledger
                 WHERE ledger_id = 'ledger-interactive-restart'",
            )
            .fetch_one(db.pool())
            .await
            .expect("load deferred admission");
            assert_eq!(ledger, "committed");
            let _ = state
                .agent_tui_manager
                .remove_active(&worker_id)
                .expect("stop deferred refresh");
        },
    ))
    .await;
}

async fn seed_workspace(db: &crate::daemon::db_handle::AsyncDaemonDbHandle) {
    seed_workspace_owner(db, WORKSPACE_ID).await;
    sqlx::query(
        "INSERT INTO agent_working_copies (
             working_copy_id, workspace_id, origin_path, project_name, worktree_path,
             branch_ref, status, created_at, updated_at
         ) VALUES (?1, ?2, '/tmp/project', 'Project', '/tmp/project-copy',
                   'branch', 'active', 'created', 'updated')",
    )
    .bind(WORKING_COPY_ID)
    .bind(WORKSPACE_ID)
    .execute(db.pool())
    .await
    .expect("seed working copy");
}

async fn seed_dispatch(
    db: &crate::daemon::db_handle::AsyncDaemonDbHandle,
    applied: &crate::task_board::DispatchAppliedTask,
    worker_id: &str,
) {
    db.create_task_board_item(applied.item.clone())
        .await
        .expect("seed board item");
    let payload = serde_json::to_string(applied).expect("serialize applied dispatch");
    sqlx::query(
        "INSERT INTO task_board_dispatch_intents (
             intent_id, item_id, session_id, workspace_id, working_copy_id, work_item_id,
             workflow_execution_id, payload_json, status, available_at,
             created_at, updated_at, completed_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'completed',
                   'available', 'created', 'updated', 'completed')",
    )
    .bind(INTENT_ID)
    .bind(&applied.board_item_id)
    .bind(applied.session_id.as_deref())
    .bind(applied.workspace_id.as_deref())
    .bind(applied.working_copy_id.as_deref())
    .bind(&applied.work_item_id)
    .bind(
        applied
            .item
            .workflow
            .execution_id
            .as_deref()
            .expect("execution"),
    )
    .bind(payload)
    .execute(db.pool())
    .await
    .expect("seed completed dispatch");
    seed_progress_and_admission(db, applied, worker_id).await;
}

async fn seed_progress_and_admission(
    db: &crate::daemon::db_handle::AsyncDaemonDbHandle,
    applied: &crate::task_board::DispatchAppliedTask,
    worker_id: &str,
) {
    sqlx::query(
        "INSERT INTO task_board_work_item_progress (
             item_id, work_item_id, agent_mode, state, attempt_id,
             report_sequence, created_at, updated_at
         ) VALUES (?1, ?2, 'interactive', 'pending', ?3, 0, 'created', 'updated')",
    )
    .bind(&applied.board_item_id)
    .bind(&applied.work_item_id)
    .bind(worker_id)
    .execute(db.pool())
    .await
    .expect("seed pending progress");
    sqlx::query(
        "INSERT INTO task_board_dispatch_admission_decisions (
             decision_id, intent_id, generation, item_id, item_revision, settings_revision,
             decision, policy_json, context_json, requirements_json, blockers_json,
             launch_profile, evaluated_at, is_current, created_at
         ) VALUES ('decision-interactive-restart', ?1, 1, ?2, 1, 1,
                   'allowed', '{}', '{}', '[]', '[]', 'workspace_write',
                   '2026-01-01T10:00:00Z', 1, '2026-01-01T10:00:00Z')",
    )
    .bind(INTENT_ID)
    .bind(&applied.board_item_id)
    .execute(db.pool())
    .await
    .expect("seed admission decision");
    sqlx::query(
        "INSERT INTO task_board_dispatch_admission_ledger (
             ledger_id, decision_id, decision, intent_id, generation, item_id,
             canonical_key, kind, scope, amount, limit_value, state,
             managed_worker_id, reserved_at, committed_at
         ) VALUES ('ledger-interactive-restart', 'decision-interactive-restart',
                   'allowed', ?1, 1, ?2, 'concurrency:global', 'concurrency',
                   'global', 1, 1, 'committed', ?3,
                   '2026-01-01T10:00:00Z', '2026-01-01T10:00:01Z')",
    )
    .bind(INTENT_ID)
    .bind(&applied.board_item_id)
    .bind(worker_id)
    .execute(db.pool())
    .await
    .expect("seed committed admission");
}
