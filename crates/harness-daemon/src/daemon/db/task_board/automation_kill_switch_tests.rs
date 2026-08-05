use sqlx::{query, query_as, query_scalar};

use super::*;
use crate::daemon::db::task_board::prelude::{
    ItemCoreQueries, OrchestratorSettingsQueries, PolicyRuntimeQueries, TriageQueries,
};
use crate::daemon::db_open::AsyncDaemonDbConnect;
use crate::daemon::reviews_store::PolicyGraphQueries;
use crate::task_board::policy_graph::PolicyCanvasWorkspace;
use crate::task_board::policy_runtime::models::{
    PolicyRunStatus, PolicyRunSubject, PolicyRunTrigger, PolicyWorkflowRun,
};
use crate::task_board::{
    TaskBoardItem, TaskBoardOrchestratorSettings, TaskBoardStatus, TaskBoardTriageEscalationConfig,
};

async fn database() -> crate::daemon::db_handle::AsyncDaemonDbHandle {
    let temp = tempfile::tempdir().expect("temp dir");
    let path = temp.keep().join("harness.db");
    crate::daemon::db_handle::AsyncDaemonDbHandle(
        AsyncDaemonDb::connect(&path).await.expect("open database"),
    )
}

async fn set_kill_switch(db: &crate::daemon::db_handle::AsyncDaemonDbHandle, enabled: bool) {
    let mut workspace = PolicyCanvasWorkspace::seeded();
    workspace.spawn_kill_switch = enabled;
    db.replace_policy_workspace(&workspace)
        .await
        .expect("persist kill switch");
}

fn triage_item(id: &str) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        id.into(),
        "Needs agent triage".into(),
        String::new(),
        "2026-08-04T08:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Inbox;
    item
}

#[tokio::test]
async fn inactive_switch_produces_no_stop_plan() {
    let db = database().await;
    set_kill_switch(&db, false).await;

    let plan = db
        .automation_kill_switch_stop_plan()
        .await
        .expect("load stop plan");

    assert_eq!(plan, AutomationKillSwitchStopPlan::default());
}

#[tokio::test]
async fn engaged_switch_suspends_automatic_triage_on_ingress() {
    let db = database().await;
    db.set_triage_escalation_config(TaskBoardTriageEscalationConfig {
        enabled: true,
        max_concurrent: 2,
        max_pending: 20,
        timeout_seconds: 180,
    });
    set_kill_switch(&db, true).await;

    let mutation = db
        .create_task_board_item_with_triage(triage_item("suspended"))
        .await
        .expect("create item without triage automation");

    assert_eq!(mutation.item.status, TaskBoardStatus::Inbox);
    assert_eq!(
        query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM task_board_triage_decisions WHERE item_id = 'suspended'",
        )
        .fetch_one(db.pool())
        .await
        .expect("count decisions"),
        0
    );
    assert_eq!(
        query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM task_board_triage_escalations WHERE item_id = 'suspended'",
        )
        .fetch_one(db.pool())
        .await
        .expect("count escalations"),
        0
    );
}

#[tokio::test]
async fn disabled_triage_control_suspends_automatic_triage_on_ingress() {
    let db = database().await;
    db.set_triage_escalation_config(TaskBoardTriageEscalationConfig {
        enabled: true,
        max_concurrent: 2,
        max_pending: 20,
        timeout_seconds: 180,
    });
    let mut settings = TaskBoardOrchestratorSettings::default();
    settings.triage_automation_enabled = false;
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("disable triage automation");

    let mutation = db
        .create_task_board_item_with_triage(triage_item("triage-suspended"))
        .await
        .expect("create item without triage automation");

    assert_eq!(mutation.item.status, TaskBoardStatus::Inbox);
    assert_eq!(
        query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM task_board_triage_decisions
             WHERE item_id = 'triage-suspended'",
        )
        .fetch_one(db.pool())
        .await
        .expect("count decisions"),
        0
    );
    assert_eq!(
        query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM task_board_triage_escalations
             WHERE item_id = 'triage-suspended'",
        )
        .fetch_one(db.pool())
        .await
        .expect("count escalations"),
        0
    );
}

