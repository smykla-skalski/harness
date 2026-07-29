use std::path::Path;

use serde_json::{Value, json};
use tempfile::tempdir;

use super::super::{
    DAEMON_HOST_FINGERPRINT_ENV, DAEMON_NAME_ENV, ScopedDaemonRootOverride, ensure_daemon_identity,
    identity_path, reported_daemon_identity, set_daemon_name,
};

/// Run `action` against a private daemon root with an explicit host
/// fingerprint, so the tests do not depend on whether this machine exposes a
/// machine id of its own.
fn with_daemon_root<T>(root: &Path, fingerprint: Option<&str>, action: impl FnOnce() -> T) -> T {
    let _root = ScopedDaemonRootOverride::set(Some(root.to_path_buf()));
    temp_env::with_vars(
        [
            (DAEMON_HOST_FINGERPRINT_ENV, fingerprint),
            (DAEMON_NAME_ENV, None),
        ],
        action,
    )
}

fn stored_identity(root: &Path) -> Value {
    let _root = ScopedDaemonRootOverride::set(Some(root.to_path_buf()));
    let text = fs_err::read_to_string(identity_path()).expect("read identity file");
    serde_json::from_str(&text).expect("parse identity file")
}

#[test]
fn identity_is_minted_once_and_reused() {
    let tmp = tempdir().expect("tempdir");

    let (first, second) = with_daemon_root(tmp.path(), Some("host-a"), || {
        let first = ensure_daemon_identity().expect("first identity");
        let second = ensure_daemon_identity().expect("second identity");
        (first, second)
    });

    assert_eq!(first, second);
    assert!(!first.daemon_id.is_empty());
}

#[test]
fn separate_daemon_roots_report_separate_identities() {
    let first_root = tempdir().expect("tempdir");
    let second_root = tempdir().expect("tempdir");

    let first = with_daemon_root(first_root.path(), Some("host-a"), || {
        ensure_daemon_identity().expect("first identity")
    });
    let second = with_daemon_root(second_root.path(), Some("host-a"), || {
        ensure_daemon_identity().expect("second identity")
    });

    assert_ne!(first.daemon_id, second.daemon_id);
}

#[test]
fn identity_restored_onto_another_host_is_replaced() {
    let tmp = tempdir().expect("tempdir");

    let original = with_daemon_root(tmp.path(), Some("host-a"), || {
        ensure_daemon_identity().expect("original identity")
    });
    let restored = with_daemon_root(tmp.path(), Some("host-b"), || {
        ensure_daemon_identity().expect("restored identity")
    });

    assert_ne!(original.daemon_id, restored.daemon_id);
}

#[test]
fn identity_without_a_stored_fingerprint_is_kept() {
    let tmp = tempdir().expect("tempdir");
    with_daemon_root(tmp.path(), Some("host-a"), || {
        fs_err::create_dir_all(identity_path().parent().expect("identity parent"))
            .expect("create daemon root");
        fs_err::write(
            identity_path(),
            json!({ "daemon_id": "carried-over", "created_at": "2026-07-25T00:00:00Z" })
                .to_string(),
        )
        .expect("write identity file");

        assert_eq!(
            ensure_daemon_identity().expect("identity").daemon_id,
            "carried-over"
        );
    });
}

#[test]
fn reporting_never_mints_an_identity() {
    let tmp = tempdir().expect("tempdir");

    let reported = with_daemon_root(tmp.path(), Some("host-a"), || {
        let reported = reported_daemon_identity().expect("reported identity");
        assert!(!identity_path().exists());
        reported
    });

    assert!(reported.is_none());
}

#[test]
fn reporting_follows_a_rename_made_by_another_process() {
    let tmp = tempdir().expect("tempdir");
    with_daemon_root(tmp.path(), Some("host-a"), || {
        ensure_daemon_identity().expect("identity");
        set_daemon_name("prod-runner").expect("set name");

        assert_eq!(
            reported_daemon_identity()
                .expect("reported identity")
                .expect("identity present")
                .name,
            "prod-runner"
        );
    });
}

#[test]
fn stored_fingerprint_is_hashed() {
    let tmp = tempdir().expect("tempdir");
    with_daemon_root(tmp.path(), Some("machine-id-secret"), || {
        ensure_daemon_identity().expect("identity");
    });

    let stored = stored_identity(tmp.path());
    let fingerprint = stored["host_fingerprint"]
        .as_str()
        .expect("stored fingerprint");
    assert_ne!(fingerprint, "machine-id-secret");
    assert_eq!(fingerprint.len(), 64);
}

#[test]
fn name_falls_back_to_the_environment_default() {
    let tmp = tempdir().expect("tempdir");
    let _root = ScopedDaemonRootOverride::set(Some(tmp.path().to_path_buf()));

    let identity = temp_env::with_vars(
        [
            (DAEMON_HOST_FINGERPRINT_ENV, Some("host-a")),
            (DAEMON_NAME_ENV, Some("lab-01")),
        ],
        || ensure_daemon_identity().expect("identity"),
    );

    assert_eq!(identity.name, "lab-01");
}

#[test]
fn set_name_outlives_the_environment_default_and_keeps_the_id() {
    let tmp = tempdir().expect("tempdir");
    let _root = ScopedDaemonRootOverride::set(Some(tmp.path().to_path_buf()));

    temp_env::with_vars(
        [
            (DAEMON_HOST_FINGERPRINT_ENV, Some("host-a")),
            (DAEMON_NAME_ENV, Some("lab-01")),
        ],
        || {
            let original = ensure_daemon_identity().expect("identity");
            let renamed = set_daemon_name("  prod-runner  ").expect("set name");

            assert_eq!(renamed.name, "prod-runner");
            assert_eq!(renamed.daemon_id, original.daemon_id);
            assert_eq!(ensure_daemon_identity().expect("reread"), renamed);
        },
    );
}

#[test]
fn set_name_rejects_unusable_names() {
    let tmp = tempdir().expect("tempdir");
    with_daemon_root(tmp.path(), Some("host-a"), || {
        assert!(set_daemon_name("   ").is_err());
        assert!(set_daemon_name("lab\u{0}01").is_err());
        assert!(set_daemon_name(&"n".repeat(65)).is_err());
        assert!(set_daemon_name(&"n".repeat(64)).is_ok());
    });
}
