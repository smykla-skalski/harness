use std::fs;
use std::os::unix::fs::{MetadataExt as _, symlink};
use std::path::{Path, PathBuf};

use clap::Parser;

use super::super::remote::DaemonRemoteCommand;
use super::super::remote_systemd_lifecycle::RemoteSystemdCommandOutput;
use super::super::remote_systemd_upgrade_lifecycle::{
    LockedLifecycle, RemoteSystemdArtifact, RemoteSystemdHealthReport, RemoteSystemdOperationPlan,
    RemoteSystemdRecoveryOutcome, RemoteSystemdRecoveryReport, RemoteSystemdRollbackReport,
    RemoteSystemdUpgradeOutcome, RemoteSystemdUpgradeReport, acquire_with_trusted_controller,
    atomic_copy_temp_prefix_for_tests, notify_unit_contents_for_tests,
    parse_systemd_observation_for_tests, reconcile_restore_debris_for_tests,
    reconcile_rotation_state_for_tests, recover_remote_systemd_with,
    release_restore_capacity_for_tests, render_recovery_units_for_tests,
    required_restore_capacity_for_tests, required_restore_inodes_for_tests,
    reserve_bidirectional_restore_capacity_for_tests,
    reserve_inode_capacity_with_available_for_tests, restart_stability_behavior_for_tests,
    restore_state_tree_for_tests, restore_state_tree_retaining_current_for_tests,
    rollback_remote_systemd_with, snapshot_generation_for_tests, snapshot_state_tree_for_tests,
    stability_reset_sequence_for_tests, upgrade_remote_systemd_with,
};

#[path = "remote_systemd_upgrade/autonomous.rs"]
mod autonomous;
#[path = "remote_systemd_upgrade/capacity.rs"]
mod capacity;
#[path = "remote_systemd_upgrade/hardening.rs"]
mod hardening;
#[path = "remote_systemd_upgrade/locking.rs"]
mod locking;
#[path = "remote_systemd_upgrade/ownership.rs"]
mod ownership;
#[path = "remote_systemd_upgrade/recovery.rs"]
mod recovery;
#[path = "remote_systemd_upgrade/support.rs"]
mod support;

use support::*;

#[derive(Debug, Parser)]
struct DaemonRemoteCommandTestHarness {
    #[command(subcommand)]
    command: DaemonRemoteCommand,
}

#[test]
fn daemon_remote_systemd_upgrade_and_rollback_parse() {
    let upgrade = DaemonRemoteCommandTestHarness::try_parse_from([
        "test",
        "upgrade-systemd",
        "--unit",
        "harness-remote",
        "--candidate-path",
        "/tmp/harness-47",
        "--binary-path",
        "/usr/local/bin/harness-daemon",
        "--readiness-timeout-seconds",
        "90",
        "--json",
    ])
    .expect("parse upgrade-systemd")
    .command;
    let DaemonRemoteCommand::UpgradeSystemd(args) = upgrade else {
        panic!("expected upgrade-systemd");
    };
    assert_eq!(args.systemd.unit, "harness-remote");
    assert_eq!(args.candidate_path, Some(PathBuf::from("/tmp/harness-47")));
    assert_eq!(args.readiness_timeout_seconds, 90);
    assert!(args.json);

    let rollback = DaemonRemoteCommandTestHarness::try_parse_from([
        "test",
        "rollback-systemd",
        "--unit",
        "harness-remote",
        "--confirm-data-loss",
        "--json",
    ])
    .expect("parse rollback-systemd")
    .command;
    let DaemonRemoteCommand::RollbackSystemd(args) = rollback else {
        panic!("expected rollback-systemd");
    };
    assert!(args.confirm_data_loss);
    assert!(args.json);
}

