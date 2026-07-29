use tempfile::tempdir;

use super::tests::legacy_v40_fixture_at;
use harness_daemon::daemon::db::DaemonDb;
use harness_task_board::TASK_BOARD_LEGACY_LOCAL_TARGET_ADOPTION_V43;

const LEGACY_ACTION: &str = "implementation:1";
const LEGACY_ATTEMPT: &str = "1";
const LEGACY_IDEMPOTENCY_KEY: &str = "legacy-local-attempt-1";

// The controller-fixture variant of this test - upgrading a targetless
// Starting workflow built through the real async dispatch/offer/claim path,
// not raw SQL - lives in `harness-daemon`'s own
// `db/tests/schema_v43_legacy_target_controller.rs` instead of here: it
// needs `db::task_board::remote_assignment_test_support`'s `ControllerFixture`,
// which reaches deep into daemon-internal `AsyncDaemonDb` test-only methods
// that stay `cfg(test)`-only rather than widen behind `test-support`.
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
        harness_daemon::daemon::db::SCHEMA_VERSION
    );
    assert_sync_legacy_marker(upgraded.connection());
    drop(upgraded);

    let reopened = DaemonDb::open(&path).expect("reopen upgraded legacy target");
    assert_eq!(
        reopened.schema_version().expect("schema version"),
        harness_daemon::daemon::db::SCHEMA_VERSION
    );
    assert_sync_legacy_marker(reopened.connection());
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
