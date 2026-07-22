use rusqlite::Connection;
use sqlx::{Row, SqlitePool, query, query_scalar};
use tempfile::tempdir;

use super::tests::{legacy_v40_fixture, legacy_v40_fixture_at};
use super::*;
use crate::daemon::db::AsyncDaemonDb;

#[derive(Debug, PartialEq, Eq)]
struct LegacyAssignment {
    assignment_id: String,
    execution_id: String,
    phase: String,
    host_id: String,
    idempotency_key: String,
    fencing_epoch: i64,
    state: String,
    legacy_migrated: i64,
    offered_at: String,
    claimed_at: Option<String>,
    started_at: Option<String>,
    heartbeat_at: Option<String>,
    completed_at: Option<String>,
    result_json: Option<String>,
    error: Option<String>,
    updated_at: String,
    new_evidence: NewAssignmentEvidence,
}

#[derive(Debug, Default, PartialEq, Eq)]
struct NewAssignmentEvidence {
    action_key: Option<String>,
    attempt: Option<i64>,
    target_host_instance_id: Option<String>,
    claimed_host_instance_id: Option<String>,
    lease_id: Option<String>,
    configuration_revision: Option<i64>,
    execution_record_sha256: Option<String>,
    request_sha256: Option<String>,
    request_json: Option<String>,
    authenticated_principal: Option<String>,
    claim_request_sha256: Option<String>,
    claim_response_json: Option<String>,
    claim_receipt_sha256: Option<String>,
    controller_lifecycle_trust_json: Option<String>,
    controller_lifecycle_trust_sha256: Option<String>,
    controller_operation_kind: Option<String>,
    controller_operation_request_sha256: Option<String>,
    controller_operation_trust_sha256: Option<String>,
    controller_operation_fence_json: Option<String>,
    controller_operation_fence_sha256: Option<String>,
    last_mutation_kind: Option<String>,
    last_mutation_sha256: Option<String>,
    lease_expires_at: Option<String>,
    deadline_at: Option<String>,
    cancel_requested_at: Option<String>,
    workspace_ref: Option<String>,
    executor_configuration_revision: Option<i64>,
    executor_checkout_path: Option<String>,
    executor_start_authority_sha256: Option<String>,
    executor_start_authority_at: Option<String>,
    executor_start_io_permit_sha256: Option<String>,
    executor_start_io_permit_at: Option<String>,
    executor_start_receipt_json: Option<String>,
    executor_start_receipt_sha256: Option<String>,
    executor_lifecycle_owner_instance_id: Option<String>,
    executor_lifecycle_owner_epoch: Option<i64>,
    executor_lifecycle_owner_acquired_at: Option<String>,
    executor_lifecycle_owner_expires_at: Option<String>,
    executor_lifecycle_owner_sha256: Option<String>,
    executor_stop_pending_json: Option<String>,
    executor_stop_pending_sha256: Option<String>,
    status_sha256: Option<String>,
    result_sha256: Option<String>,
    cleanup_settlement_request_sha256: Option<String>,
    cleanup_completed_at: Option<String>,
}

#[test]
fn sync_v36_assignment_upgrade_preserves_every_legacy_field() {
    let db = legacy_v40_fixture();

    run(db.connection()).expect("migrate legacy remote assignment synchronously");

    assert_eq!(
        read_sync_assignments(db.connection()),
        expected_assignments()
    );
}

#[tokio::test]
async fn async_v36_assignment_upgrade_preserves_every_legacy_field() {
    let temp = tempdir().expect("tempdir");
    let path = temp.path().join("harness.db");
    let db = legacy_v40_fixture_at(&path);
    drop(db);

    let db = AsyncDaemonDb::connect(&path)
        .await
        .expect("migrate legacy remote assignment asynchronously");

    assert_eq!(db.schema_version().await.expect("schema version"), "43");
    let migration_count: i64 =
        query_scalar("SELECT COUNT(*) FROM _sqlx_migrations WHERE version = 35")
            .fetch_one(db.pool())
            .await
            .expect("count v43 migration ledger row");
    assert_eq!(migration_count, 1);
    assert_eq!(
        read_async_assignments(db.pool()).await,
        expected_assignments()
    );
}

