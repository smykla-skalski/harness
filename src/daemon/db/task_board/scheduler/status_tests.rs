use chrono::{DateTime, Duration, Utc};
use sqlx::{query, query_as, query_scalar};

use super::test_support::{database, seed_run};
use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::policy_graph::PolicyCanvasWorkspace;
use crate::task_board::{
    TaskBoardAutomationAdmissionState, TaskBoardAutomationDesiredMode,
    TaskBoardAutomationEffectiveState, TaskBoardAutomationSchedulingSettings, TaskBoardItem,
    TaskBoardOrchestratorSettings,
};

#[tokio::test]
async fn snapshot_is_consistent_bounded_and_read_only() {
    let db = database().await;
    let now = Utc::now();
    let success_at = now - Duration::minutes(15);
    let failed_at = now - Duration::minutes(10);
    let active_started_at = now - Duration::minutes(2);
    let active_heartbeat_at = now - Duration::minutes(1);
    let backoff_until = now + Duration::minutes(5);
    seed_settings(&db, 7, 60).await;
    seed_control(
        &db,
        "continuous",
        "accepting",
        &timestamp(now - Duration::minutes(5)),
    )
    .await;
    seed_policy_live_revision(&db, 13).await;
    seed_change_revision(&db, 42).await;
    seed_run(
        &db,
        "run-success",
        "terminal",
        Some("completed"),
        Some(success_at),
    )
    .await;
    seed_run(
        &db,
        "run-latest-failed",
        "terminal",
        Some("failed"),
        Some(failed_at),
    )
    .await;
    seed_run(&db, "run-active", "running", None, None).await;
    query(
        "UPDATE task_board_orchestrator_runs
         SET started_at = ?1, heartbeat_at = ?2
         WHERE run_id = 'run-active'",
    )
    .bind(timestamp(active_started_at))
    .bind(timestamp(active_heartbeat_at))
    .execute(db.pool())
    .await
    .expect("set active heartbeat");
    seed_backoff(&db, &timestamp(backoff_until)).await;
    let before = fingerprint(&db).await;

    let snapshot = snapshot(&db).await;
    assert_eq!(snapshot.revision, 42);
    assert_eq!(snapshot.settings_revision, 7);
    assert_eq!(snapshot.policy_revision, 13);
    assert_eq!(
        snapshot.desired_mode,
        TaskBoardAutomationDesiredMode::Continuous
    );
    assert_eq!(
        snapshot.admission_state,
        TaskBoardAutomationAdmissionState::Accepting
    );
    assert_eq!(
        snapshot.effective_state,
        TaskBoardAutomationEffectiveState::Running
    );
    assert_eq!(snapshot.heartbeat_at, timestamp(active_heartbeat_at));
    assert!(matches!(snapshot.heartbeat_age_seconds, Some(59..=65)));
    assert_eq!(
        snapshot.next_run_at.as_deref(),
        Some(timestamp(backoff_until).as_str())
    );
    assert_eq!(snapshot.next_retry_at, None);
    assert_eq!(
        snapshot.last_success_at.as_deref(),
        Some(timestamp(success_at).as_str())
    );
    assert_eq!(snapshot.last_reconciliation_at, None);
    assert_eq!(snapshot.queue, Default::default());
    assert_eq!(
        snapshot.active_run.as_ref().map(|run| run.run_id.as_str()),
        Some("run-active")
    );
    assert_eq!(fingerprint(&db).await, before);
}

#[tokio::test]
async fn provider_backoff_and_open_conflict_follow_lean_precedence() {
    let db = database().await;
    let now = Utc::now();
    seed_settings(&db, 1, 60).await;
    seed_control(
        &db,
        "continuous",
        "accepting",
        &timestamp(now - Duration::minutes(1)),
    )
    .await;
    seed_change_revision(&db, 1).await;
    seed_run(
        &db,
        "run-completed",
        "terminal",
        Some("completed"),
        Some(now - Duration::minutes(1)),
    )
    .await;
    seed_backoff(&db, &timestamp(now + Duration::minutes(10))).await;

    let backing_off = snapshot(&db).await;
    assert_eq!(
        backing_off.effective_state,
        TaskBoardAutomationEffectiveState::BackingOff
    );
    assert_eq!(
        backing_off.blocked_reason.as_deref(),
        Some("provider_backoff")
    );
    seed_backoff_row(
        &db,
        "gitlab",
        "secondary",
        &timestamp(now - Duration::seconds(1)),
    )
    .await;
    let mixed = snapshot(&db).await;
    assert_eq!(
        mixed.effective_state,
        TaskBoardAutomationEffectiveState::BackingOff
    );
    assert_eq!(
        mixed.next_run_at.as_deref(),
        Some(timestamp(now - Duration::seconds(1)).as_str())
    );

    seed_open_conflict(&db).await;
    let degraded = snapshot(&db).await;
    assert_eq!(
        degraded.effective_state,
        TaskBoardAutomationEffectiveState::Degraded
    );
    assert_eq!(
        degraded.blocked_reason.as_deref(),
        Some("open_sync_conflict")
    );

    query("UPDATE task_board_sync_conflicts SET state = 'resolved' WHERE state = 'open'")
        .execute(db.pool())
        .await
        .expect("resolve conflict");
    query(
        "UPDATE task_board_provider_scope_state
         SET backoff_until = ?1",
    )
    .bind(timestamp(now - Duration::seconds(1)))
    .execute(db.pool())
    .await
    .expect("make provider due");
    assert_eq!(
        snapshot(&db).await.effective_state,
        TaskBoardAutomationEffectiveState::Scheduled
    );
}

