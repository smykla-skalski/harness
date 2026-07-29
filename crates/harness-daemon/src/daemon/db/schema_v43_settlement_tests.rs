use super::*;
use crate::daemon::db::DaemonDb;
use rusqlite::params;

const OFFER_DIGEST: &str = "1111111111111111111111111111111111111111111111111111111111111111";
const CHILD_DIGEST: &str = "2222222222222222222222222222222222222222222222222222222222222222";

#[test]
fn fresh_schema_owns_settlement_artifact_and_quarantine_evidence() {
    let db = DaemonDb::open_in_memory().expect("open daemon db");
    for table in [
        "task_board_remote_settlement_receipts",
        "task_board_remote_source_bundles",
        "task_board_remote_outbound_sources",
        "task_board_remote_artifacts",
        "task_board_remote_recovery_quarantine",
    ] {
        let present: i64 = db
            .connection()
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
                [table],
                |row| row.get(0),
            )
            .expect("inspect settlement schema table");
        assert_eq!(present, 1, "missing strict table {table}");
    }
    let settlement_columns: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('task_board_remote_settlement_receipts')
             WHERE name IN (
               'lease_id', 'offer_request_sha256', 'terminal_state', 'result_sha256',
               'request_sha256', 'authenticated_principal', 'response_json', 'settled_at',
               'cleanup_ready_at'
             )",
            [],
            |row| row.get(0),
        )
        .expect("inspect settlement receipt columns");
    assert_eq!(settlement_columns, 9);
    let artifact_columns: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('task_board_remote_artifacts')
             WHERE name IN (
               'assignment_id', 'fencing_epoch', 'relative_path', 'sha256', 'size_bytes',
               'media_type', 'content', 'stored_at'
             )",
            [],
            |row| row.get(0),
        )
        .expect("inspect artifact columns");
    assert_eq!(artifact_columns, 8);
    let source_columns: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('task_board_remote_source_bundles')
             WHERE name IN ('source_kind', 'base_revision', 'result_revision', 'advertised_ref')",
            [],
            |row| row.get(0),
        )
        .expect("inspect source receipt provenance columns");
    assert_eq!(source_columns, 4);
    let outbound_columns: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('task_board_remote_outbound_sources')
             WHERE name IN (
               'offer_request_sha256', 'upload_request_sha256', 'source_kind',
               'repository', 'base_revision', 'result_revision', 'advertised_ref',
               'content', 'content_pruned_at'
             )",
            [],
            |row| row.get(0),
        )
        .expect("inspect outbound source provenance columns");
    assert_eq!(outbound_columns, 9);
    let cleanup_columns: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('task_board_remote_assignments')
             WHERE name IN (
               'cleanup_settlement_request_sha256', 'cleanup_completed_at'
             )",
            [],
            |row| row.get(0),
        )
        .expect("inspect durable cleanup marker columns");
    assert_eq!(cleanup_columns, 2);
}

#[test]
fn repair_restores_settlement_retention_index_but_refuses_table_drift() {
    let db = DaemonDb::open_in_memory().expect("open daemon db");
    db.connection()
        .execute_batch(
            "DROP INDEX task_board_remote_settlement_receipts_retention;
             DROP INDEX task_board_remote_assignments_identity_epoch;",
        )
        .expect("drop repairable settlement indexes");

    run(db.connection()).expect("repair settlement retention index");
    let repaired: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index'
             AND name = 'task_board_remote_settlement_receipts_retention'",
            [],
            |row| row.get(0),
        )
        .expect("inspect repaired settlement index");
    assert_eq!(repaired, 1);
    let parent_key: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index'
             AND name = 'task_board_remote_assignments_identity_epoch'",
            [],
            |row| row.get(0),
        )
        .expect("inspect repaired parent generation index");
    assert_eq!(parent_key, 1);

    db.connection()
        .execute(
            "ALTER TABLE task_board_remote_settlement_receipts
             ADD COLUMN mutable_cleanup_hint TEXT",
            [],
        )
        .expect("malform settlement receipt table");
    let error = run(db.connection()).expect_err("settlement table drift must fail closed");
    assert!(error.to_string().contains("refusing destructive repair"));
}