#[tokio::test]
async fn engaged_switch_cancels_running_triage_and_keeps_pending_work_queued() {
    let db = database().await;
    db.set_triage_escalation_config(TaskBoardTriageEscalationConfig {
        enabled: true,
        max_concurrent: 2,
        max_pending: 20,
        timeout_seconds: 180,
    });
    for id in ["running", "pending"] {
        db.create_task_board_item_with_triage(triage_item(id))
            .await
            .expect("seed escalation");
    }
    let claimed = db
        .claim_pending_task_board_triage_escalations(1)
        .await
        .expect("claim one escalation");
    assert_eq!(claimed.len(), 1);
    set_kill_switch(&db, true).await;

    let plan = db
        .automation_kill_switch_stop_plan()
        .await
        .expect("load stop plan");

    assert!(plan.engaged);
    let rows: Vec<(String, String, Option<String>)> = query_as(
        "SELECT escalation_id, status, failure_reason
         FROM task_board_triage_escalations ORDER BY escalation_id",
    )
    .fetch_all(db.pool())
    .await
    .expect("load escalations");
    assert_eq!(rows.len(), 2);
    assert!(rows.contains(&(
        claimed[0].escalation_id.clone(),
        "failed".into(),
        Some(KILL_SWITCH_FAILURE_REASON.into()),
    )));
    assert!(
        rows.iter()
            .any(|(_, status, reason)| status == "pending" && reason.is_none())
    );
}

#[tokio::test]
async fn disabled_triage_control_stops_only_active_triage_workers() {
    let db = database().await;
    db.set_triage_escalation_config(TaskBoardTriageEscalationConfig {
        enabled: true,
        max_concurrent: 2,
        max_pending: 20,
        timeout_seconds: 180,
    });
    db.create_task_board_item_with_triage(triage_item("triage-disabled"))
        .await
        .expect("seed escalation");
    let claimed = db
        .claim_pending_task_board_triage_escalations(1)
        .await
        .expect("claim escalation");
    assert_eq!(claimed.len(), 1);
    query(
        "UPDATE task_board_triage_escalations SET managed_run_id = 'triage-run'
         WHERE escalation_id = ?1",
    )
    .bind(&claimed[0].escalation_id)
    .execute(db.pool())
    .await
    .expect("bind managed run");
    let mut settings = TaskBoardOrchestratorSettings::default();
    settings.triage_automation_enabled = false;
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("disable triage automation");

    let plan = db
        .triage_automation_stop_plan()
        .await
        .expect("load triage stop plan");

    assert!(plan.disabled);
    assert_eq!(plan.codex_run_ids, vec!["triage-run"]);
    assert_eq!(
        query_as::<_, (String, Option<String>)>(
            "SELECT status, failure_reason FROM task_board_triage_escalations
             WHERE escalation_id = ?1",
        )
        .bind(&claimed[0].escalation_id)
        .fetch_one(db.pool())
        .await
        .expect("load escalation"),
        ("failed".into(), Some(TRIAGE_DISABLED_FAILURE_REASON.into()),)
    );
}

#[tokio::test]
async fn disabled_triage_control_retries_a_worker_that_remains_active() {
    let db = database().await;
    db.set_triage_escalation_config(TaskBoardTriageEscalationConfig {
        enabled: true,
        max_concurrent: 2,
        max_pending: 20,
        timeout_seconds: 180,
    });
    db.create_task_board_item_with_triage(triage_item("triage-retry"))
        .await
        .expect("seed escalation");
    let claimed = db
        .claim_pending_task_board_triage_escalations(1)
        .await
        .expect("claim escalation");
    query(
        "UPDATE task_board_triage_escalations SET managed_run_id = 'triage-retry-run'
         WHERE escalation_id = ?1",
    )
    .bind(&claimed[0].escalation_id)
    .execute(db.pool())
    .await
    .expect("bind managed run");
    query(
        "INSERT INTO codex_runs (
            run_id, board_item_id, project_dir, mode, status, prompt,
            pending_approvals_json, resolved_approvals_json, events_json,
            created_at, updated_at
         ) VALUES (
            'triage-retry-run', 'triage-retry', '/tmp', 'report', 'running', 'prompt',
            '[]', '[]', '[]', '2026-08-04T08:00:00Z', '2026-08-04T08:00:00Z'
         )",
    )
    .execute(db.pool())
    .await
    .expect("seed active Codex run");
    let mut settings = TaskBoardOrchestratorSettings::default();
    settings.triage_automation_enabled = false;
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("disable triage automation");

    let first = db
        .triage_automation_stop_plan()
        .await
        .expect("load first stop plan");
    let retry = db
        .triage_automation_stop_plan()
        .await
        .expect("load retry stop plan");

    assert_eq!(first.codex_run_ids, vec!["triage-retry-run"]);
    assert_eq!(retry.codex_run_ids, vec!["triage-retry-run"]);

    query("UPDATE codex_runs SET status = 'completed' WHERE run_id = 'triage-retry-run'")
        .execute(db.pool())
        .await
        .expect("complete Codex run");
    let completed = db
        .triage_automation_stop_plan()
        .await
        .expect("load completed stop plan");

    assert!(completed.codex_run_ids.is_empty());
}

