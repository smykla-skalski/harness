use sqlx::query_as;
use tempfile::tempdir;

use super::RemoteAssignmentRow;
use crate::daemon::db::AsyncDaemonDb;

// The column order mirrors RemoteAssignmentRow::SELECT_COLLISION exactly so the
// derived FromRow decode lines up; unlike the production queries it omits the
// legacy_migrated = 0 filter so the archival fence in into_record can be reached.
const SELECT_ARCHIVAL_ROW: &str = "SELECT assignment_id, execution_id, phase,
    action_key, attempt, idempotency_key, host_id, target_host_instance_id,
    claimed_host_instance_id, fencing_epoch, configuration_revision,
    executor_configuration_revision, executor_checkout_path,
    executor_start_authority_sha256, executor_start_authority_at,
    executor_start_io_permit_sha256, executor_start_io_permit_at,
    executor_start_receipt_json, executor_start_receipt_sha256,
    executor_start_failure_receipt_json, executor_start_failure_receipt_sha256,
    executor_lifecycle_owner_instance_id, executor_lifecycle_owner_epoch,
    executor_lifecycle_owner_acquired_at, executor_lifecycle_owner_expires_at,
    executor_lifecycle_owner_sha256, executor_stop_pending_json,
    executor_stop_pending_sha256,
    execution_record_sha256, request_sha256, request_json, authenticated_principal,
    claim_request_sha256, claim_response_json, claim_receipt_sha256,
    controller_lifecycle_trust_json, controller_lifecycle_trust_sha256,
    controller_operation_kind, controller_operation_request_sha256,
    controller_operation_trust_sha256, controller_operation_fence_json,
    controller_operation_fence_sha256,
    state, legacy_migrated, offered_at, claimed_at, started_at, heartbeat_at,
    lease_id, lease_expires_at, deadline_at, cancel_requested_at, completed_at,
    workspace_ref, result_json, result_sha256, status_sha256,
    cleanup_settlement_request_sha256, cleanup_completed_at, last_mutation_kind,
    last_mutation_sha256, error, updated_at
    FROM task_board_remote_assignments WHERE assignment_id = ?1";

#[tokio::test]
async fn into_record_reports_archival_before_decoding_an_invalid_phase() {
    let temp = tempdir().expect("model fixture directory");
    let db = AsyncDaemonDb::connect(&temp.path().join("model.sqlite3"))
        .await
        .expect("open daemon db");
    sqlx::query(
        "INSERT INTO task_board_execution_hosts (
             host_id, host_role, configuration_revision, enabled, created_at, updated_at
         ) VALUES ('executor-self', 'executor_self', 1, 1,
                   '2026-07-19T08:00:00Z', '2026-07-19T08:00:00Z')",
    )
    .execute(db.pool())
    .await
    .expect("seed local executor host");
    // A truthful legacy row whose phase would fail the current decoder if it were
    // ever reached. The current typed queries always exclude legacy_migrated = 1,
    // so into_record is the last-line archival fence.
    sqlx::query(
        "INSERT INTO task_board_remote_assignments (
             assignment_id, execution_id, phase, idempotency_key, host_id,
             fencing_epoch, state, legacy_migrated, offered_at, completed_at, updated_at
         ) VALUES ('legacy-bad-phase', 'execution-legacy', 'not-a-real-phase', 'legacy-key',
                   'executor-self', 1, 'superseded', 1, '2026-07-19T08:00:00Z',
                   '2026-07-19T08:00:00Z', '2026-07-19T08:00:00Z')",
    )
    .execute(db.pool())
    .await
    .expect("seed archival row with an undecodable phase");

    // Load the archival row the production filters always exclude. The column
    // order mirrors RemoteAssignmentRow::SELECT_COLLISION so the FromRow decode
    // matches; the static string satisfies the repo's no-dynamic-SQL guard.
    let row = query_as::<_, RemoteAssignmentRow>(SELECT_ARCHIVAL_ROW)
        .bind("legacy-bad-phase")
        .fetch_one(db.pool())
        .await
        .expect("load archival row");

    let error = row
        .into_record()
        .expect_err("an archival row must never decode into a current record");
    assert!(
        error.to_string().contains("archival only"),
        "the archival guard must precede phase decoding; got: {error}"
    );
}