#[test]
fn child_evidence_rejects_a_mismatched_assignment_generation() {
    let db = strict_assignment_fixture();
    let (request_json, response_json) = mismatched_settlement_json();
    let settlement_error = db
        .connection()
        .execute(
            "INSERT INTO task_board_remote_settlement_receipts (
               assignment_id, execution_id, phase, action_key, attempt, idempotency_key,
               host_id, target_host_instance_id, fencing_epoch, configuration_revision,
               execution_record_sha256, lease_id, offer_request_sha256, terminal_state,
               result_sha256, request_sha256, request_json, authenticated_principal,
               response_json, settled_at, cleanup_ready_at
             ) VALUES (
               'assignment-a', 'execution-a', 'implementation', 'implementation:1', 1,
               'idempotency-assignment-a', 'executor-a', 'instance-a', 2, 7,
               ?1, 'lease-a', ?2, 'cancelled', NULL, ?3, ?4,
               'executor:executor-a', ?5, '2026-07-19T09:10:00Z',
               '2026-07-19T09:10:00Z'
             )",
            params![
                "a".repeat(64),
                OFFER_DIGEST,
                CHILD_DIGEST,
                request_json,
                response_json
            ],
        )
        .expect_err("settlement receipt must bind the parent epoch");
    assert!(settlement_error.to_string().contains("FOREIGN KEY"));

    let artifact_error = db
        .connection()
        .execute(
            "INSERT INTO task_board_remote_artifacts (
               assignment_id, fencing_epoch, lease_id, offer_request_sha256,
               authenticated_principal, relative_path, sha256, size_bytes,
               media_type, content, stored_at
             ) VALUES (
               'assignment-a', 2, 'lease-a', ?1, 'executor:executor-a',
               'result.json', ?2, 1, 'application/json', X'7B',
               '2026-07-19T09:10:00Z'
             )",
            params![OFFER_DIGEST, CHILD_DIGEST],
        )
        .expect_err("artifact must bind the parent epoch");
    assert!(artifact_error.to_string().contains("FOREIGN KEY"));

    let quarantine_error = db
        .connection()
        .execute(
            "INSERT INTO task_board_remote_recovery_quarantine (
               assignment_id, fencing_epoch, assignment_state, assignment_updated_at,
               state_fingerprint, failure_count, next_attempt_at, last_error_code,
               updated_at
             ) VALUES (
               'assignment-a', 2, 'cancelled', '2026-07-19T09:05:00Z', ?1, 1,
               '2026-07-19T09:06:00Z', 'workflow_io', '2026-07-19T09:05:00Z'
             )",
            [CHILD_DIGEST],
        )
        .expect_err("quarantine must bind the parent epoch");
    assert!(quarantine_error.to_string().contains("FOREIGN KEY"));
}

#[test]
fn settlement_response_requires_exact_request_digest_echo() {
    let db = strict_assignment_fixture();
    insert_valid_settlement_receipt(&db);

    let error = db
        .connection()
        .execute(
            "UPDATE task_board_remote_settlement_receipts
             SET response_json = json_set(
               response_json, '$.settlement_request_sha256', ?1
             )
             WHERE assignment_id = 'assignment-a'",
            [OFFER_DIGEST],
        )
        .expect_err("settlement response must echo the exact request digest");
    assert!(error.to_string().contains("CHECK constraint failed"));
}

#[test]
fn settlement_receipt_prevents_parent_assignment_delete() {
    let db = strict_assignment_fixture();
    super::super::schema_v45::run(db.connection()).expect("migrate remote execution integrity");
    insert_valid_settlement_receipt(&db);

    let error = db
        .connection()
        .execute(
            "DELETE FROM task_board_remote_assignments WHERE assignment_id = 'assignment-a'",
            [],
        )
        .expect_err("immutable settlement evidence must prevent parent delete");
    assert!(
        error
            .to_string()
            .contains("cannot delete remote assignment with immutable settlement receipt")
    );
}

