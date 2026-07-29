use sqlx::{query, query_scalar};
use tempfile::tempdir;

use super::tests::legacy_v40_fixture_at;
use crate::daemon::db::task_board::remote_assignment_test_support::controller_fixture;
use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::task_board::{
    TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE, TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE,
    TASK_BOARD_EXECUTION_TARGET_RESOURCE, TASK_BOARD_LEGACY_LOCAL_TARGET_ACTION_RESOURCE,
    TASK_BOARD_LEGACY_LOCAL_TARGET_ADOPTION_RESOURCE, TASK_BOARD_LEGACY_LOCAL_TARGET_ADOPTION_V43,
    TASK_BOARD_LEGACY_LOCAL_TARGET_ATTEMPT_RESOURCE,
    TASK_BOARD_LEGACY_LOCAL_TARGET_IDEMPOTENCY_RESOURCE, TaskBoardAttemptState,
    TaskBoardExecutionAttemptCas, TaskBoardExecutionState, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionRecord,
};

const CLAIMED_AT: &str = "2026-07-19T10:00:01Z";
const LEGACY_ACTION: &str = "implementation:1";
const LEGACY_ATTEMPT: &str = "1";
const LEGACY_IDEMPOTENCY_KEY: &str = "legacy-local-attempt-1";

