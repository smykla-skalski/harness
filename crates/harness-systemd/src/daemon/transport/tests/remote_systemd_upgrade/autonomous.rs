use std::panic::{AssertUnwindSafe, catch_unwind};

use super::*;

#[path = "autonomous/assertions.rs"]
mod assertions;
#[path = "autonomous/database_seal.rs"]
mod database_seal;
#[path = "autonomous/inhibitor.rs"]
mod inhibitor;

use assertions::{
    assert_commit_completed, assert_committed_crash_state, assert_coordinator_crash_state,
    assert_partial_arm_cleaned, assert_rollback_evidence_before_restart, assert_rolled_back_state,
    assert_successful_finish,
};

#[test]
fn recovery_units_repeat_and_treat_the_operation_lock_as_deferred_success() {
    let fixture = UpgradeFixture::new();
    let (service, timer) = render_recovery_units_for_tests(&fixture.operation);

    assert!(service.contains("ConditionPathExists="));
    assert!(service.contains(" recover --store-path"));
    assert!(service.contains("SuccessExitStatus=75"));
    assert!(timer.contains("OnBootSec=1s"));
    assert!(timer.contains("OnUnitInactiveSec=5s"));
    assert!(timer.contains("WantedBy=timers.target"));
}

#[test]
fn successful_upgrade_disarms_with_the_idle_recovery_timer_still_enabled() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);

    let report = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("successful autonomous upgrade");

    assert_eq!(report.outcome, RemoteSystemdUpgradeOutcome::Upgraded);
    assert!(runner.armed_before_disable());
    assert!(runner.enabled());
    assert!(runner.recovery_timer_enabled());
    assert!(!fixture.operation.store_path.join("armed.json").exists());
    assert_eq!(
        fs::read_to_string(fixture.operation.store_path.join("recovery-controller"))
            .expect("trusted recovery controller"),
        CONTROLLER_BINARY,
        "deployment candidate must never become the recovery controller"
    );
}

#[test]
fn daemon_reload_failure_before_arm_cleans_partial_recovery_material() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    runner.fail_next_daemon_reload();

    let error = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect_err("daemon reload failure must abort before arming");

    assert!(error.to_string().contains("forced daemon-reload failure"));
    assert_partial_arm_cleaned(&fixture, &runner);
}

#[test]
fn timer_enable_failure_before_arm_cleans_partial_recovery_material() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    runner.set_fail_timer_enable(true);

    let error = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect_err("timer enable failure must abort before arming");

    assert!(error.to_string().contains("recovery timer enable failure"));
    assert_partial_arm_cleaned(&fixture, &runner);
}

#[test]
fn successful_finish_never_disables_the_persistent_recovery_timer() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    runner.set_fail_timer_disable(true);

    let report = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("persistent recovery timer must not be disabled during finish");

    assert_successful_finish(&fixture, &runner, &report);
}

#[test]
fn coordinator_crash_after_candidate_migration_is_automatically_rolled_back() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);

    let crash = catch_unwind(AssertUnwindSafe(|| {
        let _ = upgrade_remote_systemd_with(
            &fixture.upgrade_plan,
            &|args| runner.run(args),
            &|plan, expected, run| {
                assert!(
                    !installed_is_candidate(&fixture.binary),
                    "simulated coordinator SIGKILL after candidate start"
                );
                runner.verify(plan, expected, run)
            },
        );
    }));
    assert_coordinator_crash_state(&fixture, &runner, &crash);

    let report = recover_remote_systemd_with(
        &fixture.operation.store_path,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("automatic recovery");

    assert_rolled_back_state(&fixture, &runner, &report);
}

#[test]
fn privileged_upgrade_never_executes_candidate_for_version_metadata() {
    let fixture = UpgradeFixture::new();
    let execution_marker = fixture.operation.store_path.join("candidate-executed");
    write_executable(
        &fixture.upgrade_plan.candidate_path,
        &format!(
            "#!/bin/sh\n# harness 47.0.1\ntouch {}\nsetsid sh -c 'sleep 30' &\nsleep 30\n",
            execution_marker.display()
        ),
    );
    let runner = ScriptedSystemd::new(&fixture, false);

    let report = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("candidate metadata must not require execution");

    assert_eq!(report.outcome, RemoteSystemdUpgradeOutcome::Upgraded);
    assert!(!execution_marker.exists());
    assert!(
        fs::read_to_string(&fixture.binary)
            .expect("installed candidate")
            .contains("candidate-executed")
    );
    assert_eq!(database_schema(&fixture.database()), 35);
    assert!(runner.enabled());
    assert!(runner.recovery_timer_enabled());
}

#[test]
fn rollback_evidence_is_moved_after_terminal_phase_and_before_old_restart() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, true);
    runner.set_panic_on_old_start(true);

    let crash = catch_unwind(AssertUnwindSafe(|| {
        let _ = upgrade_remote_systemd_with(
            &fixture.upgrade_plan,
            &|args| runner.run(args),
            &|plan, expected, run| runner.verify(plan, expected, run),
        );
    }));

    let arm = fs::read_to_string(fixture.operation.store_path.join("armed.json"))
        .expect("durable recovery arm");
    let failed_evidence_exists = fs::read_dir(&fixture.operation.store_path)
        .expect("transaction entries")
        .filter_map(Result::ok)
        .any(|entry| entry.file_name().to_string_lossy().starts_with("failed-"));
    assert_rollback_evidence_before_restart(&fixture, &crash, &arm, failed_evidence_exists);

    runner.set_panic_on_old_start(false);
    let report = recover_remote_systemd_with(
        &fixture.operation.store_path,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("terminal rollback recovery");

    assert_rolled_back_state(&fixture, &runner, &report);
}

