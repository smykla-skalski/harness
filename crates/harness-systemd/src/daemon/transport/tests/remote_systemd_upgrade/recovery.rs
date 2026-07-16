use super::*;
use rusqlite::Connection;

use crate::errors::CliError;

#[test]
fn incomplete_pre_snapshot_staging_is_discarded_before_candidate_validation() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    let pending = fixture.operation.store_path.join("pending");
    fs::create_dir_all(&pending).expect("create incomplete pending generation");
    fs::write(pending.join("candidate"), "partial\n").expect("write partial staging");
    fs::remove_file(&fixture.upgrade_plan.candidate_path).expect("remove retry candidate");

    let error = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect_err("missing retry candidate must fail after safe cleanup");

    assert!(error.to_string().contains("candidate"));
    assert!(!pending.exists());
    assert_eq!(
        fs::read_to_string(&fixture.binary).expect("unchanged installed binary"),
        OLD_BINARY
    );
    assert!(runner.enabled());
    assert_eq!(
        runner.starts(),
        0,
        "active current service needs no restart"
    );
}

#[test]
fn pending_generation_recovers_before_missing_candidate_is_rejected() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    let upgraded = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("successful upgrade");
    assert_initial_upgrade_completed(&fixture, &upgraded);

    let previous = fixture.operation.store_path.join("previous");
    let pending = fixture.operation.store_path.join("pending");
    fs::rename(&previous, &pending).expect("simulate interrupted generation recovery");
    fs::remove_file(&fixture.upgrade_plan.candidate_path).expect("remove retry candidate");

    let error = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect_err("missing candidate must be rejected after recovery");

    assert_pending_generation_recovered(&fixture, &runner, &pending, &error);
}

#[test]
fn previous_old_is_restored_when_previous_is_missing() {
    let fixture = UpgradeFixture::new();
    let previous = fixture.operation.store_path.join("previous");
    let previous_old = fixture.operation.store_path.join(".previous-old");
    fs::create_dir_all(&previous_old).expect("create interrupted previous generation");
    fs::write(previous_old.join("proof"), "recover me\n").expect("write recovery proof");

    reconcile_rotation_state_for_tests(&fixture.operation).expect("reconcile interrupted rotation");

    assert!(!previous_old.exists());
    assert_eq!(
        fs::read_to_string(previous.join("proof")).expect("restored generation proof"),
        "recover me\n"
    );
}

#[test]
fn previous_old_is_discarded_when_previous_is_committed() {
    let fixture = UpgradeFixture::new();
    let previous = fixture.operation.store_path.join("previous");
    let previous_old = fixture.operation.store_path.join(".previous-old");
    fs::create_dir_all(&previous).expect("create committed previous generation");
    fs::write(previous.join("proof"), "committed\n").expect("write committed proof");
    fs::create_dir_all(&previous_old).expect("create stale previous generation");
    fs::write(previous_old.join("proof"), "stale\n").expect("write stale proof");

    reconcile_rotation_state_for_tests(&fixture.operation).expect("discard stale rotation state");

    assert!(!previous_old.exists());
    assert_eq!(
        fs::read_to_string(previous.join("proof")).expect("committed generation proof"),
        "committed\n"
    );
}

#[test]
fn corrupted_retained_binary_is_rejected_before_service_stop() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    let upgraded = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("successful upgrade");
    assert_eq!(upgraded.outcome, RemoteSystemdUpgradeOutcome::Upgraded);
    let starts_before = runner.starts();
    fs::write(
        fixture.operation.store_path.join("previous").join("binary"),
        "corrupt retained binary\n",
    )
    .expect("corrupt retained binary");

    let error = rollback_remote_systemd_with(
        &fixture.operation,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect_err("corrupt retained binary must fail preflight");

    assert!(error.to_string().contains("digest mismatch"));
    assert!(installed_is_candidate(&fixture.binary));
    assert_eq!(database_schema(&fixture.database()), 35);
    assert_eq!(runner.starts(), starts_before, "service must not restart");
    assert!(runner.enabled());
}

#[test]
fn missing_retained_unit_is_rejected_before_service_stop() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("successful upgrade");
    let starts_before = runner.starts();
    fs::remove_file(
        fixture
            .operation
            .store_path
            .join("previous")
            .join("unit.service"),
    )
    .expect("remove retained unit artifact");

    let error = rollback_remote_systemd_with(
        &fixture.operation,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect_err("missing retained unit must fail preflight");

    assert_missing_retained_unit_rejected(&fixture, &runner, starts_before, &error);
    assert_missing_retained_unit_left_no_transaction(&fixture);
}

fn assert_initial_upgrade_completed(fixture: &UpgradeFixture, report: &RemoteSystemdUpgradeReport) {
    assert_eq!(report.outcome, RemoteSystemdUpgradeOutcome::Upgraded);
    assert!(installed_is_candidate(&fixture.binary));
    assert_eq!(database_schema(&fixture.database()), 35);
}

fn assert_pending_generation_recovered(
    fixture: &UpgradeFixture,
    runner: &ScriptedSystemd<'_>,
    pending: &Path,
    error: &CliError,
) {
    assert!(
        error
            .to_string()
            .contains(&fixture.upgrade_plan.candidate_path.display().to_string())
    );
    assert_eq!(
        fs::read_to_string(&fixture.binary).expect("recovered old binary"),
        OLD_BINARY
    );
    assert_eq!(database_schema(&fixture.database()), 31);
    assert_eq!(database_values(&fixture.database()), vec!["before"]);
    assert!(!pending.exists());
    assert_eq!(
        runner.starts(),
        3,
        "upgrade must verify two starts before generation recovery"
    );
}

fn assert_missing_retained_unit_rejected(
    fixture: &UpgradeFixture,
    runner: &ScriptedSystemd<'_>,
    starts_before: u32,
    error: &CliError,
) {
    assert!(
        error
            .to_string()
            .contains("retained unit artifact is missing")
    );
    assert!(installed_is_candidate(&fixture.binary));
    assert_eq!(database_schema(&fixture.database()), 35);
    assert_eq!(runner.starts(), starts_before, "service must not restart");
    assert!(runner.enabled());
}

fn assert_missing_retained_unit_left_no_transaction(fixture: &UpgradeFixture) {
    assert!(!fixture.operation.store_path.join("armed.json").exists());
    assert!(!fixture.operation.store_path.join("pending").exists());
}

#[test]
fn retained_database_foreign_key_violation_is_rejected_before_stop() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("successful upgrade");
    let snapshot_database = fixture
        .operation
        .store_path
        .join("previous")
        .join("state")
        .join("daemon")
        .join("external")
        .join("harness.db");
    Connection::open(snapshot_database)
        .expect("open retained database")
        .execute_batch(
            "PRAGMA foreign_keys=OFF;
             CREATE TABLE parent (id INTEGER PRIMARY KEY);
             CREATE TABLE child (
               id INTEGER PRIMARY KEY,
               parent_id INTEGER REFERENCES parent(id)
             );
             INSERT INTO child (id, parent_id) VALUES (1, 999);",
        )
        .expect("inject foreign-key violation");
    let starts_before = runner.starts();

    let error = rollback_remote_systemd_with(
        &fixture.operation,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect_err("foreign-key violation must fail preflight");

    assert!(error.to_string().contains("foreign_key_check"));
    assert!(installed_is_candidate(&fixture.binary));
    assert_eq!(runner.starts(), starts_before);
    assert!(runner.enabled());
}
