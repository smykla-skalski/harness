use std::collections::HashMap;
use std::path::Path;
use std::time::Duration;

use tempfile::TempDir;

use crate::daemon::db::{ClaimedTaskBoardDispatch, ReservedTaskBoardDispatch};
use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::CodexRunStatus;
use crate::task_board::{
    AgentMode, SpawnGateSwitches, TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION, TaskBoardItem,
    TaskBoardReadOnlyRunContext, TaskBoardReadOnlyWorkflowLaunch, TaskBoardWorkflowKind,
    build_dispatch_plans_with_policy, resolve_task_board_reviewers,
};

use super::start_authorization_test_support::StartAuthorizationPause;
use super::test_support::{codex_snapshot, seed_session, test_http_state};
use super::{
    codex_worker_request, managed_worker_id, settle_claimed_task_board_worker,
    start_worker_for_applied_task,
};

#[tokio::test]
async fn managed_read_only_start_rejects_revision_drift_before_codex() {
    let (state, mut claim, _worktree) = claimed_read_only_dispatch().await;
    let db = state.async_db.get().cloned().expect("test async db");
    sqlx::query("UPDATE task_board_items SET revision = revision + 2 WHERE item_id = ?1")
        .bind(&claim.applied.board_item_id)
        .execute(db.pool())
        .await
        .expect("simulate revision drift before managed start");

    let error = settle_claimed_task_board_worker(&state, &db, &mut claim)
        .await
        .expect_err("stale item must not reach Codex start");

    assert!(
        error
            .to_string()
            .contains("launch contract changed before worker start")
    );
    assert_eq!(codex_run_count(&db).await, 0);
    assert_eq!(workflow_execution_count(&db).await, 0);
    assert_eq!(intent_status(&db, &claim.intent_id).await, "failed");
}

#[tokio::test]
async fn absent_worker_rejects_settings_drift_before_codex() {
    let (state, mut claim, _worktree) = claimed_read_only_dispatch().await;
    let db = state.async_db.get().cloned().expect("test async db");
    bump_settings_revision(&db).await;

    let error = settle_claimed_task_board_worker(&state, &db, &mut claim)
        .await
        .expect_err("mutable settings drift must block a new worker");

    assert!(error.to_string().contains("launch contract changed"));
    assert_eq!(codex_run_count(&db).await, 0);
    assert_eq!(workflow_execution_count(&db).await, 0);
    assert_eq!(intent_status(&db, &claim.intent_id).await, "failed");
}

#[tokio::test]
async fn final_start_fence_rejects_post_preflight_settings_drift() {
    assert_post_preflight_drift_is_fenced(FinalStartDrift::SettingsRevision).await;
}

#[tokio::test]
async fn final_start_fence_rejects_post_preflight_kill_switch() {
    assert_post_preflight_drift_is_fenced(FinalStartDrift::SpawnKillSwitch).await;
}

#[derive(Clone, Copy)]
enum FinalStartDrift {
    SettingsRevision,
    SpawnKillSwitch,
}

impl FinalStartDrift {
    const fn expected_error(self) -> &'static str {
        match self {
            Self::SettingsRevision => {
                "read-only workflow configuration revision changed before worker start"
            }
            Self::SpawnKillSwitch => "spawn kill switch engaged; worker start refused",
        }
    }
}