#[test]
fn child_evidence_prevents_parent_epoch_rewrite() {
    let db = strict_assignment_fixture();
    db.connection()
        .execute(
            "INSERT INTO task_board_remote_artifacts (
               assignment_id, fencing_epoch, lease_id, offer_request_sha256,
               authenticated_principal, relative_path, sha256, size_bytes,
               media_type, content, stored_at
             ) VALUES (
               'assignment-a', 1, 'lease-a', ?1, 'executor:executor-a',
               'result.json', ?2, 1, 'application/json', X'7B',
               '2026-07-19T09:10:00Z'
             )",
            params![OFFER_DIGEST, CHILD_DIGEST],
        )
        .expect("insert exact-generation artifact");

    let error = db
        .connection()
        .execute(
            "UPDATE task_board_remote_assignments
             SET fencing_epoch = 2,
                 request_json = json_set(request_json, '$.binding.fencing_epoch', 2)
             WHERE assignment_id = 'assignment-a'",
            [],
        )
        .expect_err("child evidence must prevent parent epoch rewrite");
    assert!(error.to_string().contains("FOREIGN KEY"));
}

#[test]
fn failed_status_failure_class_is_typed_and_failed_only() {
    let db = strict_assignment_fixture();
    let valid = failed_status_json("transient");
    db.connection()
        .execute(
            "UPDATE task_board_remote_assignments
             SET state = 'failed', result_json = ?1, status_sha256 = ?2,
                 completed_at = '2026-07-19T09:10:00Z',
                 updated_at = '2026-07-19T09:10:00Z'
             WHERE assignment_id = 'assignment-a'",
            params![valid, CHILD_DIGEST],
        )
        .expect("store typed failed status");

    for corruption in [
        "json_remove(result_json, '$.failure_class')",
        "json_set(result_json, '$.failure_class', NULL)",
        "json_set(result_json, '$.failure_class', 'unknown_outcome')",
        "json_set(result_json, '$.failure_class', 'fabricated')",
    ] {
        let error = db
            .connection()
            .execute(
                &format!(
                    "UPDATE task_board_remote_assignments
                     SET result_json = {corruption}
                     WHERE assignment_id = 'assignment-a'"
                ),
                [],
            )
            .expect_err("invalid failed status class must fail closed");
        assert!(error.to_string().contains("CHECK constraint failed"));
    }

    let error = db
        .connection()
        .execute(
            "UPDATE task_board_remote_assignments
             SET state = 'unknown',
                 result_json = json_set(result_json, '$.state', 'unknown')
             WHERE assignment_id = 'assignment-a'",
            [],
        )
        .expect_err("non-failed status must not retain a failure class");
    assert!(error.to_string().contains("CHECK constraint failed"));
}

#[test]
fn cleanup_marker_is_paired_and_terminal() {
    let db = super::tests::legacy_v40_fixture();
    run(db.connection()).expect("migrate strict remote execution schema");
    let offer = super::tests::strict_request("assignment-a", "execution-a", 1, OFFER_DIGEST);
    super::tests::insert_strict_assignment(db.connection(), "assignment-a", 1, &offer)
        .expect("insert strict assignment");
    let digest = "3".repeat(64);
    let active_error = db
        .connection()
        .execute(
            "UPDATE task_board_remote_assignments
             SET cleanup_settlement_request_sha256 = ?1,
                 cleanup_completed_at = '2026-07-19T09:10:00Z'
             WHERE assignment_id = 'assignment-a'",
            [&digest],
        )
        .expect_err("active assignment must reject a cleanup marker");
    assert!(active_error.to_string().contains("CHECK constraint failed"));

    db.connection()
        .execute(
            "UPDATE task_board_remote_assignments
             SET lease_id = 'lease-a', state = 'cancelled',
                 completed_at = '2026-07-19T09:05:00Z',
                 updated_at = '2026-07-19T09:05:00Z'
             WHERE assignment_id = 'assignment-a'",
            [],
        )
        .expect("make strict assignment terminal");
    for update in [
        "cleanup_settlement_request_sha256 = NULL,
         cleanup_completed_at = '2026-07-19T09:10:00Z'",
        "cleanup_settlement_request_sha256 = '3333333333333333333333333333333333333333333333333333333333333333',
         cleanup_completed_at = NULL",
    ] {
        let error = db
            .connection()
            .execute(
                &format!(
                    "UPDATE task_board_remote_assignments SET {update}
                     WHERE assignment_id = 'assignment-a'"
                ),
                [],
            )
            .expect_err("partial cleanup marker must fail closed");
        assert!(error.to_string().contains("CHECK constraint failed"));
    }
}

