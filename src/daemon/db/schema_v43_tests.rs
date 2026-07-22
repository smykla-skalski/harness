use super::*;
use crate::daemon::db::DaemonDb;
use rusqlite::params;

const HOST_ID: &str = "executor-a";
const SPKI_PIN: &str = "sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

#[path = "schema_v43_strict_fixture.rs"]
mod strict_fixture;

pub(super) use strict_fixture::{insert_strict_assignment, strict_request};

#[test]
fn fresh_schema_includes_v43_remote_execution_evidence() {
    let db = DaemonDb::open_in_memory().expect("open fresh daemon db");

    let columns: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('task_board_remote_assignments')
             WHERE name IN ('executor_configuration_revision', 'executor_checkout_path')",
            [],
            |row| row.get(0),
        )
        .expect("inspect fresh remote assignment schema");

    assert_eq!(columns, 2);
    let dispatch_columns: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM pragma_table_info('task_board_dispatch_intents')
             WHERE name IN ('start_admission_outcome', 'start_admission_settings_revision')",
            [],
            |row| row.get(0),
        )
        .expect("inspect fresh dispatch schema");
    assert_eq!(dispatch_columns, 2);
    let abandonment_columns: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*)
             FROM pragma_table_info('task_board_remote_source_bundle_abandonments')
             WHERE name IN (
                 'verified_absence_checked_at', 'verified_absence_json',
                 'request_json', 'response_json'
             )",
            [],
            |row| row.get(0),
        )
        .expect("inspect durable source abandonment authority schema");
    assert_eq!(abandonment_columns, 4);
    assert_eq!(db.schema_version().expect("schema version"), "43");
}

#[test]
fn migration_supersedes_legacy_rows_and_sources_trust_from_settings() {
    let db = legacy_v40_fixture();

    run(db.connection()).expect("migrate strict remote execution ledger");

    assert_eq!(db.schema_version().expect("schema version"), "43");
    let host: (String, String, String, String, i64, i64, Option<String>) = db
        .connection()
        .query_row(
            "SELECT host_role, configured_endpoint, configured_leaf_sha256,
                    configured_credential_reference, configuration_revision,
                    enabled, observed_host_instance_id
             FROM task_board_execution_hosts WHERE host_id = ?1",
            [HOST_ID],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                ))
            },
        )
        .expect("read migrated host");
    assert_eq!(
        host,
        (
            "controller_remote".into(),
            "https://executor.example.test".into(),
            SPKI_PIN.into(),
            "env://HARNESS_REMOTE_TOKEN".into(),
            7,
            1,
            None,
        )
    );

    let assignment: (
        String,
        i64,
        Option<String>,
        Option<i64>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<i64>,
        Option<String>,
    ) = db
        .connection()
        .query_row(
            "SELECT state, legacy_migrated, action_key, attempt, request_json,
                    executor_configuration_revision, executor_checkout_path,
                    last_mutation_kind, last_mutation_sha256
             FROM task_board_remote_assignments WHERE assignment_id = 'legacy-assignment'",
            [],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                    row.get(7)?,
                    row.get(8)?,
                ))
            },
        )
        .expect("read migrated assignment");
    assert_eq!(
        assignment,
        (
            "superseded".into(),
            1,
            None,
            None,
            None,
            None,
            None,
            None,
            None
        )
    );
    let obsolete_index: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'index'
               AND name = 'task_board_remote_assignments_one_active_phase'",
            [],
            |row| row.get(0),
        )
        .expect("count obsolete index");
    assert_eq!(obsolete_index, 0);
}

#[test]
fn migration_refuses_unconfigured_legacy_trust_anchor_without_mutation() {
    let db = legacy_v40_fixture();
    db.connection()
        .execute(
            "UPDATE task_board_orchestrator_settings
             SET settings_json = json_set(
                 settings_json,
                 '$.execution_hosts[0].certificate_fingerprint',
                 ?1
             )",
            [crate::task_board::remote_spki_pin::encode([0x22; 32])],
        )
        .expect("change operator pin");

    let error = run(db.connection()).expect_err("untrusted legacy row must fail closed");

    assert!(error.to_string().contains("operator-owned trust anchors"));
    assert_eq!(db.schema_version().expect("schema version"), "42");
    let endpoint: String = db
        .connection()
        .query_row(
            "SELECT endpoint FROM task_board_execution_hosts WHERE host_id = ?1",
            [HOST_ID],
            |row| row.get(0),
        )
        .expect("legacy host remains");
    assert_eq!(endpoint, "https://executor.example.test");
}