fn expected_assignments() -> Vec<LegacyAssignment> {
    vec![
        LegacyAssignment {
            assignment_id: "legacy-assignment".into(),
            execution_id: "execution-a".into(),
            phase: "planning".into(),
            host_id: "executor-a".into(),
            idempotency_key: "legacy-idempotency".into(),
            fencing_epoch: 1,
            state: "superseded".into(),
            legacy_migrated: 1,
            offered_at: "2026-07-19T08:01:00Z".into(),
            claimed_at: Some("2026-07-19T08:02:00Z".into()),
            started_at: Some("2026-07-19T08:03:00Z".into()),
            heartbeat_at: Some("2026-07-19T08:04:00Z".into()),
            completed_at: Some("2026-07-19T08:05:00Z".into()),
            result_json: Some(r#"{"legacy_result":"legacy-result-a"}"#.into()),
            error: Some("legacy-error-a".into()),
            updated_at: "2026-07-19T08:05:00Z".into(),
            new_evidence: NewAssignmentEvidence::default(),
        },
        LegacyAssignment {
            assignment_id: "legacy-nullable-assignment".into(),
            execution_id: "execution-a".into(),
            phase: "reviewing".into(),
            host_id: "executor-a".into(),
            idempotency_key: "legacy-nullable-idempotency".into(),
            fencing_epoch: 2,
            state: "superseded".into(),
            legacy_migrated: 1,
            offered_at: "2026-07-19T08:06:00Z".into(),
            claimed_at: None,
            started_at: None,
            heartbeat_at: None,
            completed_at: Some("2026-07-19T08:06:00Z".into()),
            result_json: None,
            error: Some("migrated from dormant v36 assignment; never executable".into()),
            updated_at: "2026-07-19T08:06:00Z".into(),
            new_evidence: NewAssignmentEvidence::default(),
        },
    ]
}

const LEGACY_ASSIGNMENT_SELECT: &str =
    "SELECT assignment_id, execution_id, phase, host_id, idempotency_key,
            fencing_epoch, state, legacy_migrated, offered_at, claimed_at,
            started_at, heartbeat_at, completed_at, result_json, error, updated_at,
            action_key, attempt, target_host_instance_id, claimed_host_instance_id,
            lease_id, configuration_revision, execution_record_sha256, request_sha256,
            request_json, authenticated_principal,
            claim_request_sha256, claim_response_json, claim_receipt_sha256,
            controller_lifecycle_trust_json, controller_lifecycle_trust_sha256,
            controller_operation_kind, controller_operation_request_sha256,
            controller_operation_trust_sha256, controller_operation_fence_json,
            controller_operation_fence_sha256, last_mutation_kind, last_mutation_sha256,
            lease_expires_at, deadline_at, cancel_requested_at, workspace_ref,
            executor_configuration_revision, executor_checkout_path,
            executor_start_authority_sha256, executor_start_authority_at,
            executor_start_io_permit_sha256, executor_start_io_permit_at,
            executor_start_receipt_json, executor_start_receipt_sha256,
            executor_lifecycle_owner_instance_id, executor_lifecycle_owner_epoch,
            executor_lifecycle_owner_acquired_at, executor_lifecycle_owner_expires_at,
            executor_lifecycle_owner_sha256, executor_stop_pending_json,
            executor_stop_pending_sha256, status_sha256, result_sha256,
            cleanup_settlement_request_sha256, cleanup_completed_at
     FROM task_board_remote_assignments
     WHERE legacy_migrated = 1
     ORDER BY assignment_id";

fn read_sync_assignments(conn: &Connection) -> Vec<LegacyAssignment> {
    let mut statement = conn
        .prepare(LEGACY_ASSIGNMENT_SELECT)
        .expect("prepare synchronously migrated legacy assignments");
    statement
        .query_map([], decode_sync_assignment)
        .expect("read synchronously migrated legacy assignments")
        .collect::<Result<Vec<_>, _>>()
        .expect("decode synchronously migrated legacy assignments")
}

fn decode_sync_assignment(row: &rusqlite::Row<'_>) -> rusqlite::Result<LegacyAssignment> {
    Ok(LegacyAssignment {
        assignment_id: row.get(0)?,
        execution_id: row.get(1)?,
        phase: row.get(2)?,
        host_id: row.get(3)?,
        idempotency_key: row.get(4)?,
        fencing_epoch: row.get(5)?,
        state: row.get(6)?,
        legacy_migrated: row.get(7)?,
        offered_at: row.get(8)?,
        claimed_at: row.get(9)?,
        started_at: row.get(10)?,
        heartbeat_at: row.get(11)?,
        completed_at: row.get(12)?,
        result_json: row.get(13)?,
        error: row.get(14)?,
        updated_at: row.get(15)?,
        new_evidence: NewAssignmentEvidence {
            action_key: row.get(16)?,
            attempt: row.get(17)?,
            target_host_instance_id: row.get(18)?,
            claimed_host_instance_id: row.get(19)?,
            lease_id: row.get(20)?,
            configuration_revision: row.get(21)?,
            execution_record_sha256: row.get(22)?,
            request_sha256: row.get(23)?,
            request_json: row.get(24)?,
            authenticated_principal: row.get(25)?,
            claim_request_sha256: row.get(26)?,
            claim_response_json: row.get(27)?,
            claim_receipt_sha256: row.get(28)?,
            controller_lifecycle_trust_json: row.get(29)?,
            controller_lifecycle_trust_sha256: row.get(30)?,
            controller_operation_kind: row.get(31)?,
            controller_operation_request_sha256: row.get(32)?,
            controller_operation_trust_sha256: row.get(33)?,
            controller_operation_fence_json: row.get(34)?,
            controller_operation_fence_sha256: row.get(35)?,
            last_mutation_kind: row.get(36)?,
            last_mutation_sha256: row.get(37)?,
            lease_expires_at: row.get(38)?,
            deadline_at: row.get(39)?,
            cancel_requested_at: row.get(40)?,
            workspace_ref: row.get(41)?,
            executor_configuration_revision: row.get(42)?,
            executor_checkout_path: row.get(43)?,
            executor_start_authority_sha256: row.get(44)?,
            executor_start_authority_at: row.get(45)?,
            executor_start_io_permit_sha256: row.get(46)?,
            executor_start_io_permit_at: row.get(47)?,
            executor_start_receipt_json: row.get(48)?,
            executor_start_receipt_sha256: row.get(49)?,
            executor_lifecycle_owner_instance_id: row.get(50)?,
            executor_lifecycle_owner_epoch: row.get(51)?,
            executor_lifecycle_owner_acquired_at: row.get(52)?,
            executor_lifecycle_owner_expires_at: row.get(53)?,
            executor_lifecycle_owner_sha256: row.get(54)?,
            executor_stop_pending_json: row.get(55)?,
            executor_stop_pending_sha256: row.get(56)?,
            status_sha256: row.get(57)?,
            result_sha256: row.get(58)?,
            cleanup_settlement_request_sha256: row.get(59)?,
            cleanup_completed_at: row.get(60)?,
        },
    })
}

async fn read_async_assignments(pool: &SqlitePool) -> Vec<LegacyAssignment> {
    query(LEGACY_ASSIGNMENT_SELECT)
        .fetch_all(pool)
        .await
        .expect("read asynchronously migrated legacy assignments")
        .into_iter()
        .map(|row| decode_async_assignment(&row))
        .collect()
}

fn decode_async_assignment(row: &sqlx::sqlite::SqliteRow) -> LegacyAssignment {
    LegacyAssignment {
        assignment_id: row.get(0),
        execution_id: row.get(1),
        phase: row.get(2),
        host_id: row.get(3),
        idempotency_key: row.get(4),
        fencing_epoch: row.get(5),
        state: row.get(6),
        legacy_migrated: row.get(7),
        offered_at: row.get(8),
        claimed_at: row.get(9),
        started_at: row.get(10),
        heartbeat_at: row.get(11),
        completed_at: row.get(12),
        result_json: row.get(13),
        error: row.get(14),
        updated_at: row.get(15),
        new_evidence: NewAssignmentEvidence {
            action_key: row.get(16),
            attempt: row.get(17),
            target_host_instance_id: row.get(18),
            claimed_host_instance_id: row.get(19),
            lease_id: row.get(20),
            configuration_revision: row.get(21),
            execution_record_sha256: row.get(22),
            request_sha256: row.get(23),
            request_json: row.get(24),
            authenticated_principal: row.get(25),
            claim_request_sha256: row.get(26),
            claim_response_json: row.get(27),
            claim_receipt_sha256: row.get(28),
            controller_lifecycle_trust_json: row.get(29),
            controller_lifecycle_trust_sha256: row.get(30),
            controller_operation_kind: row.get(31),
            controller_operation_request_sha256: row.get(32),
            controller_operation_trust_sha256: row.get(33),
            controller_operation_fence_json: row.get(34),
            controller_operation_fence_sha256: row.get(35),
            last_mutation_kind: row.get(36),
            last_mutation_sha256: row.get(37),
            lease_expires_at: row.get(38),
            deadline_at: row.get(39),
            cancel_requested_at: row.get(40),
            workspace_ref: row.get(41),
            executor_configuration_revision: row.get(42),
            executor_checkout_path: row.get(43),
            executor_start_authority_sha256: row.get(44),
            executor_start_authority_at: row.get(45),
            executor_start_io_permit_sha256: row.get(46),
            executor_start_io_permit_at: row.get(47),
            executor_start_receipt_json: row.get(48),
            executor_start_receipt_sha256: row.get(49),
            executor_lifecycle_owner_instance_id: row.get(50),
            executor_lifecycle_owner_epoch: row.get(51),
            executor_lifecycle_owner_acquired_at: row.get(52),
            executor_lifecycle_owner_expires_at: row.get(53),
            executor_lifecycle_owner_sha256: row.get(54),
            executor_stop_pending_json: row.get(55),
            executor_stop_pending_sha256: row.get(56),
            status_sha256: row.get(57),
            result_sha256: row.get(58),
            cleanup_settlement_request_sha256: row.get(59),
            cleanup_completed_at: row.get(60),
        },
    }
}
