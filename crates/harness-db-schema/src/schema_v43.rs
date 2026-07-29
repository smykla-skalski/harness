use rusqlite::Connection;

use super::CliError;

/// # Errors
/// Returns [`CliError`] on SQL failures.
pub fn run(conn: &Connection) -> Result<(), CliError> {
    if super::schema_repairs_admission::shape_needs_repair(conn)? {
        super::schema_repairs_admission::repair_and_stamp(conn)?;
    }
    super::schema_repairs_remote_execution::repair_and_stamp(conn)
}

// `pub`, not `pub(crate)`, and gated on `test-support` alongside `test`:
// `harness-daemon`'s own `db/tests/` migration-repair suite restores this
// legacy shape to exercise the v43 upgrade path, and that suite runs under
// `harness-daemon`'s own test build, a different crate's test compilation
// from this one's. The fixture lives here rather than in `schema_v43_tests`
// because it only touches `rusqlite::Connection`, so it stays reachable
// under the `test-support` feature without needing this crate's
// test-only dev-dependencies (`tempfile`, `sqlx`, `harness-daemon`) to
// build.
#[cfg(any(test, feature = "test-support"))]
pub fn restore_legacy_v40_for_test(conn: &Connection) {
    restore_legacy_v40_shape(conn);
}

#[cfg(any(test, feature = "test-support"))]
pub(crate) const HOST_ID: &str = "executor-a";
#[cfg(any(test, feature = "test-support"))]
pub(crate) const SPKI_PIN: &str = "sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

#[cfg(any(test, feature = "test-support"))]
pub(crate) fn restore_legacy_v40_shape(conn: &Connection) {
    conn.execute_batch(
        "DROP TABLE task_board_dispatch_admission_ledger;
         DROP TABLE task_board_dispatch_admission_decisions;
         DROP TABLE task_board_dispatch_intents;
         DROP TABLE task_board_remote_recovery_quarantine;
         DROP TABLE task_board_remote_result_imports;
         DROP TABLE task_board_remote_source_bundle_abandonments;
         DROP TABLE task_board_remote_artifacts;
         DROP TABLE task_board_remote_outbound_sources;
         DROP TABLE task_board_remote_source_bundles;
         DROP TABLE task_board_remote_settlement_receipts;
         DROP TABLE task_board_remote_offer_receipts;
         DROP TABLE task_board_remote_host_quarantines;
         DROP TABLE task_board_remote_assignments;
         DROP TABLE task_board_execution_hosts;
         CREATE TABLE task_board_execution_hosts (
             host_id TEXT PRIMARY KEY, endpoint TEXT NOT NULL,
             certificate_fingerprint TEXT NOT NULL,
             credential_reference TEXT NOT NULL, protocol_version INTEGER NOT NULL,
             capabilities_json TEXT NOT NULL, repositories_json TEXT NOT NULL,
             capacity INTEGER NOT NULL, active_assignments INTEGER NOT NULL DEFAULT 0,
             state TEXT NOT NULL, heartbeat_at TEXT NOT NULL, updated_at TEXT NOT NULL
         ) WITHOUT ROWID;
         CREATE TABLE task_board_remote_assignments (
             assignment_id TEXT PRIMARY KEY,
             execution_id TEXT NOT NULL REFERENCES task_board_workflow_executions(execution_id)
                 ON DELETE CASCADE,
             phase TEXT NOT NULL,
             host_id TEXT NOT NULL REFERENCES task_board_execution_hosts(host_id),
             idempotency_key TEXT NOT NULL UNIQUE, fencing_epoch INTEGER NOT NULL,
             state TEXT NOT NULL, offered_at TEXT NOT NULL, acknowledged_at TEXT,
             started_at TEXT, heartbeat_at TEXT, completed_at TEXT,
             result_json TEXT, error TEXT
         ) WITHOUT ROWID;
         CREATE UNIQUE INDEX task_board_remote_assignments_one_active_phase
             ON task_board_remote_assignments(execution_id, phase)
             WHERE state IN ('offered', 'claimed', 'started', 'running', 'unknown');",
    )
    .expect("restore v40 remote shape");
    conn.execute_batch(crate::schema_repairs_remote_execution::LEGACY_DISPATCH_TABLE_SQL)
        .expect("restore v40 dispatch shape");
    crate::schema_repairs_admission::repair_and_stamp(conn).expect("restore v40 admission shape");
    // Stamp v42 (not v40): this db already ran v43/v42, so their task_board_items
    // column additions must not re-run. The remote tables stay v40-era precursor
    // shapes for the v43 repair path to detect.
    conn.execute(
        "UPDATE schema_meta SET value = '42' WHERE key = 'version'",
        [],
    )
    .expect("stamp remote-execution precursor fixture");
    seed_settings_host(conn);
    seed_workflow_execution(conn);
    conn.execute(
        "INSERT INTO task_board_execution_hosts (
             host_id, endpoint, certificate_fingerprint, credential_reference,
             protocol_version, capabilities_json, repositories_json, capacity,
             active_assignments, state, heartbeat_at, updated_at
         ) VALUES (?1, 'https://executor.example.test', ?2,
                   'env://HARNESS_REMOTE_TOKEN', 1, '[\"report_read_only\"]',
                   '[\"acme/widgets\"]', 2, 1, 'healthy',
                   '2026-07-19T08:00:00Z', '2026-07-19T08:00:00Z')",
        rusqlite::params![HOST_ID, SPKI_PIN],
    )
    .expect("seed legacy host");
    conn.execute(
        "INSERT INTO task_board_remote_assignments (
             assignment_id, execution_id, phase, host_id, idempotency_key,
             fencing_epoch, state, offered_at, acknowledged_at, started_at,
             heartbeat_at, completed_at, result_json, error
         ) VALUES (
             'legacy-assignment', 'execution-a', 'planning', ?1,
             'legacy-idempotency', 1, 'offered', '2026-07-19T08:01:00Z',
             '2026-07-19T08:02:00Z', '2026-07-19T08:03:00Z',
             '2026-07-19T08:04:00Z', '2026-07-19T08:05:00Z',
             '{\"legacy_result\":\"legacy-result-a\"}', 'legacy-error-a'
         ), (
             'legacy-nullable-assignment', 'execution-a', 'reviewing', ?1,
             'legacy-nullable-idempotency', 2, 'offered',
             '2026-07-19T08:06:00Z', NULL, NULL, NULL, NULL, NULL, NULL
         )",
        [HOST_ID],
    )
    .expect("seed legacy assignment");
}

