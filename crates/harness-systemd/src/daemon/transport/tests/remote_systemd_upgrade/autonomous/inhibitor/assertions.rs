use std::any::Any;

use crate::errors::CliError;

use super::*;

pub(super) fn assert_permit_blocker_failure(
    fixture: &UpgradeFixture,
    runner: &ScriptedSystemd<'_>,
    report: &RemoteSystemdUpgradeReport,
) {
    assert_permit_blocker_errors(report);
    assert_permit_blocker_guard(runner);
    assert_permit_blocker_transaction(fixture, runner);
}

fn assert_permit_blocker_errors(report: &RemoteSystemdUpgradeReport) {
    assert_eq!(report.outcome, RemoteSystemdUpgradeOutcome::RollbackFailed);
    assert!(
        report
            .error
            .as_deref()
            .is_some_and(|error| error.contains("runtime systemd start permit remains installed"))
    );
    assert!(
        report
            .rollback_error
            .as_deref()
            .is_some_and(|error| error.contains("not a regular file"))
    );
}

fn assert_permit_blocker_guard(runner: &ScriptedSystemd<'_>) {
    assert_eq!(runner.starts(), 0);
    assert!(runner.inhibitor_installed());
    assert!(!runner.runtime_permit_installed());
    assert!(!runner.runtime_permit_live());
    assert!(runner.runtime_permit_path_exists());
    assert!(!runner.active());
}

fn assert_permit_blocker_transaction(fixture: &UpgradeFixture, runner: &ScriptedSystemd<'_>) {
    assert!(!runner.enabled());
    assert!(runner.recovery_timer_enabled());
    assert!(fixture.operation.store_path.join("armed.json").is_file());
    assert_eq!(database_schema(&fixture.database()), 31);
}

pub(super) fn assert_post_spawn_reload_failure(
    fixture: &UpgradeFixture,
    runner: &ScriptedSystemd<'_>,
    report: &RemoteSystemdUpgradeReport,
) {
    assert_eq!(report.outcome, RemoteSystemdUpgradeOutcome::RollbackFailed);
    assert!(
        report
            .error
            .as_deref()
            .is_some_and(|error| error.contains("post-spawn daemon-reload failure"))
    );
    assert_rollback_guard_remains(fixture, runner);
    assert_eq!(database_schema(&fixture.database()), 31);
    assert_eq!(database_values(&fixture.database()), vec!["before"]);
}

fn assert_rollback_guard_remains(fixture: &UpgradeFixture, runner: &ScriptedSystemd<'_>) {
    assert!(runner.inhibitor_installed());
    assert!(!runner.runtime_permit_path_exists());
    assert!(!runner.active());
    assert!(!runner.enabled());
    assert!(runner.recovery_timer_enabled());
    assert!(fixture.operation.store_path.join("armed.json").is_file());
}

pub(super) fn assert_persistent_spawn_failure(
    fixture: &UpgradeFixture,
    runner: &ScriptedSystemd<'_>,
    report: &RemoteSystemdUpgradeReport,
) {
    assert_persistent_spawn_errors(report);
    assert_rollback_guard_remains(fixture, runner);
    assert_persistent_spawn_data(fixture);
}

fn assert_persistent_spawn_errors(report: &RemoteSystemdUpgradeReport) {
    assert_eq!(report.outcome, RemoteSystemdUpgradeOutcome::RollbackFailed);
    assert!(
        report
            .error
            .as_deref()
            .is_some_and(|error| error.contains("persistent post-spawn daemon-reload failure"))
    );
    assert!(
        report
            .rollback_error
            .as_deref()
            .is_some_and(|error| error.contains("persistent post-spawn daemon-reload failure"))
    );
}

fn assert_persistent_spawn_data(fixture: &UpgradeFixture) {
    assert!(fixture.operation.store_path.join("pending").is_dir());
    assert!(installed_is_candidate(&fixture.binary));
    assert_eq!(
        fs::read_to_string(fixture.state.join("config.json")).expect("candidate config"),
        "candidate\n"
    );
    assert_eq!(database_schema(&fixture.database()), 35);
    assert_eq!(
        database_values(&fixture.database()),
        vec!["before", "candidate"]
    );
}

pub(super) fn assert_persistent_spawn_recovered(
    fixture: &UpgradeFixture,
    runner: &ScriptedSystemd<'_>,
    report: &RemoteSystemdRecoveryReport,
) {
    assert_rollback_service_recovered(fixture, runner, report);
    assert!(!installed_is_candidate(&fixture.binary));
    assert_eq!(
        fs::read_to_string(fixture.state.join("config.json")).expect("restored config"),
        "before\n"
    );
    assert_eq!(database_schema(&fixture.database()), 31);
    assert_eq!(database_values(&fixture.database()), vec!["before"]);
}

fn assert_rollback_service_recovered(
    fixture: &UpgradeFixture,
    runner: &ScriptedSystemd<'_>,
    report: &RemoteSystemdRecoveryReport,
) {
    assert_eq!(report.outcome, RemoteSystemdRecoveryOutcome::RolledBack);
    assert!(!runner.inhibitor_installed());
    assert!(runner.active());
    assert!(runner.enabled());
    assert!(!fixture.operation.store_path.join("armed.json").exists());
}