#[tokio::test]
async fn draining_remains_stopping_with_stale_heartbeat() {
    let db = database().await;
    seed_settings(&db, 1, 1).await;
    seed_control(
        &db,
        "off",
        "draining",
        &timestamp(Utc::now() - Duration::days(1)),
    )
    .await;

    let draining = snapshot(&db).await;
    assert_eq!(
        draining.effective_state,
        TaskBoardAutomationEffectiveState::Stopping
    );
    assert_eq!(
        draining.blocked_reason.as_deref(),
        Some("automation_draining")
    );

    query(
        "UPDATE task_board_orchestrator_control
         SET admission_state = 'stopped' WHERE singleton = 1",
    )
    .execute(db.pool())
    .await
    .expect("finish drain");
    let stopped = snapshot(&db).await;
    assert_eq!(
        stopped.effective_state,
        TaskBoardAutomationEffectiveState::Idle
    );
    assert_eq!(stopped.blocked_reason, None);
}

#[tokio::test]
async fn snapshot_derives_offline_threshold_from_durable_settings() {
    let db = database().await;
    let now = Utc::now();
    seed_settings(&db, 1, 10).await;
    seed_control(
        &db,
        "continuous",
        "accepting",
        &timestamp(now - Duration::seconds(31)),
    )
    .await;

    let offline = snapshot(&db).await;
    assert_eq!(
        offline.effective_state,
        TaskBoardAutomationEffectiveState::Offline
    );
    assert_eq!(offline.settings_revision, 1);

    query("UPDATE task_board_orchestrator_control SET desired_mode = 'step' WHERE singleton = 1")
        .execute(db.pool())
        .await
        .expect("switch to step mode");
    assert_eq!(
        snapshot(&db).await.effective_state,
        TaskBoardAutomationEffectiveState::Idle
    );

    seed_settings(&db, 2, 20).await;
    let current = snapshot(&db).await;
    assert_eq!(
        current.effective_state,
        TaskBoardAutomationEffectiveState::Idle
    );
    assert_eq!(current.settings_revision, 2);

    seed_settings(&db, 3, u64::MAX).await;
    let error = db
        .task_board_automation_snapshot()
        .await
        .expect_err("oversized offline threshold must fail");
    assert!(
        error
            .to_string()
            .contains("offline threshold is out of range")
    );
}

#[tokio::test]
async fn missing_control_fails_without_persisting_defaults() {
    let db = database().await;
    let before_sequence = db.current_change_sequence().await.expect("read sequence");
    let error = db
        .task_board_automation_snapshot()
        .await
        .expect_err("missing control must fail");
    assert!(error.to_string().contains("control is not initialized"));
    assert_eq!(control_count(&db).await, 0);
    assert_eq!(
        db.current_change_sequence()
            .await
            .expect("read stable sequence"),
        before_sequence
    );
}

async fn snapshot(db: &AsyncDaemonDb) -> crate::task_board::TaskBoardAutomationSnapshot {
    db.task_board_automation_snapshot()
        .await
        .expect("build automation snapshot")
}

fn timestamp(value: DateTime<Utc>) -> String {
    value.to_rfc3339()
}

async fn seed_policy_live_revision(db: &AsyncDaemonDb, revision: u64) {
    let mut workspace = PolicyCanvasWorkspace::seeded();
    let canvas = workspace.active_canvas_mut().expect("active policy canvas");
    let mut live = canvas.document.clone();
    live.revision = revision;
    canvas.live_document = Some(live);
    db.replace_policy_workspace(&workspace)
        .await
        .expect("seed active live policy");
}