#[tokio::test]
async fn disabled_triage_control_adopts_a_failed_kill_switch_stop() {
    let db = database().await;
    db.set_triage_escalation_config(TaskBoardTriageEscalationConfig {
        enabled: true,
        max_concurrent: 2,
        max_pending: 20,
        timeout_seconds: 180,
    });
    db.create_task_board_item_with_triage(triage_item("kill-switch-handoff"))
        .await
        .expect("seed escalation");
    let claimed = db
        .claim_pending_task_board_triage_escalations(1)
        .await
        .expect("claim escalation");
    query(
        "UPDATE task_board_triage_escalations SET managed_run_id = 'handoff-run'
         WHERE escalation_id = ?1",
    )
    .bind(&claimed[0].escalation_id)
    .execute(db.pool())
    .await
    .expect("bind managed run");
    query(
        "INSERT INTO codex_runs (
            run_id, board_item_id, project_dir, mode, status, prompt,
            pending_approvals_json, resolved_approvals_json, events_json,
            created_at, updated_at
         ) VALUES (
            'handoff-run', 'kill-switch-handoff', '/tmp', 'report', 'running', 'prompt',
            '[]', '[]', '[]', '2026-08-04T08:00:00Z', '2026-08-04T08:00:00Z'
         )",
    )
    .execute(db.pool())
    .await
    .expect("seed active Codex run");
    set_kill_switch(&db, true).await;
    db.automation_kill_switch_stop_plan()
        .await
        .expect("apply kill switch stop plan");
    set_kill_switch(&db, false).await;
    let mut settings = TaskBoardOrchestratorSettings::default();
    settings.triage_automation_enabled = false;
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("disable triage automation");

    let plan = db
        .triage_automation_stop_plan()
        .await
        .expect("adopt kill switch stop");

    assert_eq!(plan.codex_run_ids, vec!["handoff-run"]);
}

#[tokio::test]
async fn stop_plan_finds_every_active_runtime() {
    let db = database().await;
    set_kill_switch(&db, true).await;
    for (run_id, board_item_id, status) in [
        ("active-board", Some("item-1"), "running"),
        ("completed-board", Some("item-1"), "completed"),
        ("active-unbound", None, "running"),
    ] {
        query(
            "INSERT INTO codex_runs (
                run_id, board_item_id, project_dir, mode, status, prompt,
                pending_approvals_json, resolved_approvals_json, events_json,
                created_at, updated_at
             ) VALUES (?1, ?2, '/tmp', 'report', ?3, 'prompt', '[]', '[]', '[]',
                       '2026-08-04T08:00:00Z', '2026-08-04T08:00:00Z')",
        )
        .bind(run_id)
        .bind(board_item_id)
        .bind(status)
        .execute(db.pool())
        .await
        .expect("seed Codex run");
    }

    let plan = db
        .automation_kill_switch_stop_plan()
        .await
        .expect("load stop plan");

    assert_eq!(plan.codex_run_ids, vec!["active-board", "active-unbound"]);
    assert_eq!(
        query_scalar::<_, i64>("SELECT COUNT(*) FROM codex_runs")
            .fetch_one(db.pool())
            .await
            .expect("count Codex rows"),
        3
    );
}

#[tokio::test]
async fn policy_automation_stop_cancels_active_policy_runs() {
    let db = database().await;
    let run = PolicyWorkflowRun::new(
        "reviews_auto",
        PolicyRunSubject::review_pr("owner/repo#1"),
        Some("head-sha".into()),
        PolicyRunTrigger::Manual,
        Vec::new(),
    );
    let run_id = run.run_id.clone();
    db.save_policy_workflow_run(&run)
        .await
        .expect("save active policy run");

    let cancelled = db
        .cancel_active_policy_workflow_runs("automation stopped")
        .await
        .expect("cancel policy automation");

    assert_eq!(cancelled, 1);
    let cancelled = db
        .policy_run_by_id(&run_id)
        .await
        .expect("load policy run")
        .expect("policy run exists");
    assert_eq!(cancelled.status, PolicyRunStatus::Cancelled);
    assert_eq!(
        cancelled.error_message.as_deref(),
        Some("automation stopped")
    );
}
