use std::fs::{File, OpenOptions};
use std::os::unix::fs::OpenOptionsExt as _;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;

use fs2::FileExt as _;

use super::*;

fn hold_lifecycle_lock(path: &Path) -> File {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(path)
        .expect("open lifecycle lock");
    file.lock_exclusive().expect("hold lifecycle lock");
    file
}

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
    let _lock = hold_lifecycle_lock(&fixture.operation.store_path.join("operation.lock"));
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
    let _lock = hold_lifecycle_lock(&fixture.operation.store_path.join("operation.lock"));

    let transaction_root = fixture
        .operation
        .store_path
        .parent()
        .expect("transaction root");
    let Err(error) = LockedLifecycle::acquire(
        transaction_root,
        &fixture.operation.unit,
        &fixture.operation.store_path,
    ) else {
        panic!("install/uninstall guard must refuse a busy lifecycle lock");
    };

    assert!(
        error
            .to_string()
            .contains("another remote systemd lifecycle operation")
    );
}
