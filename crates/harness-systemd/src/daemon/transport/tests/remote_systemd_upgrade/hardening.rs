use super::*;
use crate::errors::{CliError, CliErrorKind};
use std::os::unix::fs::PermissionsExt as _;

#[test]
fn systemd_upgrade_adds_notify_readiness_to_legacy_unit() {
    let upgraded = notify_unit_contents_for_tests(
        "[Service]\nType=simple\nExecStart=/usr/local/bin/harness-daemon remote serve\n",
    )
    .expect("upgrade legacy unit");

    assert!(upgraded.contains("Type=notify\n"));
    assert!(upgraded.contains("NotifyAccess=main\n"));
    assert!(upgraded.contains("TimeoutStartSec=20min\n"));
    assert!(upgraded.contains("KillMode=control-group\n"));
    assert!(!upgraded.contains("Type=simple"));
}

#[test]
fn systemd_upgrade_normalizes_only_service_readiness_with_crlf() {
    let upgraded = notify_unit_contents_for_tests(
        "[Unit]\r\nType=simple\r\n[Service]\r\nType=notify\r\nNotifyAccess=all\r\nExecStart=/bin/true\r\n[Install]\r\nWantedBy=multi-user.target\r\n",
    )
    .expect("normalize CRLF service section");

    assert!(upgraded.contains("[Unit]\r\nType=simple\r\n"));
    assert!(upgraded.contains("[Service]\r\nType=notify\r\nNotifyAccess=main\r\n"));
    assert!(upgraded.contains("TimeoutStartSec=20min\r\n"));
    assert!(!upgraded.contains("NotifyAccess=all"));
}

#[test]
fn systemd_upgrade_normalizes_timeout_and_removes_duplicates() {
    let upgraded = notify_unit_contents_for_tests(
        "[Service]\nType=notify\nTimeoutStartSec=30s\nNotifyAccess=main\nTimeoutStartSec=2min\nExecStart=/bin/true\n",
    )
    .expect("normalize readiness timeout");

    assert_eq!(upgraded.matches("TimeoutStartSec=20min").count(), 1);
    assert!(!upgraded.contains("TimeoutStartSec=30s"));
    assert!(!upgraded.contains("TimeoutStartSec=2min"));
}

#[test]
fn systemd_upgrade_rejects_repeated_service_sections() {
    let error = notify_unit_contents_for_tests(
        "[Service]\nType=notify\nNotifyAccess=main\nTimeoutStartSec=20min\n[Service]\nType=simple\n",
    )
    .expect_err("repeated service sections must fail closed");

    assert!(error.to_string().contains("exactly one [Service] section"));
}

#[test]
fn systemd_health_observation_parses_named_properties() {
    assert_eq!(
        parse_systemd_observation_for_tests(
            "SubState=running\nNRestarts=0\nActiveState=active\nMainPID=4321\n"
        )
        .expect("parse observation"),
        ("active".to_string(), "running".to_string(), 4321, 0)
    );
}

#[test]
fn systemd_health_stability_resets_when_main_pid_changes() {
    assert_eq!(stability_reset_sequence_for_tests(), (true, false, true));
}

#[test]
fn systemd_health_accepts_historical_restarts_and_resets_on_new_restart() {
    assert_eq!(
        restart_stability_behavior_for_tests(),
        (true, true, false, true)
    );
}

#[test]
fn inactive_upgrade_refuses_before_transaction_artifacts_are_written() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    runner.set_active(false);
    let original_unit = fs::read(&fixture.unit).expect("read original unit");

    let error = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect_err("inactive service must fail preflight");

    assert!(error.to_string().contains("must be active"));
    assert!(!fixture.operation.store_path.join("pending").exists());
    assert!(!fixture.operation.store_path.join("armed.json").exists());
    assert!(
        !fixture
            .operation
            .store_path
            .join("recovery-controller")
            .exists()
    );
    assert_eq!(
        fs::read(&fixture.unit).expect("unchanged unit"),
        original_unit
    );
    assert_eq!(
        fs::read_to_string(&fixture.binary).expect("old binary"),
        OLD_BINARY
    );
}

