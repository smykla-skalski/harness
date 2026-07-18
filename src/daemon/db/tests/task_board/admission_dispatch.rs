use std::collections::HashMap;
use std::ops::Deref;

use tempfile::{TempDir, tempdir};

#[path = "admission_dispatch_completion_evidence.rs"]
mod completion_evidence_tests;
#[path = "admission_dispatch_completion_fence.rs"]
mod completion_fence_tests;
#[path = "admission_dispatch_estimate_freeze.rs"]
mod estimate_freeze_tests;
#[path = "admission_dispatch_read_only_revision.rs"]
mod read_only_revision_tests;
#[path = "admission_dispatch_startup_reconciliation.rs"]
mod startup_reconciliation_tests;
#[path = "admission_dispatch_write_workflow.rs"]
mod write_workflow_tests;

use crate::daemon::db::{AsyncDaemonDb, DaemonDb, ReservedTaskBoardDispatch, workflow_owner};
use crate::daemon::protocol::CodexRunStatus;
use crate::task_board::{
    AgentMode, DispatchPlan, SpawnGateSwitches, TaskBoardAdmissionDecision,
    TaskBoardAutomationPolicy, TaskBoardItem, TaskBoardPolicyLimit, TaskBoardPolicyScope,
    TaskBoardReadOnlyWorkflowLaunch, TaskBoardWorkflowKind, TaskBoardWriteWorkflowLaunch,
    bind_plan_approval, build_dispatch_plans_with_policy, build_planning_result,
    resolve_task_board_reviewers,
};

#[tokio::test]
async fn admission_reservation_is_all_or_none_and_idempotent() {
    let db = test_db().await;
    configure_policy(&db, admission_policy(1)).await;
    let first = create_plan(&db, "admission-first", AgentMode::Headless).await;
    let second = create_plan(&db, "admission-second", AgentMode::Headless).await;

    let first = db
        .reserve_task_board_dispatch(&first, "control-plane", Some("/tmp/project"), false)
        .await
        .expect("reserve first dispatch");
    let first_intent = preparing_intent(first);
    let repeated = db
        .reserve_task_board_dispatch(
            &create_plan_for_existing(&db, "admission-first").await,
            "control-plane",
            Some("/tmp/project"),
            false,
        )
        .await
        .expect("repeat first dispatch");
    assert_eq!(preparing_intent(repeated), first_intent);
    assert_eq!(ledger_count(&db, "admission-first").await, 2);

    let blocked = db
        .reserve_task_board_dispatch(&second, "control-plane", Some("/tmp/project"), false)
        .await
        .expect("evaluate second dispatch");
    let ReservedTaskBoardDispatch::Blocked(snapshot) = blocked else {
        panic!("second dispatch exceeded concurrency but was not blocked");
    };
    assert_eq!(snapshot.decision, TaskBoardAdmissionDecision::Deferred);
    assert_eq!(ledger_count(&db, "admission-second").await, 0);
    assert_eq!(active_intent_count(&db, "admission-second").await, 0);
}

#[tokio::test]
async fn preparation_renewal_rejects_a_partial_admission_ledger() {
    let db = test_db().await;
    configure_policy(&db, admission_policy(1)).await;
    let plan = create_plan(&db, "admission-partial-renewal", AgentMode::Headless).await;
    let intent = preparing_intent(
        db.reserve_task_board_dispatch(&plan, "control-plane", Some("/tmp/project"), false)
            .await
            .expect("reserve dispatch"),
    );
    let preparation = db
        .claim_task_board_dispatch_preparation(&intent)
        .await
        .expect("claim preparation")
        .expect("pending preparation");
    sqlx::query(
        "DELETE FROM task_board_dispatch_admission_ledger
         WHERE intent_id = ?1 AND kind = 'rate' AND state = 'reserved'",
    )
    .bind(&intent)
    .execute(db.pool())
    .await
    .expect("remove one reserved requirement");

    let error = db
        .renew_task_board_dispatch_preparation(&preparation)
        .await
        .expect_err("partial admission ledger must not renew");

    assert!(
        error
            .to_string()
            .contains("found 1 valid reserved ledger rows, expected 2")
    );
}

#[tokio::test]
async fn configured_admission_rejects_unenforceable_interactive_launch() {
    let db = test_db().await;
    configure_policy(&db, admission_policy(1)).await;
    let plan = create_plan(&db, "admission-interactive", AgentMode::Interactive).await;

    let outcome = db
        .reserve_task_board_dispatch(&plan, "control-plane", Some("/tmp/project"), false)
        .await
        .expect("evaluate interactive dispatch");
    let ReservedTaskBoardDispatch::Blocked(snapshot) = outcome else {
        panic!("configured interactive dispatch was not rejected");
    };
    assert_eq!(snapshot.decision, TaskBoardAdmissionDecision::Rejected);
    assert_eq!(active_intent_count(&db, "admission-interactive").await, 0);
}

