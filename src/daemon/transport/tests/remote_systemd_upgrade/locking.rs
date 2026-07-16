use std::panic::{AssertUnwindSafe, catch_unwind};

use crate::infra::persistence::flock::{FlockErrorContext, try_acquire_exclusive_flock};

use super::*;

#[test]
fn active_lifecycle_lock_defers_timer_recovery_with_exit_75() {
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
    let _lock = try_acquire_exclusive_flock(
        &fixture.operation.store_path.join("operation.lock"),
        FlockErrorContext::new("recovery defer test"),
    )
    .expect("hold operation lock");
    fs::write(
        fixture.operation.store_path.join("armed.json"),
        "stale arm must not be read while the lock is busy\n",
    )
    .expect("corrupt stale arm after lifecycle lock");

    let report = recover_remote_systemd_with(
        &fixture.operation.store_path,
        &|args| runner.run(args),
        &|plan, expected, run| runner.verify(plan, expected, run),
    )
    .expect("busy recovery report");

    assert_eq!(report.outcome, RemoteSystemdRecoveryOutcome::Deferred);
    assert_eq!(report.exit_code(), 75);
    assert!(fixture.operation.store_path.join("armed.json").is_file());
    assert!(!runner.enabled());
}

#[test]
fn install_and_uninstall_guard_refuses_a_busy_lifecycle_lock() {
    let fixture = UpgradeFixture::new();
    fs::create_dir_all(&fixture.operation.store_path).expect("create transaction store");
    let _lock = try_acquire_exclusive_flock(
        &fixture.operation.store_path.join("operation.lock"),
        FlockErrorContext::new("lifecycle mutation guard test"),
    )
    .expect("hold lifecycle lock");

    let transaction_root = fixture
        .operation
        .store_path
        .parent()
        .expect("transaction root");
    let error = match LockedLifecycle::acquire(
        transaction_root,
        &fixture.operation.unit,
        &fixture.operation.store_path,
    ) {
        Ok(_) => panic!("install/uninstall guard must refuse a busy lifecycle lock"),
        Err(error) => error,
    };

    assert!(
        error
            .to_string()
            .contains("another remote systemd lifecycle operation")
    );
}