async fn assert_post_preflight_drift_is_fenced(drift: FinalStartDrift) {
    let (state, mut claim, _worktree) = claimed_read_only_dispatch().await;
    let db = state.async_db.get().cloned().expect("test async db");
    let pause = StartAuthorizationPause::new();
    let settlement = pause.scope(settle_claimed_task_board_worker(&state, &db, &mut claim));
    let mutate = async {
        tokio::time::timeout(Duration::from_secs(5), pause.wait_until_reached())
            .await
            .expect("worker start reached final authorization");
        match drift {
            FinalStartDrift::SettingsRevision => bump_settings_revision(&db).await,
            FinalStartDrift::SpawnKillSwitch => engage_spawn_kill_switch(&db).await,
        }
        pause.resume();
    };
    let (result, ()) = tokio::join!(settlement, mutate);
    let error = result.expect_err("post-preflight drift must refuse absent worker start");

    assert!(error.to_string().contains(drift.expected_error()));
    assert_eq!(codex_run_count(&db).await, 0);
    assert_eq!(workflow_execution_count(&db).await, 0);
    assert_eq!(intent_status(&db, &claim.intent_id).await, "failed");
}

#[tokio::test]
async fn exact_worker_is_compensated_after_settings_drift() {
    let (state, mut claim, _worktree) = claimed_read_only_dispatch().await;
    let db = state.async_db.get().cloned().expect("test async db");
    let seeded = seed_exact_read_only_worker(&db, &claim, CodexRunStatus::Running).await;
    bump_settings_revision(&db).await;

    let error = settle_claimed_task_board_worker(&state, &db, &mut claim)
        .await
        .expect_err("configuration drift must compensate the exact worker");

    assert!(
        error
            .to_string()
            .contains("configuration revision changed before worker start")
    );
    assert_eq!(codex_run_count(&db).await, 1);
    assert_eq!(workflow_execution_count(&db).await, 0);
    assert_eq!(intent_status(&db, &claim.intent_id).await, "failed");
    assert!(!intent_compensation_pending(&db, &claim.intent_id).await);
    assert!(
        !db.codex_run(&seeded.run_id)
            .await
            .expect("load compensated exact worker")
            .expect("compensated exact worker")
            .status
            .is_active()
    );
}

#[tokio::test]
async fn recovered_item_drift_persists_compensation_before_stopping_worker() {
    let (state, mut claim, _worktree) = claimed_read_only_dispatch().await;
    let db = state.async_db.get().cloned().expect("test async db");
    let worker = seed_exact_read_only_worker(&db, &claim, CodexRunStatus::Running).await;
    sqlx::query("UPDATE task_board_items SET revision = revision + 2 WHERE item_id = ?1")
        .bind(&claim.applied.board_item_id)
        .execute(db.pool())
        .await
        .expect("simulate revision drift after worker evidence");

    let error = settle_claimed_task_board_worker(&state, &db, &mut claim)
        .await
        .expect_err("stale frozen item must compensate the exact worker");

    assert!(
        error
            .to_string()
            .contains("item revision changed before worker start")
    );
    assert_eq!(workflow_execution_count(&db).await, 0);
    assert_eq!(intent_status(&db, &claim.intent_id).await, "failed");
    assert_eq!(
        intent_compensation_pending(&db, &claim.intent_id).await,
        false
    );
    assert!(
        !db.codex_run(&worker.run_id)
            .await
            .expect("load compensated worker")
            .expect("compensated worker")
            .status
            .is_active()
    );
}

#[tokio::test]
async fn stale_claim_after_probe_keeps_exact_worker_running() {
    let (state, mut stale_claim, _worktree) = claimed_read_only_dispatch().await;
    let db = state.async_db.get().cloned().expect("test async db");
    let worker = seed_exact_read_only_worker(&db, &stale_claim, CodexRunStatus::Running).await;
    start_worker_for_applied_task(
        &state,
        &stale_claim.applied,
        &stale_claim.intent_id,
        &stale_claim.claim_token,
    )
    .await
    .expect("probe exact worker before replacing the claim");
    let probed = db
        .codex_run(&worker.run_id)
        .await
        .expect("load probed worker")
        .expect("probed worker");
    sqlx::query(
        "UPDATE task_board_dispatch_intents SET claimed_at = '2000-01-01T00:00:00Z'
         WHERE intent_id = ?1",
    )
    .bind(&stale_claim.intent_id)
    .execute(db.pool())
    .await
    .expect("expire old dispatch claim");
    let current_claim = db
        .claim_next_task_board_dispatch()
        .await
        .expect("reclaim dispatch")
        .expect("expired dispatch claim");

    let error = settle_claimed_task_board_worker(&state, &db, &mut stale_claim)
        .await
        .expect_err("stale owner must remain fenced after exact probe");

    assert!(error.to_string().contains("lost its claim"));
    assert_eq!(workflow_execution_count(&db).await, 0);
    assert_eq!(
        current_intent_claim(&db, &stale_claim.intent_id).await,
        Some(current_claim.claim_token)
    );
    assert!(!intent_compensation_pending(&db, &stale_claim.intent_id).await);
    let fenced = db
        .codex_run(&worker.run_id)
        .await
        .expect("load fenced worker")
        .expect("fenced worker");
    assert_eq!(fenced.status, probed.status);
    assert_eq!(fenced.updated_at, probed.updated_at);
}

