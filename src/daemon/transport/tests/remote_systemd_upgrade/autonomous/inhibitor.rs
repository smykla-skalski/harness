use super::*;

#[test]
fn crash_before_post_spawn_reload_leaves_the_persistent_inhibitor_on_disk() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    runner.set_panic_on_spawn_observation(true);

    let crash = catch_unwind(AssertUnwindSafe(|| {
        let _ = upgrade_remote_systemd_with(
            &fixture.upgrade_plan,
            &|args| runner.run(args),
            &|plan, expected, run| runner.verify(plan, expected, run),
        );
    }));

    assert!(crash.is_err());
    assert!(runner.inhibitor_installed());
    assert!(runner.runtime_permit_installed());
    assert!(!runner.runtime_permit_live());
    assert!(runner.active());
    assert!(!runner.enabled());
    assert!(runner.recovery_timer_enabled());
    assert!(fixture.operation.store_path.join("armed.json").is_file());
    assert!(installed_is_candidate(&fixture.binary));
    assert_eq!(database_schema(&fixture.database()), 35);

    runner.set_panic_on_spawn_observation(false);
    let report = recover_remote_systemd_with(
        &fixture.operation.store_path,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("recover after the post-spawn kill boundary");

    assert_eq!(report.outcome, RemoteSystemdRecoveryOutcome::RolledBack);
    assert!(!runner.inhibitor_installed());
    assert!(!runner.runtime_permit_path_exists());
    assert!(runner.active());
    assert!(runner.enabled());
    assert!(!fixture.operation.store_path.join("armed.json").exists());
    assert_eq!(database_schema(&fixture.database()), 31);
    assert_eq!(database_values(&fixture.database()), vec!["before"]);
}

#[test]
fn crash_after_permit_reload_before_start_leaves_only_a_stale_closed_window() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    runner.set_panic_after_permit_reload_before_start(true);

    let crash = catch_unwind(AssertUnwindSafe(|| {
        let _ = upgrade_remote_systemd_with(
            &fixture.upgrade_plan,
            &|args| runner.run(args),
            &|plan, expected, run| runner.verify(plan, expected, run),
        );
    }));

    assert!(crash.is_err());
    assert_eq!(runner.starts(), 0);
    assert!(runner.inhibitor_installed());
    assert!(runner.runtime_permit_installed());
    assert!(!runner.runtime_permit_live());
    assert!(!runner.active());
    assert!(!runner.enabled());
    assert!(runner.recovery_timer_enabled());
    assert!(fixture.operation.store_path.join("armed.json").is_file());
    assert!(installed_is_candidate(&fixture.binary));
    assert_eq!(database_schema(&fixture.database()), 31);

    runner.set_panic_after_permit_reload_before_start(false);
    let report = recover_remote_systemd_with(
        &fixture.operation.store_path,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("recover after the pre-start permit reload kill boundary");

    assert_eq!(report.outcome, RemoteSystemdRecoveryOutcome::RolledBack);
    assert!(!runner.runtime_permit_path_exists());
    assert!(!runner.inhibitor_installed());
    assert!(runner.active());
    assert!(runner.enabled());
    assert!(!fixture.operation.store_path.join("armed.json").exists());
    assert_eq!(database_schema(&fixture.database()), 31);
}

#[test]
fn unrelated_permit_path_blocks_creation_without_queueing_a_start() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    runner.set_block_permit_creation_after_candidate_reload(true);

    let report = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("permit blocker must produce a fail-closed rollback report");

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
    assert_eq!(runner.starts(), 0);
    assert!(runner.inhibitor_installed());
    assert!(!runner.runtime_permit_installed());
    assert!(!runner.runtime_permit_live());
    assert!(runner.runtime_permit_path_exists());
    assert!(!runner.active());
    assert!(!runner.enabled());
    assert!(runner.recovery_timer_enabled());
    assert!(fixture.operation.store_path.join("armed.json").is_file());
    assert_eq!(database_schema(&fixture.database()), 31);
}

#[test]
fn post_spawn_reload_failure_stays_disabled_inhibited_and_armed_when_rollback_health_fails() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    runner.set_fail_reload_after_start(true);
    runner.set_fail_old_health(true);

    let report = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("post-spawn failure must produce a fail-closed rollback report");

    assert_eq!(report.outcome, RemoteSystemdUpgradeOutcome::RollbackFailed);
    assert!(
        report
            .error
            .as_deref()
            .is_some_and(|error| error.contains("post-spawn daemon-reload failure"))
    );
    assert!(runner.inhibitor_installed());
    assert!(!runner.runtime_permit_path_exists());
    assert!(!runner.active());
    assert!(!runner.enabled());
    assert!(runner.recovery_timer_enabled());
    assert!(fixture.operation.store_path.join("armed.json").is_file());
    assert_eq!(database_schema(&fixture.database()), 31);
    assert_eq!(database_values(&fixture.database()), vec!["before"]);
}