#[test]
fn untrusted_candidate_coordinator_is_rejected_before_store_mutation() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    let mut plan = fixture.upgrade_plan.clone();
    plan.operation.controller_path = plan.candidate_path.clone();

    let error = upgrade_remote_systemd_with(
        &plan,
        &|args| runner.run(args),
        &|operation, expected, run| runner.verify(operation, expected, run),
    )
    .expect_err("candidate must not coordinate its own privileged upgrade");

    assert!(error.to_string().contains("controller digest"));
    assert!(!fixture.operation.store_path.join("pending").exists());
    assert_eq!(runner.starts(), 0);
}

#[test]
fn controller_is_reverified_after_lifecycle_lock_acquisition() {
    let fixture = UpgradeFixture::new();
    let replacement = "#!/bin/sh\necho 'harness replacement'\n";
    let operation = fixture.operation.clone();

    let error = acquire_with_trusted_controller(&operation, || {
        fs::write(&fixture.controller, replacement)
            .expect("replace controller during lifecycle lock acquisition");
        Ok(())
    })
    .expect_err("changed controller must invalidate the waiting coordinator");

    assert!(error.to_string().contains("controller digest"));
}

#[test]
fn stale_rollback_coordinator_is_rejected_before_generation_mutation() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|operation, expected, run| runner.verify(operation, expected, run),
    )
    .expect("successful upgrade");
    let stale_controller = fixture.binary.with_file_name("stale-rollback-controller");
    fs::copy(
        fixture.operation.store_path.join("previous").join("binary"),
        &stale_controller,
    )
    .expect("copy stale rollback controller outside transaction storage");
    let mut operation = fixture.operation.clone();
    operation.controller_path = stale_controller;

    let error = rollback_remote_systemd_with(
        &operation,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect_err("stale binary must not coordinate privileged rollback");

    assert!(error.to_string().contains("controller digest"));
    assert!(installed_is_candidate(&fixture.binary));
    assert_eq!(database_schema(&fixture.database()), 35);
    assert!(!operation.store_path.join("pending").exists());
    assert!(operation.store_path.join("previous").exists());
}

#[test]
fn running_binary_mismatch_is_rejected_before_service_stop() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);

    let error = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|_operation, _expected, _run| {
            Err(CliErrorKind::workflow_io(
                "running executable digest differs from installed binary".to_string(),
            )
            .into())
        },
    )
    .expect_err("running/installed generation mismatch must fail closed");

    assert!(error.to_string().contains("running executable digest"));
    assert_eq!(
        fs::read_to_string(&fixture.binary).expect("binary"),
        OLD_BINARY
    );
    assert!(!fixture.operation.store_path.join("pending").exists());
    assert!(!fixture.operation.store_path.join("armed.json").exists());
    assert_eq!(runner.starts(), 0);
}

#[test]
fn managed_unit_drift_is_rejected_before_stop_or_transaction_writes() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    let drifted = fs::read_to_string(&fixture.unit)
        .expect("read unit")
        .replace(
            "StateDirectory=harness-remote",
            "StateDirectory=unmanaged-state",
        );
    fs::write(&fixture.unit, &drifted).expect("write drifted unit");

    let error = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect_err("managed unit drift must fail closed");

    assert_unit_drift_rejected_without_mutation(&fixture, &runner, &error);
    assert_unit_drift_files_preserved(&fixture, &drifted);
}

fn assert_unit_drift_rejected_without_mutation(
    fixture: &UpgradeFixture,
    runner: &ScriptedSystemd<'_>,
    error: &CliError,
) {
    assert!(error.to_string().contains("StateDirectory=harness-remote"));
    assert_eq!(runner.starts(), 0);
    assert!(runner.enabled());
    assert!(!fixture.operation.store_path.join("pending").exists());
    assert!(!fixture.operation.store_path.join("armed.json").exists());
}

fn assert_unit_drift_files_preserved(fixture: &UpgradeFixture, drifted: &str) {
    assert_eq!(
        fs::read_to_string(&fixture.unit).expect("drift remains"),
        drifted
    );
    assert_eq!(
        fs::read_to_string(&fixture.binary).expect("old binary"),
        OLD_BINARY
    );
}