async fn claimed_read_only_dispatch() -> (DaemonHttpState, ClaimedTaskBoardDispatch, TempDir) {
    let state = test_http_state();
    let db = state.async_db.get().cloned().expect("test async db");
    let worktree = tempfile::tempdir().expect("review worktree");
    harness_testkit::init_git_repo_with_seed(worktree.path());
    let exact_head = harness_testkit::git_head_sha(worktree.path(), "HEAD");
    let mut item = TaskBoardItem::new(
        "managed-read-only-revision".into(),
        "Review exact head".into(),
        "Review without workspace writes".into(),
        "2026-07-18T10:00:00Z".into(),
    );
    item.agent_mode = AgentMode::Evaluate;
    item.workflow_kind = TaskBoardWorkflowKind::Review;
    db.create_task_board_item(item.clone())
        .await
        .expect("create read-only item");
    let plan = build_dispatch_plans_with_policy(
        &[item],
        None,
        None,
        SpawnGateSwitches::default(),
        &HashMap::new(),
    )
    .remove(0);
    let intent_id = match db
        .reserve_task_board_dispatch(&plan, "control-plane", Some("/tmp/project"), false)
        .await
        .expect("reserve read-only dispatch")
    {
        ReservedTaskBoardDispatch::Preparing { intent_id, .. } => intent_id,
        other => panic!("unexpected reservation: {other:?}"),
    };
    let preparation = db
        .claim_task_board_dispatch_preparation(&intent_id)
        .await
        .expect("claim preparation")
        .expect("pending preparation");
    let worktree_path = worktree.path().to_string_lossy().into_owned();
    let launch = read_only_launch(
        &db,
        &preparation.preparation.session_id,
        worktree.path(),
        exact_head,
    )
    .await;
    let applied = db
        .complete_task_board_dispatch_preparation_with_workflow(
            &preparation,
            "branch",
            &worktree_path,
            Some(launch),
            None,
        )
        .await
        .expect("publish read-only dispatch");
    let claim = db
        .claim_task_board_dispatch(&applied.board_item_id)
        .await
        .expect("claim read-only dispatch")
        .expect("pending read-only dispatch");
    (state, claim, worktree)
}

async fn read_only_launch(
    db: &crate::daemon::db::AsyncDaemonDb,
    session_id: &str,
    worktree: &Path,
    exact_head_revision: String,
) -> TaskBoardReadOnlyWorkflowLaunch {
    let snapshot = db
        .task_board_item_snapshot("managed-read-only-revision")
        .await
        .expect("source item snapshot");
    let settings = db
        .task_board_orchestrator_settings_snapshot()
        .await
        .expect("settings snapshot");
    TaskBoardReadOnlyWorkflowLaunch {
        workflow_kind: TaskBoardWorkflowKind::Review,
        execution_repository: None,
        configuration_revision: u64::try_from(settings.row_revision).expect("settings revision"),
        policy_version: settings.settings.policy_version,
        resolved_reviewers: resolve_task_board_reviewers(
            &settings.settings.reviewers,
            TaskBoardWorkflowKind::Review,
            None,
        )
        .expect("resolved reviewers"),
        source_item_revision: snapshot.item_revision,
        prepared_item_revision: snapshot.item_revision,
        run_context: TaskBoardReadOnlyRunContext {
            schema_version: TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
            session_id: session_id.into(),
            title: snapshot.item.title,
            body: snapshot.item.body,
            tags: snapshot.item.tags,
            worktree: worktree.to_string_lossy().into_owned(),
        },
        provider_revision: None,
        pull_request: None,
        exact_head_revision,
    }
}