#[test]
fn persistent_post_spawn_reload_failure_quiesces_candidate_until_timer_retry() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    runner.fail_reloads_after_candidate_spawn();

    let report = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("persistent post-spawn reload failure must remain recoverable");

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
    assert!(runner.inhibitor_installed());
    assert!(!runner.runtime_permit_path_exists());
    assert!(!runner.active());
    assert!(!runner.enabled());
    assert!(runner.recovery_timer_enabled());
    assert!(fixture.operation.store_path.join("armed.json").is_file());
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

    runner.clear_persistent_reload_failure();
    let recovered = recover_remote_systemd_with(
        &fixture.operation.store_path,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("timer retry restores the pre-upgrade generation");

    assert_eq!(recovered.outcome, RemoteSystemdRecoveryOutcome::RolledBack);
    assert!(!runner.inhibitor_installed());
    assert!(runner.active());
    assert!(runner.enabled());
    assert!(!fixture.operation.store_path.join("armed.json").exists());
    assert!(!installed_is_candidate(&fixture.binary));
    assert_eq!(
        fs::read_to_string(fixture.state.join("config.json")).expect("restored config"),
        "before\n"
    );
    assert_eq!(database_schema(&fixture.database()), 31);
    assert_eq!(database_values(&fixture.database()), vec!["before"]);
}

#[test]
fn final_release_failure_rearms_disables_and_inhibits_before_timer_retry() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    runner.set_fail_final_release_reload(true);

    let error = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect_err("final inhibitor release failure must remain armed");

    assert!(
        error
            .to_string()
            .contains("final inhibitor release reload failure")
    );
    assert!(runner.inhibitor_installed());
    assert!(!runner.active());
    assert!(!runner.enabled());
    assert!(runner.recovery_timer_enabled());
    assert!(fixture.operation.store_path.join("armed.json").is_file());
    assert!(fixture.operation.store_path.join("previous").is_dir());
    assert!(installed_is_candidate(&fixture.binary));
    assert_eq!(database_schema(&fixture.database()), 35);

    let report = recover_remote_systemd_with(
        &fixture.operation.store_path,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("timer retry finishes the durable commit");

    assert_eq!(
        report.outcome,
        RemoteSystemdRecoveryOutcome::CommitCompleted
    );
    assert!(!runner.inhibitor_installed());
    assert!(runner.active());
    assert!(runner.enabled());
    assert!(!fixture.operation.store_path.join("armed.json").exists());
    assert!(installed_is_candidate(&fixture.binary));
    assert_eq!(database_schema(&fixture.database()), 35);
}

#[test]
fn persistent_final_release_reload_failure_quiesces_committed_candidate_until_retry() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    runner.fail_reloads_after_final_inhibitor_release();

    let error = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect_err("persistent final release reload failure must remain armed");

    let error = error.to_string();
    assert!(error.contains("persistent final inhibitor release reload failure"));
    assert!(
        error
            .matches("persistent final inhibitor release reload failure")
            .count()
            >= 2,
        "both the release and fail-closed reloads must retain their errors: {error}"
    );
    assert!(runner.inhibitor_installed());
    assert!(!runner.runtime_permit_path_exists());
    assert!(!runner.active());
    assert!(!runner.enabled());
    assert!(runner.recovery_timer_enabled());
    assert!(fixture.operation.store_path.join("armed.json").is_file());
    assert!(!fixture.operation.store_path.join("pending").exists());
    assert!(fixture.operation.store_path.join("previous").is_dir());
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

    runner.clear_persistent_reload_failure();
    let recovered = recover_remote_systemd_with(
        &fixture.operation.store_path,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("timer retry finishes the committed generation");

    assert_eq!(
        recovered.outcome,
        RemoteSystemdRecoveryOutcome::CommitCompleted
    );
    assert!(!runner.inhibitor_installed());
    assert!(runner.active());
    assert!(runner.enabled());
    assert!(!fixture.operation.store_path.join("armed.json").exists());
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

#[test]
fn recovery_disable_failure_happens_only_after_the_candidate_is_stopped_and_inhibited() {
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
    assert!(runner.active());
    assert!(runner.inhibitor_installed());

    runner.set_panic_on_candidate_health(false);
    runner.fail_reloads_after_candidate_spawn();
    runner.set_fail_daemon_disable(true);
    let error = recover_remote_systemd_with(
        &fixture.operation.store_path,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect_err("recovery disable failure must preserve the quiescent guard");

    let error = error.to_string();
    assert!(error.contains("persistent post-spawn daemon-reload failure"));
    assert!(error.contains("forced daemon disable failure"));
    assert!(runner.inhibitor_installed());
    assert!(!runner.active());
    assert!(fixture.operation.store_path.join("armed.json").is_file());
    assert!(fixture.operation.store_path.join("pending").is_dir());
    assert!(installed_is_candidate(&fixture.binary));
    assert_eq!(database_schema(&fixture.database()), 35);
}