fn strict_assignment_fixture() -> DaemonDb {
    let db = super::tests::legacy_v40_fixture();
    run(db.connection()).expect("migrate strict remote execution schema");
    let offer = super::tests::strict_request("assignment-a", "execution-a", 1, OFFER_DIGEST);
    super::tests::insert_strict_assignment(db.connection(), "assignment-a", 1, &offer)
        .expect("insert strict assignment");
    db.connection()
        .execute(
            "UPDATE task_board_remote_assignments
             SET lease_id = 'lease-a', state = 'cancelled',
                 completed_at = '2026-07-19T09:05:00Z',
                 updated_at = '2026-07-19T09:05:00Z'
             WHERE assignment_id = 'assignment-a'",
            [],
        )
        .expect("make strict assignment terminal");
    db
}

fn insert_valid_settlement_receipt(db: &DaemonDb) {
    let (request_json, response_json) = settlement_json(1, CHILD_DIGEST);
    db.connection()
        .execute(
            "INSERT INTO task_board_remote_settlement_receipts (
               assignment_id, execution_id, phase, action_key, attempt, idempotency_key,
               host_id, target_host_instance_id, fencing_epoch, configuration_revision,
               execution_record_sha256, lease_id, offer_request_sha256, terminal_state,
               result_sha256, request_sha256, request_json, authenticated_principal,
               response_json, settled_at, cleanup_ready_at
             ) VALUES (
               'assignment-a', 'execution-a', 'implementation', 'implementation:1', 1,
               'idempotency-assignment-a', 'executor-a', 'instance-a', 1, 7,
               ?1, 'lease-a', ?2, 'cancelled', NULL, ?3, ?4,
               'executor:executor-a', ?5, '2026-07-19T09:10:00Z',
               '2026-07-19T09:10:00Z'
             )",
            params![
                "a".repeat(64),
                OFFER_DIGEST,
                CHILD_DIGEST,
                request_json,
                response_json
            ],
        )
        .expect("insert exact settlement response digest echo");
}

fn mismatched_settlement_json() -> (String, String) {
    settlement_json(2, CHILD_DIGEST)
}

fn settlement_json(fencing_epoch: i64, response_request_sha256: &str) -> (String, String) {
    let offer =
        super::tests::strict_request("assignment-a", "execution-a", fencing_epoch, OFFER_DIGEST);
    let binding = serde_json::from_str::<serde_json::Value>(&offer)
        .expect("decode strict offer")
        .get("binding")
        .expect("offer binding")
        .clone();
    let request = serde_json::json!({
        "schema_version": 1,
        "binding": binding,
        "lease_id": "lease-a",
        "offer_request_sha256": OFFER_DIGEST,
        "terminal_state": "cancelled",
        "result_sha256": null,
        "request_sha256": CHILD_DIGEST,
    });
    let response = serde_json::json!({
        "schema_version": 1,
        "binding": request["binding"],
        "offer_request_sha256": OFFER_DIGEST,
        "settlement_request_sha256": response_request_sha256,
        "settled_at": "2026-07-19T09:10:00Z",
    });
    (request.to_string(), response.to_string())
}

fn failed_status_json(failure_class: &str) -> String {
    let offer = super::tests::strict_request("assignment-a", "execution-a", 1, OFFER_DIGEST);
    let binding = serde_json::from_str::<serde_json::Value>(&offer)
        .expect("decode strict offer")
        .get("binding")
        .expect("offer binding")
        .clone();
    serde_json::json!({
        "schema_version": 1,
        "binding": binding,
        "state": "failed",
        "offer_request_sha256": OFFER_DIGEST,
        "status_sha256": CHILD_DIGEST,
        "output_artifacts": {},
        "failure_class": failure_class,
        "error_code": "executor_failed",
        "observed_at": "2026-07-19T09:10:00Z",
    })
    .to_string()
}
