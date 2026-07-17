use chrono::{DateTime, Duration, Utc};
use sqlx::{Acquire, query, query_scalar};

use super::status::{
    begin_snapshot_observation, snapshot_after_observation, snapshot_in_transaction,
};
use super::test_support::{database, instant};
use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::policy_graph::{PolicyCanvasWorkspace, PolicyGraphMode};

#[tokio::test]
async fn lean_policy_revision_matches_active_live_policy_semantics() {
    let db = ready_database().await;
    let mut workspace = PolicyCanvasWorkspace::seeded();
    assert_policy_revision(&db, &workspace).await;

    let canvas = workspace.active_canvas_mut().expect("active canvas");
    let mut live = canvas.document.clone();
    live.revision = 17;
    canvas.live_document = Some(live);
    assert_policy_revision(&db, &workspace).await;

    workspace.global_policy_enforcement_enabled = false;
    assert_policy_revision(&db, &workspace).await;

    workspace.global_policy_enforcement_enabled = true;
    let canvas = workspace.active_canvas_mut().expect("active canvas");
    canvas.live_document = None;
    canvas.document.mode = PolicyGraphMode::Enforced;
    canvas.document.revision = 29;
    assert_policy_revision(&db, &workspace).await;
}

#[tokio::test]
async fn policy_revision_uses_the_pinned_read_snapshot() {
    let db = ready_database().await;
    let mut workspace = PolicyCanvasWorkspace::seeded();
    let canvas = workspace.active_canvas_mut().expect("active canvas");
    let mut live = canvas.document.clone();
    live.revision = 17;
    canvas.live_document = Some(live);
    db.replace_policy_workspace(&workspace)
        .await
        .expect("seed live policy");

    let mut transaction = db.pool().begin().await.expect("begin read transaction");
    query_scalar::<_, i64>(
        "SELECT revision FROM task_board_orchestrator_settings WHERE singleton = 1",
    )
    .fetch_one(transaction.as_mut())
    .await
    .expect("pin read snapshot");
    set_live_policy_revision(&db, 29).await;

    let pinned = snapshot_in_transaction(&mut transaction)
        .await
        .expect("read pinned snapshot");
    assert_eq!(pinned.policy_revision, 17);
    transaction.commit().await.expect("commit read transaction");
    assert_eq!(snapshot(&db).await.policy_revision, 29);
}

#[tokio::test]
async fn observation_follows_a_heartbeat_committed_after_deferred_begin() {
    let db = ready_database().await;
    let mut transaction = db.pool().begin().await.expect("begin deferred read");
    let pre_read_clock = Utc::now() - Duration::seconds(1);
    let heartbeat = Utc::now();
    let heartbeat_raw = heartbeat.to_rfc3339();
    query("UPDATE task_board_orchestrator_control SET updated_at = ?1 WHERE singleton = 1")
        .bind(&heartbeat_raw)
        .execute(db.pool())
        .await
        .expect("commit newer heartbeat");

    let current = snapshot_in_transaction(&mut transaction)
        .await
        .expect("snapshot after concurrent heartbeat");
    let observed_at = instant(&current.observed_at);
    assert!(heartbeat > pre_read_clock);
    assert!(observed_at >= heartbeat);
    assert_eq!(current.heartbeat_at, heartbeat_raw);
    assert!(matches!(current.heartbeat_age_seconds, Some(0..=5)));
    transaction.commit().await.expect("commit read transaction");
}

#[tokio::test]
async fn observation_is_pinned_before_later_heartbeat_commits() {
    let db = ready_database().await;
    let mut transaction = db.pool().begin().await.expect("begin deferred read");
    let (policy_revision, observed_at) = begin_snapshot_observation(transaction.as_mut())
        .await
        .expect("pin snapshot observation");
    let later_heartbeat = wait_until_after(observed_at).await;
    let later_heartbeat_raw = later_heartbeat.to_rfc3339();
    query("UPDATE task_board_orchestrator_control SET updated_at = ?1 WHERE singleton = 1")
        .bind(&later_heartbeat_raw)
        .execute(db.pool())
        .await
        .expect("commit heartbeat after observation");

    let pinned = snapshot_after_observation(&mut transaction, policy_revision, observed_at)
        .await
        .expect("build pinned snapshot");
    assert_eq!(instant(&pinned.observed_at), observed_at);
    assert_ne!(pinned.heartbeat_at, later_heartbeat_raw);
    transaction.commit().await.expect("commit read transaction");
    assert_eq!(snapshot(&db).await.heartbeat_at, later_heartbeat_raw);
}

#[tokio::test]
async fn snapshot_ledger_read_succeeds_on_a_query_only_connection() {
    let db = ready_database().await;
    let mut connection = db.pool().acquire().await.expect("acquire connection");
    query("PRAGMA query_only = ON")
        .execute(&mut *connection)
        .await
        .expect("enable query-only mode");
    let mut transaction = connection.begin().await.expect("begin query-only read");

    snapshot_in_transaction(&mut transaction)
        .await
        .expect("read query-only snapshot");
    transaction.commit().await.expect("commit query-only read");
    query("PRAGMA query_only = OFF")
        .execute(&mut *connection)
        .await
        .expect("disable query-only mode");
}

async fn ready_database() -> AsyncDaemonDb {
    let db = database().await;
    let settings =
        serde_json::to_string(&crate::task_board::TaskBoardOrchestratorSettings::default())
            .expect("serialize settings");
    query(
        "INSERT INTO task_board_orchestrator_settings
            (singleton, settings_json, revision, updated_at)
         VALUES (1, ?1, 1, ?2)",
    )
    .bind(settings)
    .bind(timestamp(Utc::now()))
    .execute(db.pool())
    .await
    .expect("seed settings");
    query(
        "INSERT INTO task_board_orchestrator_control
            (singleton, desired_mode, admission_state, stop_generation, updated_at)
         VALUES (1, 'continuous', 'accepting', 0, ?1)",
    )
    .bind(timestamp(Utc::now()))
    .execute(db.pool())
    .await
    .expect("seed control");
    db
}

async fn assert_policy_revision(db: &AsyncDaemonDb, workspace: &PolicyCanvasWorkspace) {
    let expected = workspace
        .active_live_document()
        .map_or(0, |document| document.revision);
    db.replace_policy_workspace(workspace)
        .await
        .expect("replace policy workspace");
    assert_eq!(snapshot(db).await.policy_revision, expected);
}

async fn set_live_policy_revision(db: &AsyncDaemonDb, revision: i64) {
    query(
        "UPDATE policy_canvases
         SET live_document_json = json_set(live_document_json, '$.revision', ?1)
         WHERE canvas_id = (SELECT active_canvas_id FROM policy_workspace WHERE singleton = 1)",
    )
    .bind(revision)
    .execute(db.pool())
    .await
    .expect("update live policy revision");
}

async fn snapshot(db: &AsyncDaemonDb) -> crate::task_board::TaskBoardAutomationSnapshot {
    db.task_board_automation_snapshot()
        .await
        .expect("build automation snapshot")
}

fn timestamp(value: DateTime<Utc>) -> String {
    value.to_rfc3339()
}

async fn wait_until_after(instant: DateTime<Utc>) -> DateTime<Utc> {
    loop {
        let now = Utc::now();
        if now > instant {
            return now;
        }
        tokio::task::yield_now().await;
    }
}
