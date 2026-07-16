use std::any::Any;

use super::*;

pub(super) fn assert_partial_arm_cleaned(fixture: &UpgradeFixture, runner: &ScriptedSystemd<'_>) {
    assert_partial_arm_files_absent(fixture);
    assert_partial_arm_service_state(fixture, runner);
}

fn assert_partial_arm_files_absent(fixture: &UpgradeFixture) {
    assert!(!fixture.operation.store_path.join("armed.json").exists());
    assert!(
        !fixture
            .operation
            .store_path
            .join("recovery-controller")
            .exists()
    );
    assert!(
        !fixture
            .unit
            .with_file_name("harness-remote-harness-recovery.service")
            .exists()
    );
    assert!(
        !fixture
            .unit
            .with_file_name("harness-remote-harness-recovery.timer")
            .exists()
    );
}

fn assert_partial_arm_service_state(fixture: &UpgradeFixture, runner: &ScriptedSystemd<'_>) {
    assert!(runner.enabled());
    assert!(!runner.recovery_timer_enabled());
    assert_eq!(runner.starts(), 0);
    assert_eq!(
        fs::read_to_string(&fixture.binary).expect("old binary"),
        OLD_BINARY
    );
}

pub(super) fn assert_successful_finish(
    fixture: &UpgradeFixture,
    runner: &ScriptedSystemd<'_>,
    report: &RemoteSystemdUpgradeReport,
) {
    assert_successful_finish_transaction(fixture, report);
    assert_successful_finish_service(fixture, runner);
}

fn assert_successful_finish_transaction(
    fixture: &UpgradeFixture,
    report: &RemoteSystemdUpgradeReport,
) {
    assert_eq!(report.outcome, RemoteSystemdUpgradeOutcome::Upgraded);
    assert!(!fixture.operation.store_path.join("armed.json").exists());
    assert!(!fixture.operation.store_path.join("pending").exists());
    assert!(fixture.operation.store_path.join("previous").exists());
}

fn assert_successful_finish_service(fixture: &UpgradeFixture, runner: &ScriptedSystemd<'_>) {
    assert!(installed_is_candidate(&fixture.binary));
    assert_eq!(database_schema(&fixture.database()), 35);
    assert!(runner.enabled());
    assert!(runner.recovery_timer_enabled());
}

pub(super) fn assert_coordinator_crash_state(
    fixture: &UpgradeFixture,
    runner: &ScriptedSystemd<'_>,
    crash: &Result<(), Box<dyn Any + Send>>,
) {
    assert!(crash.is_err());
    assert!(installed_is_candidate(&fixture.binary));
    assert_eq!(database_schema(&fixture.database()), 35);
    assert!(!runner.enabled());
    assert!(runner.recovery_timer_enabled());
}

pub(super) fn assert_rolled_back_state(
    fixture: &UpgradeFixture,
    runner: &ScriptedSystemd<'_>,
    report: &RemoteSystemdRecoveryReport,
) {
    assert_rolled_back_data(fixture, report);
    assert_rolled_back_service(fixture, runner);
}

fn assert_rolled_back_data(fixture: &UpgradeFixture, report: &RemoteSystemdRecoveryReport) {
    assert_eq!(report.outcome, RemoteSystemdRecoveryOutcome::RolledBack);
    assert_eq!(
        fs::read_to_string(&fixture.binary).expect("restored binary"),
        OLD_BINARY
    );
    assert_eq!(database_schema(&fixture.database()), 31);
    assert_eq!(database_values(&fixture.database()), vec!["before"]);
}

fn assert_rolled_back_service(fixture: &UpgradeFixture, runner: &ScriptedSystemd<'_>) {
    assert!(runner.enabled());
    assert!(runner.recovery_timer_enabled());
    assert!(!fixture.operation.store_path.join("armed.json").exists());
}

pub(super) fn assert_rollback_evidence_before_restart(
    fixture: &UpgradeFixture,
    crash: &Result<(), Box<dyn Any + Send>>,
    arm: &str,
    failed_evidence_exists: bool,
) {
    assert!(crash.is_err());
    assert!(arm.contains("\"phase\": \"rollback_finalizing\""));
    assert!(!fixture.operation.store_path.join("pending").exists());
    assert!(
        failed_evidence_exists,
        "rollback evidence must move before the restored service starts"
    );
}

pub(super) fn assert_committed_crash_state(
    fixture: &UpgradeFixture,
    runner: &ScriptedSystemd<'_>,
    crash: &Result<(), Box<dyn Any + Send>>,
) {
    assert!(crash.is_err());
    assert!(!fixture.operation.store_path.join("pending").exists());
    assert!(fixture.operation.store_path.join("previous").is_dir());
    assert!(installed_is_candidate(&fixture.binary));
    assert!(!runner.enabled());
    assert!(runner.recovery_timer_enabled());
}

pub(super) fn assert_commit_completed(
    fixture: &UpgradeFixture,
    runner: &ScriptedSystemd<'_>,
    report: &RemoteSystemdRecoveryReport,
) {
    assert_eq!(
        report.outcome,
        RemoteSystemdRecoveryOutcome::CommitCompleted
    );
    assert!(installed_is_candidate(&fixture.binary));
    assert_eq!(database_schema(&fixture.database()), 35);
    assert!(runner.enabled());
    assert!(runner.recovery_timer_enabled());
}
