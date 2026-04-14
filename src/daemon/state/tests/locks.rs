use std::fs;

use fs2::FileExt;
use tempfile::tempdir;

use super::super::{
    acquire_flock_exclusive, acquire_singleton_lock, daemon_lock_is_held_at, flock_is_held_at,
    write_manifest,
};
use super::sample_manifest;

#[test]
fn singleton_lock_rejects_second_holder() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [(
            "XDG_DATA_HOME",
            Some(tmp.path().to_str().expect("utf8 path")),
        )],
        || {
            let _guard = acquire_singleton_lock().expect("first lock");
            write_manifest(&sample_manifest(4242, "http://127.0.0.1:9999")).expect("manifest");

            let error = acquire_singleton_lock().expect_err("second lock should fail");
            let message = error.to_string();
            assert!(message.contains("daemon already running"));
            assert!(message.contains("4242"));
            assert!(message.contains("127.0.0.1:9999"));
        },
    );
}

#[test]
fn daemon_lock_is_held_at_returns_false_for_missing_lock_file() {
    let tmp = tempdir().expect("tempdir");
    let missing = tmp.path().join("daemon.lock");
    assert!(!daemon_lock_is_held_at(&missing));
}

#[test]
fn daemon_lock_is_held_at_returns_false_for_unlocked_file() {
    let tmp = tempdir().expect("tempdir");
    let path = tmp.path().join("daemon.lock");
    fs::write(&path, "").expect("create empty lock file");
    assert!(!daemon_lock_is_held_at(&path));
}

#[test]
fn daemon_lock_is_held_at_returns_true_for_actively_held_lock() {
    let tmp = tempdir().expect("tempdir");
    let path = tmp.path().join("daemon.lock");
    let holder = fs::OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(&path)
        .expect("open lock");
    holder.try_lock_exclusive().expect("take flock");
    assert!(daemon_lock_is_held_at(&path));
    drop(holder);
    assert!(!daemon_lock_is_held_at(&path));
}

#[test]
fn flock_is_held_at_returns_false_for_missing_file() {
    let tmp = tempdir().expect("tempdir");
    assert!(!flock_is_held_at(&tmp.path().join("no-such.lock")));
}

#[test]
fn flock_is_held_at_returns_false_for_unlocked_file() {
    let tmp = tempdir().expect("tempdir");
    let path = tmp.path().join("test.lock");
    fs::write(&path, "").expect("create");
    assert!(!flock_is_held_at(&path));
}

#[test]
fn flock_is_held_at_returns_true_while_another_holder_is_alive() {
    let tmp = tempdir().expect("tempdir");
    let path = tmp.path().join("test.lock");
    let guard = acquire_flock_exclusive(&path, "test").expect("acquire");
    assert!(flock_is_held_at(&path));
    drop(guard);
    assert!(!flock_is_held_at(&path));
}

#[test]
fn acquire_flock_exclusive_fails_with_label_in_error_when_already_held() {
    let tmp = tempdir().expect("tempdir");
    let path = tmp.path().join("test.lock");
    let _guard = acquire_flock_exclusive(&path, "bridge").expect("first acquire");
    let error = acquire_flock_exclusive(&path, "bridge").expect_err("second should fail");
    assert!(
        error.to_string().contains("bridge"),
        "error should mention the label: {error}"
    );
}