#[test]
fn sync_v43_upgrade_persists_exact_legacy_marker_across_reopen() {
    let temp = tempdir().expect("tempdir");
    let path = temp.path().join("legacy-target.db");
    let legacy = legacy_v40_fixture_at(&path);
    seed_sync_targetless_starting(legacy.connection());
    drop(legacy);

    let upgraded = DaemonDb::open(&path).expect("upgrade legacy target synchronously");
    assert_eq!(
        upgraded.schema_version().expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
    assert_sync_legacy_marker(upgraded.connection());
    drop(upgraded);

    let reopened = DaemonDb::open(&path).expect("reopen upgraded legacy target");
    assert_eq!(
        reopened.schema_version().expect("schema version"),
        crate::daemon::db::SCHEMA_VERSION
    );
    assert_sync_legacy_marker(reopened.connection());
}

#[tokio::test]
async fn v43_upgrade_marks_and_consumes_only_the_exact_legacy_starting_generation() {
    let fixture = controller_fixture(1).await;
    let path = fixture._temp.path().join("controller.db");
    let snapshot_revision = fixture.execution.snapshot.configuration_revision;
    seed_targetless_starting(&fixture.db, &fixture.execution).await;
    drop(fixture.db);

    let sync = DaemonDb::open(&path).expect("open controller database synchronously");
    super::restore_legacy_v40_for_test(&sync);
    sync.connection()
        .execute(
            "UPDATE task_board_orchestrator_settings SET revision = ?1",
            [i64::try_from(snapshot_revision).expect("settings revision")],
        )
        .expect("restore frozen settings revision");
    sync.connection()
        .execute("DELETE FROM _sqlx_migrations WHERE version = 35", [])
        .expect("replay v43 migration");
    drop(sync);

    let db = AsyncDaemonDb::connect(&path)
        .await
        .expect("upgrade targetless Starting workflow");
    let migrated = db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load migrated workflow")
        .expect("migrated workflow exists");
    assert_async_legacy_marker(&migrated);
    let adopted = adopt_legacy_marker(&db, &migrated).await;
    assert!(legacy_marker_absent(&adopted));
    assert_eq!(
        adopted
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
            .map(String::as_str),
        Some("local")
    );

    drop(db);
    let db = AsyncDaemonDb::connect(&path)
        .await
        .expect("reopen after consuming the legacy marker");
    let adopted = db
        .task_board_workflow_execution(&fixture.execution.execution_id)
        .await
        .expect("load adopted workflow after restart")
        .expect("adopted workflow exists after restart");
    assert!(legacy_marker_absent(&adopted));
    assert_later_generation_rejected(&db, &adopted).await;
}

fn assert_async_legacy_marker(execution: &TaskBoardWorkflowExecutionRecord) {
    let current = execution.attempts.first().expect("legacy attempt");
    assert_eq!(current.state, TaskBoardAttemptState::Starting);
    assert_eq!(
        execution
            .ownership
            .resources
            .get(TASK_BOARD_LEGACY_LOCAL_TARGET_ADOPTION_RESOURCE)
            .map(String::as_str),
        Some(TASK_BOARD_LEGACY_LOCAL_TARGET_ADOPTION_V43)
    );
    assert_eq!(
        execution
            .ownership
            .resources
            .get(TASK_BOARD_LEGACY_LOCAL_TARGET_ACTION_RESOURCE),
        Some(&current.action_key)
    );
    assert_eq!(
        execution
            .ownership
            .resources
            .get(TASK_BOARD_LEGACY_LOCAL_TARGET_ATTEMPT_RESOURCE),
        Some(&current.attempt.to_string())
    );
    assert_eq!(
        execution
            .ownership
            .resources
            .get(TASK_BOARD_LEGACY_LOCAL_TARGET_IDEMPOTENCY_RESOURCE),
        Some(&current.idempotency_key)
    );
}

async fn adopt_legacy_marker(
    db: &AsyncDaemonDb,
    migrated: &TaskBoardWorkflowExecutionRecord,
) -> TaskBoardWorkflowExecutionRecord {
    let current = migrated.attempts.first().expect("legacy attempt");
    let mut claimed = current.clone();
    claimed.state = TaskBoardAttemptState::Running;
    claimed.updated_at = CLAIMED_AT.into();
    assert!(
        db.claim_task_board_workflow_side_effect(
            &TaskBoardWorkflowExecutionCas::from(migrated),
            &TaskBoardExecutionAttemptCas::from(current),
            &claimed,
            CLAIMED_AT,
        )
        .await
        .expect("adopt migrated legacy local target")
        .is_some()
    );
    let adopted = db
        .task_board_workflow_execution(&migrated.execution_id)
        .await
        .expect("load adopted workflow")
        .expect("adopted workflow exists");
    assert_eq!(
        adopted
            .ownership
            .resources
            .get(TASK_BOARD_EXECUTION_TARGET_RESOURCE)
            .map(String::as_str),
        Some("local")
    );
    adopted
}

async fn assert_later_generation_rejected(
    db: &AsyncDaemonDb,
    adopted: &TaskBoardWorkflowExecutionRecord,
) {
    seed_later_targetless_starting(db, adopted).await;
    let later = db
        .task_board_workflow_execution(&adopted.execution_id)
        .await
        .expect("load later targetless workflow")
        .expect("later targetless workflow exists");
    let later_attempt = later.attempts.first().expect("later attempt");
    let mut later_claim = later_attempt.clone();
    later_claim.state = TaskBoardAttemptState::Running;
    later_claim.updated_at = "2026-07-19T10:00:02Z".into();
    let error = db
        .claim_task_board_workflow_side_effect(
            &TaskBoardWorkflowExecutionCas::from(&later),
            &TaskBoardExecutionAttemptCas::from(later_attempt),
            &later_claim,
            &later_claim.updated_at,
        )
        .await
        .expect_err("consumed migration marker cannot authorize a later attempt");
    assert!(error.to_string().contains("target selection is incomplete"));
    assert_eq!(
        query_scalar::<_, i64>("SELECT COUNT(*) FROM codex_runs")
            .fetch_one(db.pool())
            .await
            .expect("count local runs"),
        0
    );
}

async fn seed_targetless_starting(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
) {
    let mut starting = execution.clone();
    starting.transition.execution_state = TaskBoardExecutionState::Starting;
    starting.attempts[0].state = TaskBoardAttemptState::Starting;
    persist_execution_shape(db, &starting).await;
}

async fn seed_later_targetless_starting(
    db: &AsyncDaemonDb,
    execution: &TaskBoardWorkflowExecutionRecord,
) {
    let mut later = execution.clone();
    later.transition.execution_state = TaskBoardExecutionState::Starting;
    later.ownership.host_id = None;
    for key in [
        TASK_BOARD_EXECUTION_TARGET_RESOURCE,
        TASK_BOARD_EXECUTION_TARGET_ACTION_RESOURCE,
        TASK_BOARD_EXECUTION_TARGET_ATTEMPT_RESOURCE,
    ] {
        later.ownership.resources.remove(key);
    }
    later.attempts[0].attempt = 2;
    later.attempts[0].idempotency_key = "post-migration-attempt-2".into();
    later.attempts[0].state = TaskBoardAttemptState::Starting;
    later.attempts[0].updated_at = "2026-07-19T10:00:02Z".into();
    persist_execution_shape(db, &later).await;
}

async fn persist_execution_shape(db: &AsyncDaemonDb, execution: &TaskBoardWorkflowExecutionRecord) {
    let diagnostics = serde_json::json!({
        "transition": execution.transition.clone(),
        "artifacts": execution.artifacts.clone(),
    });
    query(
        "UPDATE task_board_workflow_executions
         SET state = 'starting', diagnostics_json = ?2,
             host_id = NULL, resource_ownership_json = ?3
         WHERE execution_id = ?1",
    )
    .bind(&execution.execution_id)
    .bind(diagnostics.to_string())
    .bind(serde_json::to_string(&execution.ownership).expect("serialize ownership"))
    .execute(db.pool())
    .await
    .expect("persist targetless execution");
    let attempt = &execution.attempts[0];
    query(
        "UPDATE task_board_execution_attempts
         SET attempt = ?2, idempotency_key = ?3, state = 'starting', updated_at = ?4
         WHERE execution_id = ?1",
    )
    .bind(&execution.execution_id)
    .bind(i64::from(attempt.attempt))
    .bind(&attempt.idempotency_key)
    .bind(&attempt.updated_at)
    .execute(db.pool())
    .await
    .expect("persist targetless attempt");
}

fn seed_sync_targetless_starting(conn: &rusqlite::Connection) {
    conn.execute(
        "UPDATE task_board_workflow_executions
         SET phase = 'implementation', state = 'starting', host_id = NULL,
             resource_ownership_json = '{\"host_id\":null,\"fencing_epoch\":0,\"resources\":{}}'
         WHERE execution_id = 'execution-a'",
        [],
    )
    .expect("seed targetless legacy execution");
    conn.execute(
        "INSERT INTO task_board_execution_attempts (
             execution_id, action_key, attempt, idempotency_key, state,
             failure_class, available_at, error, artifact_json, started_at,
             updated_at, completed_at
         ) VALUES (
             'execution-a', ?1, 1, ?2, 'starting',
             NULL, NULL, NULL, NULL, '2026-07-19T09:00:00Z',
             '2026-07-19T09:00:00Z', NULL
         )",
        rusqlite::params![LEGACY_ACTION, LEGACY_IDEMPOTENCY_KEY],
    )
    .expect("seed exact legacy Starting attempt");
}