async fn seed_settings(db: &AsyncDaemonDb, revision: i64, interval_seconds: u64) {
    let mut settings = TaskBoardOrchestratorSettings::default();
    settings.scheduling = TaskBoardAutomationSchedulingSettings {
        reconcile_interval_seconds: interval_seconds,
        ..TaskBoardAutomationSchedulingSettings::default()
    };
    query(
        "INSERT INTO task_board_orchestrator_settings (
            singleton, settings_json, revision, updated_at
         ) VALUES (1, ?1, ?2, '2026-07-15T09:00:00+00:00')
         ON CONFLICT(singleton) DO UPDATE SET
            settings_json = excluded.settings_json,
            revision = excluded.revision,
            updated_at = excluded.updated_at",
    )
    .bind(serde_json::to_string(&settings).expect("serialize settings"))
    .bind(revision)
    .execute(db.pool())
    .await
    .expect("seed settings");
}

async fn seed_control(db: &AsyncDaemonDb, desired: &str, admission: &str, updated_at: &str) {
    query(
        "INSERT INTO task_board_orchestrator_control (
            singleton, desired_mode, admission_state, stop_generation, updated_at
         ) VALUES (1, ?1, ?2, 0, ?3)",
    )
    .bind(desired)
    .bind(admission)
    .bind(updated_at)
    .execute(db.pool())
    .await
    .expect("seed control");
}

async fn seed_change_revision(db: &AsyncDaemonDb, revision: i64) {
    query(
        "INSERT INTO change_tracking (scope, version, updated_at, change_seq)
         VALUES ('task_board:orchestrator', 1, '2026-07-15T09:00:00+00:00', ?1)
         ON CONFLICT(scope) DO UPDATE SET change_seq = excluded.change_seq",
    )
    .bind(revision)
    .execute(db.pool())
    .await
    .expect("seed change revision");
}

async fn seed_backoff(db: &AsyncDaemonDb, deadline: &str) {
    seed_backoff_row(db, "github", "neutral", deadline).await;
}

async fn seed_backoff_row(db: &AsyncDaemonDb, provider: &str, scope_id: &str, deadline: &str) {
    query(
        "INSERT INTO task_board_provider_scope_state (
            provider, scope_id, health, failure_count, backoff_until, updated_at
         ) VALUES (?1, ?2, 'backing_off', 2, ?3,
                   '2026-07-15T10:00:00+00:00')",
    )
    .bind(provider)
    .bind(scope_id)
    .bind(deadline)
    .execute(db.pool())
    .await
    .expect("seed provider backoff");
}

async fn seed_open_conflict(db: &AsyncDaemonDb) {
    db.create_task_board_item(TaskBoardItem::new(
        "item-status".into(),
        "Neutral status item".into(),
        String::new(),
        "2026-07-15T09:00:00+00:00".into(),
    ))
    .await
    .expect("create status item");
    query(
        "INSERT INTO task_board_sync_conflicts (
            conflict_id, item_id, provider, external_ref, field, base_value_json,
            local_value_json, remote_value_json, item_revision, state, detected_at
         ) VALUES ('conflict-status', 'item-status', 'github', 'neutral/1', 'title',
                   'null', 'null', 'null', 1, 'open', '2026-07-15T10:00:00+00:00')",
    )
    .execute(db.pool())
    .await
    .expect("seed open conflict");
}

async fn fingerprint(db: &AsyncDaemonDb) -> (i64, i64, i64, i64, i64, i64, String) {
    query_as(
        "SELECT
            (SELECT COUNT(*) FROM task_board_orchestrator_settings),
            (SELECT COUNT(*) FROM task_board_orchestrator_control),
            (SELECT COUNT(*) FROM task_board_orchestrator_runs),
            (SELECT COUNT(*) FROM task_board_provider_scope_state),
            (SELECT COUNT(*) FROM task_board_sync_conflicts),
            (SELECT change_seq FROM change_tracking WHERE scope = 'task_board:orchestrator'),
            (SELECT updated_at FROM task_board_orchestrator_control WHERE singleton = 1)",
    )
    .fetch_one(db.pool())
    .await
    .expect("load snapshot source fingerprint")
}

async fn control_count(db: &AsyncDaemonDb) -> i64 {
    query_scalar("SELECT COUNT(*) FROM task_board_orchestrator_control")
        .fetch_one(db.pool())
        .await
        .expect("count control rows")
}