#[test]
fn same_digest_upgrade_is_a_health_checked_noop() {
    let fixture = UpgradeFixture::new();
    fs::write(
        &fixture.unit,
        format!(
            "[Service]\nType=notify\nNotifyAccess=main\nTimeoutStartSec=20min\nKillMode=control-group\nEnvironmentFile={}\nEnvironment=HARNESS_DAEMON_DATA_HOME=%S/harness-remote\nEnvironment=XDG_DATA_HOME=%S/harness-remote\nEnvironment=HARNESS_DAEMON_OWNERSHIP=external\nExecStart={} remote serve\nDynamicUser=yes\nStateDirectory=harness-remote\nStateDirectoryMode=0700\n",
            fixture.operation.environment_path.display(),
            fixture.binary.display()
        ),
    )
    .expect("write notify unit");
    fs::copy(&fixture.binary, &fixture.upgrade_plan.candidate_path)
        .expect("replace candidate with installed binary");
    let runner = ScriptedSystemd::new(&fixture, false);

    let report = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("health-checked no-op");

    assert_eq!(report.outcome, RemoteSystemdUpgradeOutcome::Noop);
    assert!(!report.changed);
    assert_eq!(report.health.expect("no-op health").status, "ready");
    assert_eq!(runner.starts(), 0, "no-op must not restart the service");
    assert!(!fixture.operation.store_path.join("pending").exists());
}

#[test]
fn same_digest_legacy_unit_uses_transaction_and_rolls_back_to_simple() {
    let fixture = UpgradeFixture::new();
    fs::copy(&fixture.binary, &fixture.upgrade_plan.candidate_path)
        .expect("use identical candidate binary");
    let runner = ScriptedSystemd::new(&fixture, false);

    let upgraded = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("transactional readiness migration");

    assert_readiness_migration_upgraded(&fixture, &upgraded);

    let rolled_back = rollback_remote_systemd_with(
        &fixture.operation,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("rollback readiness migration");

    assert_readiness_migration_rolled_back(&fixture, &rolled_back);
}

#[test]
fn failed_upgrade_restores_binary_database_and_all_harness_state() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, true);

    let report = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("upgrade transaction report");

    assert_failed_upgrade_restored(&fixture, &runner, &report);
}

