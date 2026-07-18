use std::collections::HashMap;

use crate::daemon::db::task_board::write_workflow_fixture::{
    approved_write_item, complete_write_preparation,
};
use crate::daemon::db::{AsyncDaemonDb, ReservedTaskBoardDispatch};
use crate::task_board::{
    SpawnGateSwitches, TaskBoardAutomationPolicy, TaskBoardItem, TaskBoardLaunchCapability,
    TaskBoardPolicyLimit, TaskBoardPolicyScope, TaskBoardStatus, build_dispatch_plans_with_policy,
};

use super::admission_dispatch::{configure_policy, preparing_intent, test_db};

#[tokio::test]
async fn compensation_survives_reservation_horizon_and_retry_with_exact_usage() {
    let db = test_db().await;
    configure_policy(&db, finite_policy(1)).await;
    let intent = reserve_item(&db, "compensation-evidence", Some((400, 75_000))).await;
    prepare_dispatch(&db, &intent).await;
    let claim = db
        .claim_task_board_dispatch("compensation-evidence")
        .await
        .expect("claim dispatch")
        .expect("pending dispatch");
    let worker_id = format!("codex-{intent}");

    db.begin_task_board_dispatch_compensation(
        &intent,
        &claim.claim_token,
        &worker_id,
        "worker start outcome requires compensation",
    )
    .await
    .expect("commit compensation evidence before stop");
    age_committed_evidence_and_claim(&db, &intent).await;

    let blocked = db
        .reserve_task_board_dispatch(
            &create_plan(&db, "compensation-capacity", Some((1, 1))).await,
            "control-plane",
            Some("/tmp/project"),
            false,
        )
        .await
        .expect("evaluate capacity while compensation is pending");
    assert!(matches!(blocked, ReservedTaskBoardDispatch::Blocked(_)));
    assert_exact_committed_evidence(&db, &intent, &worker_id).await;

    let retry = db
        .claim_next_task_board_dispatch()
        .await
        .expect("reclaim expired compensation")
        .expect("compensation remains retryable");
    assert_eq!(retry.intent_id, intent);
    db.finalize_task_board_dispatch_compensation(
        &retry.intent_id,
        &retry.claim_token,
        &worker_id,
        "worker start outcome requires compensation",
    )
    .await
    .expect("finalize compensation after stop proof");

    assert_eq!(ledger_state(&db, &intent, "concurrency").await, "released");
    for kind in ["rate", "token_budget", "monetary_budget"] {
        assert_eq!(ledger_state(&db, &intent, kind).await, "committed");
    }
}

#[tokio::test]
async fn refused_pending_intent_releases_capacity_in_the_same_transaction() {
    let db = test_db().await;
    configure_policy(&db, finite_policy(1)).await;
    let intent = reserve_item(&db, "refused-pending", Some((400, 75_000))).await;
    prepare_dispatch(&db, &intent).await;
    db.update_task_board_item("refused-pending", |item| {
        item.status = TaskBoardStatus::Todo;
        Ok(true)
    })
    .await
    .expect("make pending item no longer startable");

    let error = db
        .claim_task_board_dispatch("refused-pending")
        .await
        .expect_err("no-longer-startable dispatch must be refused");
    assert!(error.to_string().contains("changed before worker claim"));
    assert_eq!(intent_status(&db, &intent).await, "failed");
    assert_eq!(active_ledger_rows(&db, &intent).await, 0);

    let next = reserve_item(&db, "refused-capacity-reuse", Some((1, 1))).await;
    assert!(!next.is_empty());
}

#[tokio::test]
async fn claim_to_start_policy_drift_commits_the_blocked_evidence() {
    let db = test_db().await;
    configure_policy(&db, finite_policy(2)).await;
    let first = reserve_item(&db, "start-drift-first", Some((400, 75_000))).await;
    let second = reserve_item(&db, "start-drift-second", Some((400, 75_000))).await;
    prepare_dispatch(&db, &first).await;
    prepare_dispatch(&db, &second).await;
    let first_claim = db
        .claim_task_board_dispatch("start-drift-first")
        .await
        .expect("claim first")
        .expect("first pending dispatch");
    let second_claim = db
        .claim_task_board_dispatch("start-drift-second")
        .await
        .expect("claim second")
        .expect("second pending dispatch");
    db.complete_task_board_dispatch(
        &second,
        &second_claim.claim_token,
        &format!("codex-{second}"),
    )
    .await
    .expect("commit competing worker admission");
    let prior_generation = current_intent_generation(&db, &first).await;
    configure_policy(&db, finite_policy(1)).await;
    let settings_revision = settings_revision(&db).await;

    let error = db
        .validate_task_board_dispatch_admission_start(
            &first,
            &first_claim.claim_token,
            Some(TaskBoardLaunchCapability::WorkspaceWrite),
            None,
        )
        .await
        .expect_err("new policy must block the first worker start");
    assert!(error.to_string().contains("admission deferred"));

    let (decision, intent_id, generation, recorded_revision, blockers): (
        String,
        Option<String>,
        i64,
        i64,
        String,
    ) = sqlx::query_as(
        "SELECT decision, intent_id, generation, settings_revision, blockers_json
         FROM task_board_dispatch_admission_decisions
         WHERE item_id = 'start-drift-first' AND is_current = 1",
    )
    .fetch_one(db.pool())
    .await
    .expect("load persisted blocked decision");
    assert_eq!(decision, "deferred");
    assert!(intent_id.is_none());
    assert!(generation > prior_generation);
    assert_eq!(recorded_revision, settings_revision);
    assert_ne!(blockers, "[]");
    assert_eq!(active_ledger_rows(&db, &first).await, 0);
}