#[test]
fn host_observation_requires_signed_heartbeat_and_controller_receipt() {
    let db = legacy_v40_fixture();
    run(db.connection()).expect("migrate strict remote execution ledger");
    db.connection()
        .execute(
            "UPDATE task_board_execution_hosts
             SET observed_host_instance_id = 'instance-a',
                 observed_protocol_version = 1,
                 observed_capabilities_json = '[\"implementation_write\"]',
                 observed_repositories_json = '[\"acme/widgets\"]',
                 observed_runtimes_json = '[\"codex\"]',
                 observed_capacity = 2,
                 observed_active_assignments = 0,
                 observed_state = 'healthy',
                 observed_heartbeat_at = '2026-07-19T09:00:00Z',
                 observed_received_at = '2026-07-19T09:00:01Z',
                 advertisement_sha256 =
                     'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
             WHERE host_id = ?1",
            [HOST_ID],
        )
        .expect("record authenticated observation");

    let evidence: (String, String) = db
        .connection()
        .query_row(
            "SELECT observed_heartbeat_at, observed_received_at
             FROM task_board_execution_hosts WHERE host_id = ?1",
            [HOST_ID],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("read liveness evidence");
    assert_eq!(
        evidence,
        ("2026-07-19T09:00:00Z".into(), "2026-07-19T09:00:01Z".into())
    );

    let error = db
        .connection()
        .execute(
            "UPDATE task_board_execution_hosts SET observed_received_at = NULL
             WHERE host_id = ?1",
            [HOST_ID],
        )
        .expect_err("partial observation must fail closed");
    assert!(error.to_string().contains("CHECK constraint failed"));
}

#[test]
fn repair_restores_missing_index_but_refuses_malformed_table() {
    let db = legacy_v40_fixture();
    run(db.connection()).expect("migrate strict remote execution ledger");
    db.connection()
        .execute("DROP INDEX task_board_remote_assignments_active_host", [])
        .expect("drop repairable index");

    run(db.connection()).expect("repair missing index");
    let repaired: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'index' AND name = 'task_board_remote_assignments_active_host'",
            [],
            |row| row.get(0),
        )
        .expect("count repaired index");
    assert_eq!(repaired, 1);
    let active_index_sql: String = db
        .connection()
        .query_row(
            "SELECT sql FROM sqlite_master
             WHERE type = 'index' AND name = 'task_board_remote_assignments_active_host'",
            [],
            |row| row.get(0),
        )
        .expect("read repaired active-host index");
    assert!(
        active_index_sql.contains("'unknown'"),
        "ambiguous assignments must continue consuming host capacity"
    );

    db.connection()
        .execute_batch(
            "ALTER TABLE task_board_remote_assignments
                 ADD COLUMN sentinel TEXT NOT NULL DEFAULT 'keep';",
        )
        .expect("malform current table");
    let error = run(db.connection()).expect_err("malformed table must not be replaced");
    assert!(error.to_string().contains("refusing destructive repair"));
    let sentinel: String = db
        .connection()
        .query_row(
            "SELECT sentinel FROM task_board_remote_assignments
             WHERE assignment_id = 'legacy-assignment'",
            [],
            |row| row.get(0),
        )
        .expect("preserve sentinel row");
    assert_eq!(sentinel, "keep");
}

pub(super) fn legacy_v40_fixture() -> DaemonDb {
    let db = DaemonDb::open_in_memory().expect("open daemon db");
    restore_legacy_v40_shape(&db);
    db
}

pub(super) fn legacy_v40_fixture_at(path: &std::path::Path) -> DaemonDb {
    let db = DaemonDb::open(path).expect("open daemon db");
    restore_legacy_v40_shape(&db);
    db
}

pub(super) fn restore_legacy_v40_shape(db: &DaemonDb) {
    db.connection()
        .execute_batch(
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
    db.connection()
        .execute_batch(
            crate::daemon::db::schema_repairs_remote_execution::LEGACY_DISPATCH_TABLE_SQL,
        )
        .expect("restore v40 dispatch shape");
    crate::daemon::db::schema_repairs_admission::repair_and_stamp(db.connection())
        .expect("restore v40 admission shape");
    // Stamp v42 (not v40): this db already ran v43/v42, so their task_board_items
    // column additions must not re-run. The remote tables stay v40-era precursor
    // shapes for the v43 repair path to detect.
    db.connection()
        .execute(
            "UPDATE schema_meta SET value = '42' WHERE key = 'version'",
            [],
        )
        .expect("stamp remote-execution precursor fixture");
    seed_settings_host(db);
    seed_workflow_execution(db);
    db.connection()
        .execute(
            "INSERT INTO task_board_execution_hosts (
                 host_id, endpoint, certificate_fingerprint, credential_reference,
                 protocol_version, capabilities_json, repositories_json, capacity,
                 active_assignments, state, heartbeat_at, updated_at
             ) VALUES (?1, 'https://executor.example.test', ?2,
                       'env://HARNESS_REMOTE_TOKEN', 1, '[\"report_read_only\"]',
                       '[\"acme/widgets\"]', 2, 1, 'healthy',
                       '2026-07-19T08:00:00Z', '2026-07-19T08:00:00Z')",
            params![HOST_ID, SPKI_PIN],
        )
        .expect("seed legacy host");
    db.connection()
        .execute(
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

fn seed_settings_host(db: &DaemonDb) {
    let settings = format!(
        r#"{{"execution_hosts":[{{"host_id":"{HOST_ID}","endpoint":"https://executor.example.test","certificate_fingerprint":"{SPKI_PIN}","credential_reference":"env://HARNESS_REMOTE_TOKEN","enabled":true}}]}}"#
    );
    db.connection()
        .execute(
            "UPDATE task_board_orchestrator_settings
             SET settings_json = ?1, revision = 7, updated_at = '2026-07-19T07:59:00Z'
             WHERE singleton = 1",
            [settings],
        )
        .expect("seed configured host");
}

fn seed_workflow_execution(db: &DaemonDb) {
    db.connection()
        .execute(
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
    db.connection()
        .execute(
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