#[test]
fn explicit_rollback_restores_retained_database_generation_and_is_reversible() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    let upgraded = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("successful upgrade");
    assert_explicit_rollback_upgrade(&fixture, &upgraded);

    let rolled_back = rollback_remote_systemd_with(
        &fixture.operation,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("explicit rollback");

    assert_explicit_rollback_restored(&fixture, &runner, &rolled_back);
    assert_recovery_controller(&fixture);

    let restored_candidate = rollback_remote_systemd_with(
        &fixture.operation,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("reverse explicit rollback");

    assert_reverse_explicit_rollback(&fixture, &runner, &restored_candidate);
}

fn assert_readiness_migration_upgraded(
    fixture: &UpgradeFixture,
    report: &RemoteSystemdUpgradeReport,
) {
    assert_eq!(report.outcome, RemoteSystemdUpgradeOutcome::Upgraded);
    assert!(report.changed);
    assert!(
        fs::read_to_string(&fixture.unit)
            .expect("notify unit")
            .contains("Type=notify")
    );
    assert_eq!(database_values(&fixture.database()), vec!["before"]);
    assert!(fixture.operation.store_path.join("previous").is_dir());
}

fn assert_readiness_migration_rolled_back(
    fixture: &UpgradeFixture,
    report: &RemoteSystemdRollbackReport,
) {
    assert_eq!(report.outcome, RemoteSystemdUpgradeOutcome::RolledBack);
    assert!(
        fs::read_to_string(&fixture.unit)
            .expect("restored legacy unit")
            .contains("Type=simple")
    );
}

fn assert_failed_upgrade_restored(
    fixture: &UpgradeFixture,
    runner: &ScriptedSystemd<'_>,
    report: &RemoteSystemdUpgradeReport,
) {
    assert_eq!(report.outcome, RemoteSystemdUpgradeOutcome::RolledBack);
    assert_eq!(
        fs::read_to_string(&fixture.binary).expect("old binary"),
        OLD_BINARY
    );
    assert_eq!(database_schema(&fixture.database()), 31);
    assert_eq!(database_values(&fixture.database()), vec!["before"]);
    assert_eq!(
        fs::read_to_string(fixture.state.join("config.json")).expect("restored config"),
        "before\n"
    );
    assert_failed_upgrade_files(fixture, runner);
    let failed_state = report
        .failed_state_path
        .as_ref()
        .expect("candidate state retained as evidence");
    assert_failed_state_evidence(failed_state);
}

fn assert_failed_upgrade_files(fixture: &UpgradeFixture, runner: &ScriptedSystemd<'_>) {
    assert!(!sidecar(&fixture.database(), "-wal").exists());
    assert!(!sidecar(&fixture.database(), "-shm").exists());
    assert!(
        fs::read_to_string(&fixture.unit)
            .expect("restored unit")
            .contains("Type=simple")
    );
    assert_eq!(runner.starts(), 2, "candidate and restored service started");
}

fn assert_failed_state_evidence(failed_state: &Path) {
    let metadata = fs::symlink_metadata(failed_state).expect("evidence metadata");
    assert_eq!(metadata.mode() & 0o777, 0o700);
    assert_eq!(metadata.uid(), uzers::get_current_uid());
    assert_eq!(metadata.gid(), uzers::get_current_gid());
    assert_eq!(
        database_schema(&failed_state.join("daemon/external/harness.db")),
        35
    );
}

fn assert_explicit_rollback_upgrade(fixture: &UpgradeFixture, report: &RemoteSystemdUpgradeReport) {
    assert_eq!(report.outcome, RemoteSystemdUpgradeOutcome::Upgraded);
    assert_eq!(database_schema(&fixture.database()), 35);
    assert_eq!(
        database_values(&fixture.database()),
        vec!["before", "candidate"]
    );
}

fn assert_explicit_rollback_restored(
    fixture: &UpgradeFixture,
    runner: &ScriptedSystemd<'_>,
    report: &RemoteSystemdRollbackReport,
) {
    assert_eq!(report.outcome, RemoteSystemdUpgradeOutcome::RolledBack);
    assert_eq!(
        fs::read_to_string(&fixture.binary).expect("old binary"),
        OLD_BINARY
    );
    assert_eq!(database_schema(&fixture.database()), 31);
    assert_eq!(database_values(&fixture.database()), vec!["before"]);
    assert_eq!(
        runner.starts(),
        4,
        "upgrade and explicit rollback must each verify two starts"
    );
    assert!(fixture.operation.store_path.join("previous").is_dir());
}

fn assert_recovery_controller(fixture: &UpgradeFixture) {
    assert_eq!(
        fs::read_to_string(fixture.operation.store_path.join("recovery-controller"))
            .expect("rollback recovery controller"),
        CONTROLLER_BINARY
    );
}

fn assert_reverse_explicit_rollback(
    fixture: &UpgradeFixture,
    runner: &ScriptedSystemd<'_>,
    report: &RemoteSystemdRollbackReport,
) {
    assert_eq!(report.outcome, RemoteSystemdUpgradeOutcome::RolledBack);
    assert!(installed_is_candidate(&fixture.binary));
    assert_eq!(database_schema(&fixture.database()), 35);
    assert_eq!(
        database_values(&fixture.database()),
        vec!["before", "candidate"]
    );
    assert_eq!(
        runner.starts(),
        6,
        "reverse explicit rollback must also verify two starts"
    );
    assert!(fixture.operation.store_path.join("previous").is_dir());
}

#[test]
fn explicit_rollback_snapshot_failure_restarts_current_generation() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    let upgraded = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("successful upgrade");
    assert_eq!(upgraded.outcome, RemoteSystemdUpgradeOutcome::Upgraded);
    symlink(
        fixture.state.join("config.json"),
        fixture.state.join("unsupported-link"),
    )
    .expect("create unsupported state symlink");

    let error = rollback_remote_systemd_with(
        &fixture.operation,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect_err("rollback snapshot must reject state symlinks");

    assert!(
        error
            .to_string()
            .contains("snapshot current systemd generation before rollback")
    );
    assert!(installed_is_candidate(&fixture.binary));
    assert_eq!(database_schema(&fixture.database()), 35);
    assert_eq!(
        runner.starts(),
        3,
        "upgrade must verify two starts before the recovery restart"
    );
    assert!(!fixture.operation.store_path.join("pending").exists());
}
