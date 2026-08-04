use super::*;
use harness_daemon::daemon::db::{DaemonDb, DaemonDbOpen};

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
    assert_eq!(
        db.schema_version().expect("schema version"),
        harness_daemon::daemon::db::SCHEMA_VERSION
    );
}

/// `(state, legacy_migrated, action_key, attempt, request_json,
/// executor_configuration_revision, executor_checkout_path, last_mutation_kind,
/// last_mutation_sha256)` from `task_board_remote_assignments`.
type LegacyMigratedAssignmentRow = (
    String,
    i64,
    Option<String>,
    Option<i64>,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<i64>,
    Option<String>,
);

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

    let assignment: LegacyMigratedAssignmentRow = db
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
            [harness_task_board::remote_spki_pin::encode([0x22; 32])],
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
    super::restore_legacy_v40_shape(db.connection());
    db
}

pub(super) fn legacy_v40_fixture_at(path: &std::path::Path) -> DaemonDb {
    let db = DaemonDb::open(path).expect("open daemon db");
    super::restore_legacy_v40_shape(db.connection());
    db
}