fn finite_policy(concurrency_limit: u64) -> TaskBoardAutomationPolicy {
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
            TaskBoardPolicyLimit::TokenBudget {
                scope: TaskBoardPolicyScope::Global,
                limit: 10_000,
                window_seconds: 3_600,
            },
            TaskBoardPolicyLimit::MonetaryBudget {
                scope: TaskBoardPolicyScope::Global,
                limit_microusd: 1_000_000,
                window_seconds: 3_600,
            },
        ],
        windows: Vec::new(),
    }
}

async fn reserve_item(db: &AsyncDaemonDb, item_id: &str, estimates: Option<(u64, u64)>) -> String {
    preparing_intent(
        db.reserve_task_board_dispatch(
            &create_plan(db, item_id, estimates).await,
            "control-plane",
            Some("/tmp/project"),
            false,
        )
        .await
        .expect("reserve dispatch"),
    )
}

async fn create_plan(
    db: &AsyncDaemonDb,
    item_id: &str,
    estimates: Option<(u64, u64)>,
) -> crate::task_board::DispatchPlan {
    let mut item = approved_write_item(TaskBoardItem::new(
        item_id.to_string(),
        "Admission evidence".to_string(),
        "Body".to_string(),
        "2026-07-17T10:00:00Z".to_string(),
    ));
    if let Some((tokens, cost)) = estimates {
        item.estimated_tokens = Some(tokens);
        item.estimated_cost_microusd = Some(cost);
    }
    db.create_task_board_item(item).await.expect("create item");
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

async fn prepare_dispatch(db: &AsyncDaemonDb, intent_id: &str) {
    let preparation = db
        .claim_task_board_dispatch_preparation(intent_id)
        .await
        .expect("claim preparation")
        .expect("pending preparation");
    complete_write_preparation(db, &preparation, "branch", "/tmp/worktree")
        .await
        .expect("complete preparation");
}

async fn age_committed_evidence_and_claim(db: &AsyncDaemonDb, intent_id: &str) {
    sqlx::query(
        "UPDATE task_board_dispatch_admission_ledger
         SET reserved_at = '2000-01-01T00:00:00Z', committed_at = '2000-01-01T00:00:01Z'
         WHERE intent_id = ?1 AND state = 'committed'",
    )
    .bind(intent_id)
    .execute(db.pool())
    .await
    .expect("age committed admission evidence beyond reservation horizon");
    sqlx::query(
        "UPDATE task_board_dispatch_intents SET claimed_at = '2000-01-01T00:00:00Z'
         WHERE intent_id = ?1",
    )
    .bind(intent_id)
    .execute(db.pool())
    .await
    .expect("age compensation claim for retry");
}

async fn assert_exact_committed_evidence(db: &AsyncDaemonDb, intent_id: &str, worker_id: &str) {
    let rows = sqlx::query_as::<_, (String, i64, String, String, Option<String>)>(
        "SELECT kind, amount, state, managed_worker_id, expires_at
         FROM task_board_dispatch_admission_ledger
         WHERE intent_id = ?1 AND state = 'committed' ORDER BY kind",
    )
    .bind(intent_id)
    .fetch_all(db.pool())
    .await
    .expect("load exact compensation evidence");
    let expected = [
        ("concurrency", 1),
        ("monetary_budget", 75_000),
        ("rate", 1),
        ("token_budget", 400),
    ];
    assert_eq!(rows.len(), expected.len());
    for (row, (kind, amount)) in rows.iter().zip(expected) {
        assert_eq!(row.0, kind);
        assert_eq!(row.1, amount);
        assert_eq!(row.2, "committed");
        assert_eq!(row.3, worker_id);
        assert!(row.4.is_none());
    }
}

async fn ledger_state(db: &AsyncDaemonDb, intent_id: &str, kind: &str) -> String {
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

async fn active_ledger_rows(db: &AsyncDaemonDb, intent_id: &str) -> i64 {
    sqlx::query_scalar(
        "SELECT COUNT(*) FROM task_board_dispatch_admission_ledger
         WHERE intent_id = ?1 AND state IN ('reserved', 'committed')",
    )
    .bind(intent_id)
    .fetch_one(db.pool())
    .await
    .expect("count active ledger rows")
}

async fn intent_status(db: &AsyncDaemonDb, intent_id: &str) -> String {
    sqlx::query_scalar("SELECT status FROM task_board_dispatch_intents WHERE intent_id = ?1")
        .bind(intent_id)
        .fetch_one(db.pool())
        .await
        .expect("load intent status")
}

async fn current_intent_generation(db: &AsyncDaemonDb, intent_id: &str) -> i64 {
    sqlx::query_scalar(
        "SELECT generation FROM task_board_dispatch_admission_decisions
         WHERE intent_id = ?1 AND is_current = 1",
    )
    .bind(intent_id)
    .fetch_one(db.pool())
    .await
    .expect("load current intent generation")
}

async fn settings_revision(db: &AsyncDaemonDb) -> i64 {
    sqlx::query_scalar("SELECT revision FROM task_board_orchestrator_settings WHERE singleton = 1")
        .fetch_one(db.pool())
        .await
        .expect("load settings revision")
}
