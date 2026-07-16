use super::*;

#[test]
fn upgrade_rechecks_binary_exclusivity_immediately_before_replacement() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    runner.set_inventory_conflict_from_pass(3);

    let report = upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("conflicting inventory produces a rollback report");

    assert_eq!(report.outcome, RemoteSystemdUpgradeOutcome::RolledBack);
    assert_eq!(
        fs::read_to_string(&fixture.binary).expect("installed binary"),
        OLD_BINARY
    );
    assert!(
        report
            .error
            .as_deref()
            .is_some_and(|error| error.contains("shares target executable"))
    );
}

#[test]
fn failed_legacy_upgrade_does_not_persist_an_unproven_claim() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    let drifted = fs::read_to_string(&fixture.unit)
        .expect("managed unit")
        .replace(
            "StateDirectory=harness-remote",
            "StateDirectory=unmanaged-state",
        );
    fs::write(&fixture.unit, drifted).expect("drift managed unit");

    upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect_err("unproven legacy ownership must fail");

    assert!(!claim_registry_path(&fixture).exists());
}

#[test]
fn failed_legacy_rollback_does_not_persist_an_unproven_claim() {
    let fixture = UpgradeFixture::new();
    let runner = ScriptedSystemd::new(&fixture, false);
    upgrade_remote_systemd_with(
        &fixture.upgrade_plan,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("seed rollback generation");
    fs::remove_file(claim_registry_path(&fixture)).expect("remove claim to model legacy state");
    let drifted = fs::read_to_string(&fixture.unit)
        .expect("managed unit")
        .replace(
            "StateDirectory=harness-remote",
            "StateDirectory=unmanaged-state",
        );
    fs::write(&fixture.unit, drifted).expect("drift managed unit");

    rollback_remote_systemd_with(
        &fixture.operation,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect_err("unproven legacy rollback ownership must fail");

    assert!(!claim_registry_path(&fixture).exists());
}

fn claim_registry_path(fixture: &UpgradeFixture) -> PathBuf {
    fixture
        .operation
        .store_path
        .parent()
        .expect("transaction root")
        .join(".binary-claims.json")
}