async fn seed_exact_read_only_worker(
    db: &crate::daemon::db::AsyncDaemonDb,
    claim: &ClaimedTaskBoardDispatch,
    status: CodexRunStatus,
) -> crate::daemon::protocol::CodexRunSnapshot {
    seed_session(db, &claim.applied.session_id).await;
    let worker_id = managed_worker_id(&claim.applied, &claim.intent_id);
    let request = codex_worker_request(&claim.applied, &worker_id);
    let launch = claim
        .applied
        .read_only_workflow
        .as_ref()
        .expect("read-only launch");
    let mut snapshot = codex_snapshot(status, &claim.applied.session_id);
    snapshot.run_id = worker_id;
    snapshot.board_item_id = Some(claim.applied.board_item_id.clone());
    snapshot.workflow_execution_id = claim.applied.item.workflow.execution_id.clone();
    snapshot.task_id = None;
    snapshot.session_agent_id = None;
    snapshot.project_dir = launch.run_context.worktree.clone();
    snapshot.mode = request.mode;
    snapshot.prompt = request.prompt;
    snapshot.model = request.model;
    snapshot.effort = request.effort;
    db.save_codex_run(&snapshot)
        .await
        .expect("persist exact read-only worker");
    snapshot
}

async fn bump_settings_revision(db: &crate::daemon::db::AsyncDaemonDb) {
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load current settings");
    settings.dry_run_default = !settings.dry_run_default;
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("bump settings revision");
}

async fn engage_spawn_kill_switch(db: &crate::daemon::db::AsyncDaemonDb) {
    db.update_policy_workspace(|workspace| {
        workspace.spawn_kill_switch = true;
        Ok(())
    })
    .await
    .expect("engage spawn kill switch");
}

async fn codex_run_count(db: &crate::daemon::db::AsyncDaemonDb) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM codex_runs")
        .fetch_one(db.pool())
        .await
        .expect("count Codex runs")
}

async fn workflow_execution_count(db: &crate::daemon::db::AsyncDaemonDb) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM task_board_workflow_executions")
        .fetch_one(db.pool())
        .await
        .expect("count workflow executions")
}

async fn intent_status(db: &crate::daemon::db::AsyncDaemonDb, intent_id: &str) -> String {
    sqlx::query_scalar("SELECT status FROM task_board_dispatch_intents WHERE intent_id = ?1")
        .bind(intent_id)
        .fetch_one(db.pool())
        .await
        .expect("load intent status")
}

async fn intent_compensation_pending(
    db: &crate::daemon::db::AsyncDaemonDb,
    intent_id: &str,
) -> bool {
    sqlx::query_scalar(
        "SELECT compensation_pending FROM task_board_dispatch_intents WHERE intent_id = ?1",
    )
    .bind(intent_id)
    .fetch_one(db.pool())
    .await
    .expect("load intent compensation state")
}

async fn current_intent_claim(
    db: &crate::daemon::db::AsyncDaemonDb,
    intent_id: &str,
) -> Option<String> {
    sqlx::query_scalar("SELECT claim_token FROM task_board_dispatch_intents WHERE intent_id = ?1")
        .bind(intent_id)
        .fetch_one(db.pool())
        .await
        .expect("load current intent claim")
}
