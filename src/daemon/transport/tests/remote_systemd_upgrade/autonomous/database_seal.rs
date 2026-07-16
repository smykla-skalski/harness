use std::cell::Cell;

use rusqlite::Connection;
use serde_json::Value;

use crate::errors::CliErrorKind;

use super::*;

#[test]
fn target_database_seal_is_persisted_before_second_health_check() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);

    let crash = catch_unwind(AssertUnwindSafe(|| {
        let _ = upgrade_remote_systemd_with(
            &fixture.upgrade_plan,
            &|args| runner.run(args),
            &|plan, expected, run| {
                if installed_is_candidate(&fixture.binary) && runner.starts() == 2 {
                    let arm = read_recovery_arm(&fixture);
                    assert_eq!(arm["arm_version"], 2);
                    assert_eq!(arm["phase"], "rollback_ready");
                    assert_eq!(arm["target_database_seal"]["present"], true);
                    assert_eq!(arm["target_database_seal"]["schema"], 35);
                    panic!("simulated crash during sealed target health verification");
                }
                runner.verify(plan, expected, run)
            },
        );
    }));

    assert!(crash.is_err());
    assert_eq!(read_recovery_arm(&fixture)["phase"], "rollback_ready");
    let report = recover_remote_systemd_with(
        &fixture.operation.store_path,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("recover sealed rollback-ready transaction");
    assert_eq!(report.outcome, RemoteSystemdRecoveryOutcome::RolledBack);
    assert_eq!(database_schema(&fixture.database()), 31);
}

#[test]
fn committing_phase_with_pending_generation_rolls_back_before_rotation() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    let crash = catch_unwind(AssertUnwindSafe(|| {
        let _ = upgrade_remote_systemd_with(
            &fixture.upgrade_plan,
            &|args| runner.run(args),
            &|plan, expected, run| {
                if installed_is_candidate(&fixture.binary) && runner.starts() == 2 {
                    panic!("simulated crash before committing phase");
                }
                runner.verify(plan, expected, run)
            },
        );
    }));

    assert!(crash.is_err());
    let pending = fixture.operation.store_path.join("pending");
    fs::remove_file(pending.join("candidate")).expect("remove staged candidate before commit");
    let arm_path = fixture.operation.store_path.join("armed.json");
    let mut arm = read_recovery_arm(&fixture);
    arm["phase"] = Value::String("committing".to_string());
    fs::write(
        &arm_path,
        serde_json::to_vec_pretty(&arm).expect("encode committing arm"),
    )
    .expect("persist simulated committing arm");

    let report = recover_remote_systemd_with(
        &fixture.operation.store_path,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("recover committing transaction before generation rotation");

    assert_eq!(report.outcome, RemoteSystemdRecoveryOutcome::RolledBack);
    assert_eq!(
        fs::read_to_string(&fixture.binary).expect("restored binary"),
        OLD_BINARY
    );
    assert_eq!(database_schema(&fixture.database()), 31);
    assert!(!fixture.operation.store_path.join("armed.json").exists());
}

#[test]
fn committed_database_seal_mismatch_restores_retained_generation_and_keeps_evidence() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    crash_after_generation_commit(&fixture, &runner);
    let transaction_id = read_recovery_arm(&fixture)["transaction_id"]
        .as_str()
        .expect("transaction id")
        .to_string();
    Connection::open(fixture.database())
        .expect("open committed target database")
        .execute(
            "UPDATE schema_meta SET value = '36' WHERE key = 'version'",
            [],
        )
        .expect("invalidate committed target seal");
    runner.set_panic_on_daemon_enable(false);

    let report = recover_remote_systemd_with(
        &fixture.operation.store_path,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("fallback from invalid committed database");

    assert_eq!(report.outcome, RemoteSystemdRecoveryOutcome::RolledBack);
    assert_eq!(
        fs::read_to_string(&fixture.binary).expect("restored binary"),
        OLD_BINARY
    );
    assert_eq!(database_schema(&fixture.database()), 31);
    let failed_database = fixture
        .operation
        .store_path
        .join(format!("failed-current-{transaction_id}"))
        .join("daemon/external/harness.db");
    assert_eq!(database_schema(&failed_database), 36);
    assert!(!fixture.operation.store_path.join("armed.json").exists());
}

#[test]
fn committed_target_health_failure_restores_retained_generation() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    crash_after_generation_commit(&fixture, &runner);
    runner.set_panic_on_daemon_enable(false);

    let report = recover_remote_systemd_with(
        &fixture.operation.store_path,
        &|args| runner.run(args),
        &|plan, expected, run| {
            if installed_is_candidate(&fixture.binary) {
                Err(
                    CliErrorKind::workflow_io("forced committed target health failure".to_string())
                        .into(),
                )
            } else {
                runner.verify(plan, expected, run)
            }
        },
    )
    .expect("fallback from committed target health failure");

    assert_eq!(report.outcome, RemoteSystemdRecoveryOutcome::RolledBack);
    assert_eq!(
        fs::read_to_string(&fixture.binary).expect("restored binary"),
        OLD_BINARY
    );
    assert_eq!(database_schema(&fixture.database()), 31);
    assert!(report.detail.contains("committed target health failure"));
    assert!(!fixture.operation.store_path.join("armed.json").exists());
}