#[tokio::test]
async fn default_empty_admission_rejects_unenforceable_interactive_launch() {
    let db = test_db().await;
    let plan = create_plan(&db, "admission-interactive-empty", AgentMode::Interactive).await;

    let outcome = db
        .reserve_task_board_dispatch(&plan, "control-plane", Some("/tmp/project"), false)
        .await
        .expect("evaluate interactive dispatch");
    let ReservedTaskBoardDispatch::Blocked(snapshot) = outcome else {
        panic!("default-empty policy allowed an unenforceable interactive dispatch");
    };
    assert_eq!(snapshot.decision, TaskBoardAdmissionDecision::Rejected);
    assert_eq!(
        active_intent_count(&db, "admission-interactive-empty").await,
        0
    );
}

#[tokio::test]
async fn terminal_item_cancels_unclaimed_dispatch_but_rejects_a_claimed_one() {
    let db = test_db().await;
    configure_policy(&db, admission_policy(1)).await;
    let plan = create_plan(&db, "admission-terminal", AgentMode::Headless).await;
    let first_intent = preparing_intent(
        db.reserve_task_board_dispatch(&plan, "control-plane", Some("/tmp/project"), false)
            .await
            .expect("reserve first dispatch"),
    );

    db.update_task_board_item("admission-terminal", |item| {
        item.status = crate::task_board::TaskBoardStatus::Done;
        Ok(true)
    })
    .await
    .expect("terminal mutation cancels an unclaimed dispatch");
    assert_eq!(active_intent_count(&db, "admission-terminal").await, 0);

    db.update_task_board_item("admission-terminal", |item| {
        item.status = crate::task_board::TaskBoardStatus::Todo;
        Ok(true)
    })
    .await
    .expect("reopen item");
    let second_intent = preparing_intent(
        db.reserve_task_board_dispatch(
            &create_plan_for_existing(&db, "admission-terminal").await,
            "control-plane",
            Some("/tmp/project"),
            false,
        )
        .await
        .expect("reserve fresh dispatch"),
    );
    assert_ne!(first_intent, second_intent);
    db.claim_task_board_dispatch_preparation(&second_intent)
        .await
        .expect("claim preparation")
        .expect("pending preparation");

    let error = db
        .delete_task_board_item("admission-terminal")
        .await
        .expect_err("claimed preparation must fence deletion");
    assert!(error.to_string().contains("dispatch is claimed"));
    assert_eq!(active_intent_count(&db, "admission-terminal").await, 1);
}

#[tokio::test]
async fn terminal_run_before_dispatch_commit_releases_only_concurrency() {
    let db = test_db().await;
    configure_policy(&db, admission_policy(1)).await;
    let plan = create_plan(&db, "admission-fast-terminal", AgentMode::Headless).await;
    let intent = preparing_intent(
        db.reserve_task_board_dispatch(&plan, "control-plane", Some("/tmp/project"), false)
            .await
            .expect("reserve dispatch"),
    );
    let preparation = db
        .claim_task_board_dispatch_preparation(&intent)
        .await
        .expect("claim preparation")
        .expect("pending preparation");
    db.complete_task_board_dispatch_preparation(&preparation, "branch", "/tmp/worktree")
        .await
        .expect("complete preparation");
    let claim = db
        .claim_task_board_dispatch("admission-fast-terminal")
        .await
        .expect("claim dispatch")
        .expect("pending dispatch");
    let worker_id = "codex-admission-fast-terminal";
    let mut run = super::super::sample_codex_run(worker_id, "2026-07-17T10:00:00Z");
    run.status = CodexRunStatus::Completed;
    db.save_codex_run(&run).await.expect("save terminal run");

    db.complete_task_board_dispatch(&intent, &claim.claim_token, worker_id)
        .await
        .expect("commit terminal launch evidence");

    assert_eq!(
        ledger_kind_state(&db, &intent, "concurrency").await,
        "released"
    );
    assert_eq!(ledger_kind_state(&db, &intent, "rate").await, "committed");
}

pub(super) struct TestDb {
    db: AsyncDaemonDb,
    _directory: TempDir,
}

impl Deref for TestDb {
    type Target = AsyncDaemonDb;

    fn deref(&self) -> &Self::Target {
        &self.db
    }
}

impl TestDb {
    pub(super) async fn reopen(&self) -> AsyncDaemonDb {
        AsyncDaemonDb::connect(&self._directory.path().join("harness.db"))
            .await
            .expect("reopen test db")
    }
}

