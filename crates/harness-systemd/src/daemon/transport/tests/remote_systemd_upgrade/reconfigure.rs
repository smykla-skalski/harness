use std::cell::Cell;
use std::os::unix::fs::MetadataExt as _;
use std::panic::{AssertUnwindSafe, catch_unwind};

use super::*;
use crate::errors::CliError;
use crate::errors::CliErrorKind;

#[test]
fn same_binary_and_desired_unit_is_a_health_checked_noop() {
    let mut fixture = UpgradeFixture::new();
    use_installed_binary(&fixture);
    let desired = fs::read_to_string(&fixture.unit).expect("current unit");
    fixture.upgrade_plan.desired_unit_contents = Some(desired);
    let runner = ScriptedSystemd::new(&fixture, false);

    let report = run_upgrade(&fixture, &runner).expect("reconfigure no-op");

    assert_eq!(report.outcome, RemoteSystemdUpgradeOutcome::Noop);
    assert!(!report.changed);
    assert_eq!(runner.starts(), 0);
    assert!(!fixture.operation.store_path.join("pending").exists());
}

#[test]
#[expect(
    clippy::cognitive_complexity,
    reason = "assert macros expand to one branch each, so a test that verifies a whole scenario cannot score under the threshold without being split into fragments that prove less"
)]
fn unit_only_reconfigure_commits_without_changing_environment_or_state() {
    let mut fixture = UpgradeFixture::new();
    use_installed_binary(&fixture);
    let before = LiveFiles::capture(&fixture);
    let metadata = fs::metadata(&fixture.unit).expect("unit metadata");
    let desired = desired_notify_unit(&fixture);
    fixture.upgrade_plan.desired_unit_contents = Some(desired.clone());
    let runner = ScriptedSystemd::new(&fixture, false);

    let report = run_upgrade(&fixture, &runner).expect("unit-only reconfigure");

    assert_eq!(report.outcome, RemoteSystemdUpgradeOutcome::Upgraded);
    assert!(report.changed);
    assert_eq!(
        fs::read_to_string(&fixture.unit).expect("desired unit"),
        desired
    );
    assert_eq!(
        fs::read(&fixture.operation.environment_path).expect("environment"),
        before.env
    );
    assert_state_unchanged(&fixture, &before);
    let installed = fs::metadata(&fixture.unit).expect("reconfigured unit metadata");
    assert_eq!(installed.mode(), metadata.mode());
    assert_eq!(installed.uid(), metadata.uid());
    assert_eq!(installed.gid(), metadata.gid());
    assert_eq!(runner.starts(), 1);
}

#[test]
fn failed_unit_activation_restores_exact_unit_environment_and_state() {
    let mut fixture = UpgradeFixture::new();
    use_installed_binary(&fixture);
    let before = LiveFiles::capture(&fixture);
    fixture.upgrade_plan.desired_unit_contents = Some(desired_notify_unit(&fixture));
    let runner = ScriptedSystemd::new(&fixture, false);

    let report = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| {
            if runner.starts() == 1 {
                Err(
                    CliErrorKind::workflow_io("forced reconfigure activation failure".to_string())
                        .into(),
                )
            } else {
                runner.verify(plan, expected, run)
            }
        },
    )
    .expect("rolled-back reconfigure report");

    assert_eq!(report.outcome, RemoteSystemdUpgradeOutcome::RolledBack);
    assert_eq!(fs::read(&fixture.unit).expect("restored unit"), before.unit);
    assert_eq!(
        fs::read(&fixture.operation.environment_path).expect("restored environment"),
        before.env
    );
    assert_state_unchanged(&fixture, &before);
    assert_eq!(runner.starts(), 2);
}