fn assert_sync_legacy_marker(conn: &rusqlite::Connection) {
    let marker = conn
        .query_row(
            "SELECT
                 json_extract(resource_ownership_json, '$.resources.legacy_local_target_adoption'),
                 json_extract(resource_ownership_json, '$.resources.legacy_local_target_action_key'),
                 json_extract(resource_ownership_json, '$.resources.legacy_local_target_attempt'),
                 json_extract(resource_ownership_json, '$.resources.legacy_local_target_idempotency_key')
             FROM task_board_workflow_executions
             WHERE execution_id = 'execution-a'",
            [],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                ))
            },
        )
        .expect("read exact migrated legacy marker");
    assert_eq!(
        marker,
        (
            TASK_BOARD_LEGACY_LOCAL_TARGET_ADOPTION_V43.into(),
            LEGACY_ACTION.into(),
            LEGACY_ATTEMPT.into(),
            LEGACY_IDEMPOTENCY_KEY.into(),
        )
    );
}

fn legacy_marker_absent(execution: &TaskBoardWorkflowExecutionRecord) -> bool {
    [
        TASK_BOARD_LEGACY_LOCAL_TARGET_ADOPTION_RESOURCE,
        TASK_BOARD_LEGACY_LOCAL_TARGET_ACTION_RESOURCE,
        TASK_BOARD_LEGACY_LOCAL_TARGET_ATTEMPT_RESOURCE,
        TASK_BOARD_LEGACY_LOCAL_TARGET_IDEMPOTENCY_RESOURCE,
    ]
    .iter()
    .all(|key| !execution.ownership.resources.contains_key(*key))
}