#[cfg(any(test, feature = "test-support"))]
fn seed_settings_host(conn: &Connection) {
    let settings = format!(
        r#"{{"execution_hosts":[{{"host_id":"{HOST_ID}","endpoint":"https://executor.example.test","certificate_fingerprint":"{SPKI_PIN}","credential_reference":"env://HARNESS_REMOTE_TOKEN","enabled":true}}]}}"#
    );
    conn.execute(
        "UPDATE task_board_orchestrator_settings
         SET settings_json = ?1, revision = 7, updated_at = '2026-07-19T07:59:00Z'
         WHERE singleton = 1",
        [settings],
    )
    .expect("seed configured host");
}

#[cfg(any(test, feature = "test-support"))]
fn seed_workflow_execution(conn: &Connection) {
    conn.execute(
        "INSERT INTO task_board_items (
             item_id, schema_version, title, body, status, priority, tags_json,
             project_id, target_project_types_json, agent_mode, imported_from_provider,
             planning_json, workflow_json, session_id, work_item_id, usage_json,
             created_at, updated_at, deleted_at, revision, workflow_kind
         ) VALUES (
             'item-a', 1, 'Remote test', '', 'in_progress', 'medium', '[]',
             NULL, '[]', 'headless', NULL, '{}', '{}', NULL, NULL, '{}',
             '2026-07-19T07:00:00Z', '2026-07-19T07:00:00Z', NULL, 1,
             'default_task'
         )",
        [],
    )
    .expect("seed workflow item");
    conn.execute(
        "INSERT INTO task_board_workflow_executions (
             execution_id, item_id, workflow_kind, phase, state, item_revision,
             configuration_revision, provider_revision, snapshot_json,
             resolved_reviewer_json, host_id, fencing_epoch, available_at,
             blocked_reason, diagnostics_json, resource_ownership_json,
             created_at, updated_at, completed_at
         ) VALUES (
             'execution-a', 'item-a', 'default_task', 'planning', 'pending', 1, 7,
             NULL, '{}', '{}', NULL, 0, NULL, NULL, '{}', '{}',
             '2026-07-19T07:00:00Z', '2026-07-19T07:00:00Z', NULL
         )",
        [],
    )
    .expect("seed workflow execution");
}

#[cfg(test)]
#[path = "schema_v43_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "schema_v43_strict_tests.rs"]
mod strict_tests;

#[cfg(test)]
#[path = "schema_v43_replay_tests.rs"]
mod replay_tests;

#[cfg(test)]
#[path = "schema_v43_rejection_tests.rs"]
mod offer_receipt_tests;

#[cfg(test)]
#[path = "schema_v43_dispatch_tests.rs"]
mod dispatch_tests;

#[cfg(test)]
#[path = "schema_v43_partial_tests.rs"]
mod partial_tests;

#[cfg(test)]
#[path = "schema_v43_admission_shape_tests.rs"]
mod admission_shape_tests;

#[cfg(test)]
#[path = "schema_v43_settlement_tests.rs"]
mod settlement_tests;

#[cfg(test)]
#[path = "schema_v43_controller_operation_tests.rs"]
mod controller_operation_tests;

#[cfg(test)]
#[path = "schema_v43_receipt_test_support.rs"]
mod receipt_test_support;

#[cfg(test)]
#[path = "schema_v43_legacy_preservation_tests.rs"]
mod legacy_preservation_tests;

#[cfg(test)]
#[path = "schema_v43_precursor_tests.rs"]
mod precursor_tests;

#[cfg(test)]
#[path = "schema_v43_legacy_target_tests.rs"]
mod legacy_target_tests;

#[cfg(test)]
#[path = "schema_v43_handoff_tests.rs"]
mod handoff_tests;

#[cfg(test)]
#[path = "schema_v43_result_import_tests.rs"]
mod result_import_tests;

#[cfg(test)]
#[path = "schema_v43_legacy_pin_tests.rs"]
mod legacy_pin_tests;

#[cfg(test)]
#[path = "schema_v43_restart_tests.rs"]
mod restart_tests;

#[cfg(test)]
#[path = "schema_v43_tombstone_tests.rs"]
mod tombstone_tests;