#[test]
#[expect(
    clippy::cognitive_complexity,
    reason = "assert macros expand to one branch each, so a test that verifies a whole scenario cannot score under the threshold without being split into fragments that prove less"
)]
fn committed_recovery_rejects_target_unit_digest_mismatch() {
    let mut fixture = UpgradeFixture::new();
    use_installed_binary(&fixture);
    let before = LiveFiles::capture(&fixture);
    fixture.upgrade_plan.desired_unit_contents = Some(desired_notify_unit(&fixture));
    let runner = ScriptedSystemd::new(&fixture, false);
    runner.set_panic_on_daemon_enable(true);

    let crash = catch_unwind(AssertUnwindSafe(|| {
        let _ = run_upgrade(&fixture, &runner);
    }));
    assert!(crash.is_err(), "expected crash after durable commit");
    let arm: serde_json::Value = serde_json::from_slice(
        &fs::read(fixture.operation.store_path.join("armed.json")).expect("recovery arm"),
    )
    .expect("decode recovery arm");
    assert!(arm["target_unit_sha256"].as_str().is_some());

    runner.set_panic_on_daemon_enable(false);
    let tampered = Cell::new(false);
    let report = recover_remote_systemd_with(
        &fixture.operation.store_path,
        &|args| runner.run(args),
        &|plan, expected, run| {
            if !tampered.replace(true) {
                fs::write(&fixture.unit, &before.unit).expect("tamper started committed unit");
            }
            runner.verify(plan, expected, run)
        },
    )
    .expect("recover mismatched committed unit");

    assert_eq!(report.outcome, RemoteSystemdRecoveryOutcome::RolledBack);
    assert!(report.detail.contains("unit digest mismatch"));
    assert!(tampered.get());
    assert_eq!(fs::read(&fixture.unit).expect("restored unit"), before.unit);
    assert_eq!(
        fs::read(&fixture.operation.environment_path).expect("restored environment"),
        before.env
    );
    assert_state_unchanged(&fixture, &before);
}

#[test]
fn reconfigure_adoption_refuses_an_absent_unit_without_live_file_writes() {
    let fixture = UpgradeFixture::new();
    let before = LiveFiles::capture(&fixture);
    fs::remove_file(&fixture.unit).expect("remove managed unit");
    let runner = ScriptedSystemd::new(&fixture, false);
    let operation = &fixture.operation;
    let locked = LockedLifecycle::acquire(
        operation.transaction_root().expect("transaction root"),
        &operation.unit,
        &operation.store_path,
    )
    .expect("lifecycle lock");
    let mut lifecycle = locked
        .bind(&operation.binary_path, BindMode::InstallOrMatch, &|args| {
            runner.run(args)
        })
        .expect("provisional install claim");

    let error =
        adopt_existing_remote_systemd_unit(operation, &mut lifecycle, &|args| runner.run(args))
            .expect_err("missing managed unit must be refused");

    assert!(error.to_string().contains("systemd unit"));
    assert!(!fixture.unit.exists());
    assert_eq!(
        fs::read(&fixture.operation.environment_path).expect("unchanged environment"),
        before.env
    );
    assert_state_unchanged(&fixture, &before);
    assert!(!fixture.operation.store_path.join("armed.json").exists());
    assert!(!fixture.operation.store_path.join("pending").exists());
}

struct LiveFiles {
    unit: Vec<u8>,
    env: Vec<u8>,
    config: Vec<u8>,
    schema: i64,
    values: Vec<String>,
}

impl LiveFiles {
    fn capture(fixture: &UpgradeFixture) -> Self {
        Self {
            unit: fs::read(&fixture.unit).expect("unit"),
            env: fs::read(&fixture.operation.environment_path).expect("environment"),
            config: fs::read(fixture.state.join("config.json")).expect("state config"),
            schema: database_schema(&fixture.database()),
            values: database_values(&fixture.database()),
        }
    }
}

fn assert_state_unchanged(fixture: &UpgradeFixture, before: &LiveFiles) {
    assert_eq!(
        fs::read(fixture.state.join("config.json")).expect("state config"),
        before.config
    );
    assert_eq!(database_schema(&fixture.database()), before.schema);
    assert_eq!(database_values(&fixture.database()), before.values);
}

fn desired_notify_unit(fixture: &UpgradeFixture) -> String {
    notify_unit_contents_for_tests(
        &fs::read_to_string(&fixture.unit).expect("read current managed unit"),
    )
    .expect("render desired notify unit")
}

fn use_installed_binary(fixture: &UpgradeFixture) {
    fs::copy(&fixture.binary, &fixture.upgrade_plan.candidate_path)
        .expect("use installed binary as candidate");
}

fn run_upgrade(
    fixture: &UpgradeFixture,
    runner: &ScriptedSystemd<'_>,
) -> Result<RemoteSystemdUpgradeReport, CliError> {
    upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
}