pub(super) async fn test_db() -> TestDb {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let sync_db = DaemonDb::open(&path).expect("open sync db");
    let project = super::super::sample_project();
    sync_db.sync_project(&project).expect("sync project");
    let session = super::super::sample_session_state();
    sync_db
        .sync_session(&project.project_id, &session)
        .expect("sync session");
    drop(sync_db);
    let db = AsyncDaemonDb::connect(&path).await.expect("open db");
    TestDb {
        db,
        _directory: directory,
    }
}

pub(super) fn admission_policy(concurrency_limit: u64) -> TaskBoardAutomationPolicy {
    TaskBoardAutomationPolicy {
        limits: vec![
            TaskBoardPolicyLimit::Concurrency {
                scope: TaskBoardPolicyScope::Global,
                limit: concurrency_limit,
                reservation: 1,
            },
            TaskBoardPolicyLimit::Rate {
                scope: TaskBoardPolicyScope::Global,
                limit: 100,
                window_seconds: 3_600,
                reservation: 1,
            },
        ],
        windows: Vec::new(),
    }
}

pub(super) async fn configure_policy(db: &AsyncDaemonDb, policy: TaskBoardAutomationPolicy) {
    let mut settings = db
        .task_board_orchestrator_settings()
        .await
        .expect("load settings");
    settings.admission_policy = policy;
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("save settings");
}

async fn create_plan(db: &AsyncDaemonDb, item_id: &str, mode: AgentMode) -> DispatchPlan {
    let mut item = TaskBoardItem::new(
        item_id.to_string(),
        "Admission dispatch".to_string(),
        "Body".to_string(),
        "2026-07-17T10:00:00Z".to_string(),
    );
    item.agent_mode = mode;
    db.create_task_board_item(item).await.expect("create item");
    create_plan_for_existing(db, item_id).await
}

async fn create_plan_for_existing(db: &AsyncDaemonDb, item_id: &str) -> DispatchPlan {
    let item = db.task_board_item(item_id).await.expect("load item");
    build_dispatch_plans_with_policy(
        &[item],
        None,
        None,
        SpawnGateSwitches::default(),
        &HashMap::new(),
    )
    .remove(0)
}

pub(super) fn preparing_intent(outcome: ReservedTaskBoardDispatch) -> String {
    match outcome {
        ReservedTaskBoardDispatch::Preparing { intent_id, .. } => intent_id,
        ReservedTaskBoardDispatch::Applied(_) => panic!("new reservation was already applied"),
        ReservedTaskBoardDispatch::Blocked(_) => panic!("reservation was unexpectedly blocked"),
    }
}

async fn ledger_count(db: &AsyncDaemonDb, item_id: &str) -> i64 {
    sqlx::query_scalar(
        "SELECT COUNT(*) FROM task_board_dispatch_admission_ledger WHERE item_id = ?1",
    )
    .bind(item_id)
    .fetch_one(db.pool())
    .await
    .expect("count ledger")
}

async fn active_intent_count(db: &AsyncDaemonDb, item_id: &str) -> i64 {
    sqlx::query_scalar(
        "SELECT COUNT(*) FROM task_board_dispatch_intents
         WHERE item_id = ?1 AND status IN ('preparing', 'preparing_claimed', 'held', 'pending', 'starting')",
    )
    .bind(item_id)
    .fetch_one(db.pool())
    .await
    .expect("count active intents")
}

async fn current_generation(db: &AsyncDaemonDb, intent_id: &str) -> i64 {
    sqlx::query_scalar(
        "SELECT generation FROM task_board_dispatch_admission_decisions
         WHERE intent_id = ?1 AND is_current = 1",
    )
    .bind(intent_id)
    .fetch_one(db.pool())
    .await
    .expect("load generation")
}

async fn ledger_state_count(db: &AsyncDaemonDb, intent_id: &str, state: &str) -> i64 {
    sqlx::query_scalar(
        "SELECT COUNT(*) FROM task_board_dispatch_admission_ledger
         WHERE intent_id = ?1 AND state = ?2",
    )
    .bind(intent_id)
    .bind(state)
    .fetch_one(db.pool())
    .await
    .expect("count ledger state")
}

pub(super) async fn ledger_kind_state(db: &AsyncDaemonDb, intent_id: &str, kind: &str) -> String {
    sqlx::query_scalar(
        "SELECT state FROM task_board_dispatch_admission_ledger
         WHERE intent_id = ?1 AND kind = ?2 ORDER BY generation DESC LIMIT 1",
    )
    .bind(intent_id)
    .bind(kind)
    .fetch_one(db.pool())
    .await
    .expect("load ledger state")
}