pub(super) fn assert_final_release_failure(
    fixture: &UpgradeFixture,
    runner: &ScriptedSystemd<'_>,
    error: &CliError,
) {
    assert!(
        error
            .to_string()
            .contains("final inhibitor release reload failure")
    );
    assert_committed_candidate_quiesced(fixture, runner);
    assert!(fixture.operation.store_path.join("armed.json").is_file());
    assert!(fixture.operation.store_path.join("previous").is_dir());
}

fn assert_committed_candidate_quiesced(fixture: &UpgradeFixture, runner: &ScriptedSystemd<'_>) {
    assert!(runner.inhibitor_installed());
    assert!(!runner.active());
    assert!(!runner.enabled());
    assert!(runner.recovery_timer_enabled());
    assert!(installed_is_candidate(&fixture.binary));
    assert_eq!(database_schema(&fixture.database()), 35);
}

pub(super) fn assert_final_release_recovered(
    fixture: &UpgradeFixture,
    runner: &ScriptedSystemd<'_>,
    report: &RemoteSystemdRecoveryReport,
) {
    assert_commit_service_recovered(fixture, runner, report);
    assert_eq!(database_schema(&fixture.database()), 35);
}

pub(super) fn assert_persistent_final_release_failure(
    fixture: &UpgradeFixture,
    runner: &ScriptedSystemd<'_>,
    error: &str,
) {
    assert_persistent_final_release_errors(error);
    assert_persistent_commit_service_guard(runner);
    assert_persistent_commit_transaction_guard(fixture);
    assert_committed_candidate_data(fixture);
}

fn assert_persistent_final_release_errors(error: &str) {
    assert!(error.contains("persistent final inhibitor release reload failure"));
    assert!(
        error
            .matches("persistent final inhibitor release reload failure")
            .count()
            >= 2,
        "both the release and fail-closed reloads must retain their errors: {error}"
    );
}

fn assert_persistent_commit_service_guard(runner: &ScriptedSystemd<'_>) {
    assert!(runner.inhibitor_installed());
    assert!(!runner.runtime_permit_path_exists());
    assert!(!runner.active());
    assert!(!runner.enabled());
    assert!(runner.recovery_timer_enabled());
}

fn assert_persistent_commit_transaction_guard(fixture: &UpgradeFixture) {
    assert!(fixture.operation.store_path.join("armed.json").is_file());
    assert!(!fixture.operation.store_path.join("pending").exists());
    assert!(fixture.operation.store_path.join("previous").is_dir());
}

fn assert_committed_candidate_data(fixture: &UpgradeFixture) {
    assert!(installed_is_candidate(&fixture.binary));
    assert_eq!(
        fs::read_to_string(fixture.state.join("config.json")).expect("committed config"),
        "candidate\n"
    );
    assert_eq!(database_schema(&fixture.database()), 35);
    assert_eq!(
        database_values(&fixture.database()),
        vec!["before", "candidate"]
    );
}

pub(super) fn assert_persistent_final_release_recovered(
    fixture: &UpgradeFixture,
    runner: &ScriptedSystemd<'_>,
    report: &RemoteSystemdRecoveryReport,
) {
    assert_commit_service_recovered(fixture, runner, report);
    assert_committed_candidate_data(fixture);
}

fn assert_commit_service_recovered(
    fixture: &UpgradeFixture,
    runner: &ScriptedSystemd<'_>,
    report: &RemoteSystemdRecoveryReport,
) {
    assert_eq!(
        report.outcome,
        RemoteSystemdRecoveryOutcome::CommitCompleted
    );
    assert!(!runner.inhibitor_installed());
    assert!(runner.active());
    assert!(runner.enabled());
    assert!(!fixture.operation.store_path.join("armed.json").exists());
}

pub(super) fn assert_candidate_health_crash(
    runner: &ScriptedSystemd<'_>,
    crash: &Result<(), Box<dyn Any + Send>>,
) {
    assert!(crash.is_err());
    assert!(runner.active());
    assert!(runner.inhibitor_installed());
}

pub(super) fn assert_recovery_disable_failure(
    fixture: &UpgradeFixture,
    runner: &ScriptedSystemd<'_>,
    error: &str,
) {
    assert_recovery_disable_errors_and_guard(runner, error);
    assert_recovery_disable_transaction(fixture);
}

fn assert_recovery_disable_errors_and_guard(runner: &ScriptedSystemd<'_>, error: &str) {
    assert!(error.contains("persistent post-spawn daemon-reload failure"));
    assert!(error.contains("forced daemon disable failure"));
    assert!(runner.inhibitor_installed());
    assert!(!runner.active());
}

fn assert_recovery_disable_transaction(fixture: &UpgradeFixture) {
    assert!(fixture.operation.store_path.join("armed.json").is_file());
    assert!(fixture.operation.store_path.join("pending").is_dir());
    assert!(installed_is_candidate(&fixture.binary));
    assert_eq!(database_schema(&fixture.database()), 35);
}