#[test]
fn protected_environment_override_is_rejected_before_stop() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    fs::write(
        &fixture.operation.environment_path,
        "RUST_LOG=harness=info\n  HARNESS_DAEMON_DATA_HOME=/tmp/redirected\n",
    )
    .expect("write redirected environment");

    let error = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect_err("protected environment override must fail closed");

    assert!(error.to_string().contains("protected variable"));
    assert_eq!(runner.starts(), 0);
    assert!(runner.enabled());
    assert!(!fixture.operation.store_path.join("armed.json").exists());
}

#[test]
fn persistent_inhibitor_blocks_external_start_before_stopped_state_mutation() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    runner.set_attempt_external_start_on_inhibit(true);

    let report = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("upgrade with inhibited external start");

    assert_eq!(report.outcome, RemoteSystemdUpgradeOutcome::Upgraded);
    assert!(runner.blocked_external_starts() >= 1);
    assert!(installed_is_candidate(&fixture.binary));
    assert_eq!(database_schema(&fixture.database()), 35);
}

#[test]
fn effective_unit_drop_ins_are_rejected_before_stop() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    runner.set_drop_in_paths("/etc/systemd/system/harness-remote.service.d/override.conf");

    let error = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect_err("effective drop-in override must fail closed");

    assert!(error.to_string().contains("unexpected drop-ins"));
    assert_eq!(runner.starts(), 0);
    assert!(!fixture.operation.store_path.join("pending").exists());
    assert!(!fixture.operation.store_path.join("armed.json").exists());
}

#[test]
fn snapshot_rejects_a_copied_binary_that_does_not_match_the_artifact() {
    let fixture = UpgradeFixture::new();
    let pending = fixture.operation.store_path.join("snapshot-test");
    fs::create_dir_all(&pending).expect("create snapshot destination");
    let mismatched = RemoteSystemdArtifact {
        version: "46.0.2".to_string(),
        sha256: "0".repeat(64),
        binary_path: fixture.binary.clone(),
    };

    let error = snapshot_generation_for_tests(&fixture.operation, &pending, &mismatched)
        .expect_err("snapshot digest mismatch must fail");

    assert!(
        error
            .to_string()
            .contains("copied rollback generation binary")
    );
    assert!(error.to_string().contains("digest mismatch"));
    assert!(!pending.join("manifest.json").exists());
}

#[test]
fn failed_state_staging_leaves_current_database_and_sidecars_untouched() {
    let temp = tempfile::tempdir().expect("tempdir");
    let source = temp.path().join("retained");
    let destination = temp.path().join("current");
    let source_database = source.join("daemon/external/harness.db");
    let current_database = destination.join("daemon/external/harness.db");
    fs::create_dir_all(source_database.parent().expect("source parent"))
        .expect("create source state");
    fs::create_dir_all(current_database.parent().expect("destination parent"))
        .expect("create current state");
    fs::write(&source_database, "retained database").expect("write retained database");
    symlink("missing-target", source.join("zz-broken-link"))
        .expect("create invalid retained entry");
    fs::write(&current_database, "current database").expect("write current database");
    fs::write(sidecar(&current_database, "-wal"), "current wal").expect("write current wal");
    fs::write(sidecar(&current_database, "-shm"), "current shm").expect("write current shm");

    let error = restore_state_tree_for_tests(&source, &destination, true)
        .expect_err("retained symlink must fail staging");

    assert!(error.to_string().contains("symbolic link"));
    assert_eq!(
        fs::read_to_string(&current_database).expect("current database survives"),
        "current database"
    );
    assert_eq!(
        fs::read_to_string(sidecar(&current_database, "-wal")).expect("current wal survives"),
        "current wal"
    );
    assert_eq!(
        fs::read_to_string(sidecar(&current_database, "-shm")).expect("current shm survives"),
        "current shm"
    );
    assert!(
        fs::read_dir(temp.path())
            .expect("restore parent entries")
            .filter_map(Result::ok)
            .all(|entry| {
                !entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".harness-restore-")
            }),
        "failed recovery attempts must remove partial staging trees"
    );
}