#[test]
fn snapshot_and_restart_failure_remains_armed_for_timer_retry() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    runner.set_fail_old_health(true);
    symlink(
        fixture.state.join("config.json"),
        fixture.state.join("unsupported-link"),
    )
    .expect("create unsupported snapshot entry");

    let error = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect_err("snapshot and recovery health failure must remain armed");

    assert!(
        error
            .to_string()
            .contains("snapshot systemd rollback generation")
    );
    assert!(
        error
            .to_string()
            .contains("restored-generation health failure")
    );
    assert_retry_remains_armed(&fixture, &runner);
}

#[test]
fn partial_stop_and_restart_failure_remains_armed_for_timer_retry() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    runner.set_fail_stop_after_inactive(true);
    runner.set_fail_old_health(true);

    let error = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect_err("partial stop and recovery health failure must remain armed");

    assert!(error.to_string().contains("forced stop failure"));
    assert!(
        error
            .to_string()
            .contains("restored-generation health failure")
    );
    assert_retry_remains_armed(&fixture, &runner);
}

fn assert_retry_remains_armed(fixture: &UpgradeFixture, runner: &ScriptedSystemd<'_>) {
    assert!(fixture.operation.store_path.join("pending").exists());
    assert!(fixture.operation.store_path.join("armed.json").exists());
    assert!(runner.recovery_timer_enabled());
    assert!(!runner.enabled());
    assert_eq!(
        fs::read_to_string(&fixture.binary).expect("installed old binary"),
        OLD_BINARY
    );
}

#[test]
fn crash_after_generation_commit_finishes_candidate_enablement_without_rollback() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    runner.set_panic_on_daemon_enable(true);

    let crash = catch_unwind(AssertUnwindSafe(|| {
        let _ = upgrade_remote_systemd_with(
            &fixture.upgrade_plan,
            &|args| runner.run(args),
            &|plan, expected, run| runner.verify(plan, expected, run),
        );
    }));
    assert_committed_crash_state(&fixture, &runner, &crash);

    runner.set_panic_on_daemon_enable(false);
    let report = recover_remote_systemd_with(
        &fixture.operation.store_path,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("finish committed candidate");

    assert_commit_completed(&fixture, &runner, &report);
}

#[test]
fn committed_recovery_fails_closed_when_retained_generation_is_corrupt() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    runner.set_panic_on_daemon_enable(true);

    let crash = catch_unwind(AssertUnwindSafe(|| {
        let _ = upgrade_remote_systemd_with(
            &fixture.upgrade_plan,
            &|args| runner.run(args),
            &|plan, expected, run| runner.verify(plan, expected, run),
        );
    }));
    assert!(crash.is_err());
    fs::remove_file(
        fixture
            .operation
            .store_path
            .join("previous")
            .join("unit.service"),
    )
    .expect("remove committed rollback unit");
    runner.set_panic_on_daemon_enable(false);

    let error = recover_remote_systemd_with(
        &fixture.operation.store_path,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect_err("corrupt committed recovery evidence must fail closed");

    assert!(
        error
            .to_string()
            .contains("retained unit artifact is missing")
    );
    assert!(installed_is_candidate(&fixture.binary));
    assert!(!runner.enabled());
    assert!(runner.recovery_timer_enabled());
    assert!(fixture.operation.store_path.join("armed.json").exists());
}

#[test]
fn corrupt_pending_recovery_fails_closed_and_keeps_evidence_armed() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    runner.set_panic_on_candidate_health(true);
    let crash = catch_unwind(AssertUnwindSafe(|| {
        let _ = upgrade_remote_systemd_with(
            &fixture.upgrade_plan,
            &|args| runner.run(args),
            &|plan, expected, run| runner.verify(plan, expected, run),
        );
    }));
    assert!(crash.is_err());
    let manifest = fixture
        .operation
        .store_path
        .join("pending")
        .join("manifest.json");
    fs::write(&manifest, b"not valid json\n").expect("corrupt pending manifest");

    let error = recover_remote_systemd_with(
        &fixture.operation.store_path,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect_err("corrupt recovery must fail closed");

    assert!(error.to_string().contains("decode rollback manifest"));
    assert!(!runner.enabled());
    assert!(runner.recovery_timer_enabled());
    assert!(fixture.operation.store_path.join("armed.json").is_file());
    assert!(fixture.operation.store_path.join("pending").is_dir());
}

#[test]
fn armed_without_pending_finishes_safe_pre_activation_rollback() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    runner.set_panic_on_stop(true);
    let crash = catch_unwind(AssertUnwindSafe(|| {
        let _ = upgrade_remote_systemd_with(
            &fixture.upgrade_plan,
            &|args| runner.run(args),
            &|plan, expected, run| runner.verify(plan, expected, run),
        );
    }));
    assert!(crash.is_err());
    fs::remove_dir_all(fixture.operation.store_path.join("pending"))
        .expect("simulate cleanup before phase update");
    runner.set_panic_on_stop(false);

    let report = recover_remote_systemd_with(
        &fixture.operation.store_path,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("finish pre-activation rollback");

    assert_eq!(report.outcome, RemoteSystemdRecoveryOutcome::RolledBack);
    assert_eq!(
        fs::read_to_string(&fixture.binary).expect("old binary"),
        OLD_BINARY
    );
    assert!(runner.enabled());
    assert!(runner.recovery_timer_enabled());
}