#[test]
fn committed_explicit_rollback_failure_restores_the_displaced_generation() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("upgrade before explicit rollback");
    runner.set_panic_on_daemon_enable(true);

    let crash = catch_unwind(AssertUnwindSafe(|| {
        let _ = rollback_remote_systemd_with(
            &fixture.operation,
            &|args| runner.run(args),
            &|plan, expected, run| runner.verify(plan, expected, run),
        );
    }));

    assert!(crash.is_err());
    let arm = read_recovery_arm(&fixture);
    assert_eq!(arm["operation"], "rollback");
    assert_eq!(arm["phase"], "committing");
    let transaction_id = arm["transaction_id"]
        .as_str()
        .expect("rollback transaction id")
        .to_string();
    Connection::open(fixture.database())
        .expect("open committed rollback database")
        .execute(
            "UPDATE schema_meta SET value = '32' WHERE key = 'version'",
            [],
        )
        .expect("invalidate committed rollback seal");
    runner.set_panic_on_daemon_enable(false);

    let report = recover_remote_systemd_with(
        &fixture.operation.store_path,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("restore displaced generation after rollback target failure");

    assert_eq!(report.outcome, RemoteSystemdRecoveryOutcome::RolledBack);
    assert!(installed_is_candidate(&fixture.binary));
    assert_eq!(database_schema(&fixture.database()), 35);
    let failed_database = fixture
        .operation
        .store_path
        .join(format!("failed-current-{transaction_id}"))
        .join("daemon/external/harness.db");
    assert_eq!(database_schema(&failed_database), 32);
    assert!(!fixture.operation.store_path.join("armed.json").exists());
}

#[test]
fn failed_committed_fallback_stays_committing_and_retries_after_evidence_is_repaired() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    crash_after_generation_commit(&fixture, &runner);
    runner.set_panic_on_daemon_enable(false);
    let retained_binary = fixture.operation.store_path.join("previous").join("binary");
    let retained_contents = fs::read(&retained_binary).expect("retained binary contents");
    let corrupt_once = Cell::new(true);
    let run_systemctl = |args: &[String]| runner.run(args);
    let error = recover_remote_systemd_with(
        &fixture.operation.store_path,
        &run_systemctl,
        &|plan, expected, run| {
            if installed_is_candidate(&fixture.binary) {
                if corrupt_once.replace(false) {
                    fs::write(&retained_binary, "corrupt rollback evidence\n")
                        .expect("corrupt rollback evidence after preflight");
                }
                Err(
                    CliErrorKind::workflow_io("forced committed target health failure".to_string())
                        .into(),
                )
            } else {
                runner.verify(plan, expected, run)
            }
        },
    )
    .expect_err("corrupt fallback evidence must keep recovery armed");

    assert!(error.to_string().contains("digest mismatch"));
    assert_eq!(read_recovery_arm(&fixture)["phase"], "committing");
    assert!(runner.inhibitor_installed());
    assert!(!runner.enabled());
    fs::write(&retained_binary, retained_contents).expect("repair retained binary");

    let report = recover_remote_systemd_with(
        &fixture.operation.store_path,
        &run_systemctl,
        &|plan, expected, run| {
            if installed_is_candidate(&fixture.binary) {
                Err(
                    CliErrorKind::workflow_io("forced committed target health failure".to_string())
                        .into(),
                )
            } else {
                runner.verify(plan, expected, run)
            }
        },
    )
    .expect("retry committed fallback");

    assert_eq!(report.outcome, RemoteSystemdRecoveryOutcome::RolledBack);
    assert_eq!(
        fs::read_to_string(&fixture.binary).expect("restored binary"),
        OLD_BINARY
    );
    assert_eq!(database_schema(&fixture.database()), 31);
    assert!(!fixture.operation.store_path.join("armed.json").exists());
}

fn crash_after_generation_commit(fixture: &UpgradeFixture, runner: &ScriptedSystemd<'_>) {
    runner.set_panic_on_daemon_enable(true);
    let crash = catch_unwind(AssertUnwindSafe(|| {
        let _ = upgrade_remote_systemd_with(
            &fixture.upgrade_plan,
            &|args| runner.run(args),
            &|plan, expected, run| runner.verify(plan, expected, run),
        );
    }));

    assert!(crash.is_err());
    assert_eq!(read_recovery_arm(fixture)["phase"], "committing");
    assert!(fixture.operation.store_path.join("previous").is_dir());
    assert!(!fixture.operation.store_path.join("pending").exists());
}

fn read_recovery_arm(fixture: &UpgradeFixture) -> Value {
    let bytes =
        fs::read(fixture.operation.store_path.join("armed.json")).expect("read recovery arm");
    serde_json::from_slice(&bytes).expect("decode recovery arm")
}