#[test]
fn snapshot_rejects_broken_symlink_and_restore_displaces_untrusted_destination() {
    let temp = tempfile::tempdir().expect("tempdir");
    let broken_source = temp.path().join("broken-source");
    let snapshot = temp.path().join("snapshot");
    symlink("missing-source", &broken_source).expect("create broken source symlink");

    let snapshot_error = snapshot_state_tree_for_tests(&broken_source, &snapshot)
        .expect_err("broken snapshot source must fail closed");
    assert!(
        snapshot_error
            .to_string()
            .contains("not a regular directory")
    );
    assert!(!snapshot.exists());

    let broken_destination = temp.path().join("broken-destination");
    symlink("missing-destination", &broken_destination).expect("create broken destination symlink");
    restore_state_tree_for_tests(&snapshot, &broken_destination, false)
        .expect("untrusted live destination is displaced without following it");
    assert!(
        fs::symlink_metadata(&broken_destination).is_err(),
        "absent retained state leaves no live destination"
    );
}

#[test]
fn snapshot_skips_only_sidecars_next_to_the_managed_database() {
    let temp = tempfile::tempdir().expect("tempdir");
    let source = temp.path().join("state");
    let snapshot = temp.path().join("snapshot");
    let database_parent = source.join("daemon").join("external");
    let unrelated = source.join("unrelated").join("harness.db-wal");
    fs::create_dir_all(&database_parent).expect("create database parent");
    fs::create_dir_all(unrelated.parent().expect("unrelated parent"))
        .expect("create unrelated parent");
    fs::write(database_parent.join("harness.db-wal"), "managed sidecar\n")
        .expect("write managed sidecar");
    fs::write(&unrelated, "unrelated state\n").expect("write unrelated state");

    snapshot_state_tree_for_tests(&source, &snapshot).expect("snapshot state");

    assert!(!snapshot.join("daemon/external/harness.db-wal").exists());
    assert_eq!(
        fs::read_to_string(snapshot.join("unrelated/harness.db-wal"))
            .expect("unrelated state preserved"),
        "unrelated state\n"
    );
}

#[test]
fn operation_plan_rejects_state_store_overlap_and_unnormalized_paths() {
    let fixture = UpgradeFixture::new();
    let mut plan = fixture.operation.clone();
    plan.environment_path = plan.state_path.join("managed.env");
    assert!(
        plan.validate()
            .expect_err("environment inside state must fail")
            .to_string()
            .contains("outside StateDirectory")
    );

    let mut plan = fixture.operation.clone();
    plan.store_path = plan.state_path.join("transaction-store");
    assert!(
        plan.validate()
            .expect_err("store inside state must fail")
            .to_string()
            .contains("must not overlap")
    );

    let mut plan = fixture.operation;
    plan.binary_path = PathBuf::from("/usr/local/bin/../harness");
    assert!(
        plan.validate()
            .expect_err("parent components must fail")
            .to_string()
            .contains("normalized")
    );
}

#[test]
fn retry_normalizes_retained_failed_state_before_finishing_restore() {
    let temp = tempfile::tempdir().expect("tempdir");
    let source = temp.path().join("previous-state");
    let destination = temp.path().join("live-state");
    let retained = temp.path().join("failed-current");
    fs::create_dir_all(&source).expect("create previous state");
    fs::create_dir_all(&retained).expect("create retained state");
    fs::write(source.join("generation"), "previous\n").expect("write previous state");
    fs::write(retained.join("generation"), "failed\n").expect("write failed state");
    fs::set_permissions(&retained, fs::Permissions::from_mode(0o755))
        .expect("make interrupted evidence public");

    restore_state_tree_retaining_current_for_tests(&source, &destination, true, &retained)
        .expect("retry interrupted retained-state restore");

    assert_eq!(
        fs::read_to_string(destination.join("generation")).expect("restored generation"),
        "previous\n"
    );
    assert_eq!(
        fs::read_to_string(retained.join("generation")).expect("retained generation"),
        "failed\n"
    );
    let metadata = fs::symlink_metadata(&retained).expect("retained metadata");
    assert_eq!(metadata.mode() & 0o777, 0o700);
    assert_eq!(metadata.uid(), uzers::get_current_uid());
    assert_eq!(metadata.gid(), uzers::get_current_gid());
}
