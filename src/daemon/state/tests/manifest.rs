use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use tempfile::tempdir;

use super::super::{
    DaemonManifest, HostBridgeManifest, clear_manifest_for_pid, load_manifest,
    load_running_manifest, manifest_path, write_manifest,
};
use super::{install_manifest_write_hook, sample_manifest};

#[test]
fn manifest_deserializes_legacy_json_without_sandbox_fields() {
    let legacy = r#"{
        "version": "18.14.0",
        "pid": 101,
        "endpoint": "http://127.0.0.1:7070",
        "started_at": "2026-04-01T00:00:00Z",
        "token_path": "/tmp/legacy-token"
    }"#;
    let manifest: DaemonManifest = serde_json::from_str(legacy).expect("legacy deserialize");
    assert_eq!(manifest.version, "18.14.0");
    assert_eq!(manifest.pid, 101);
    assert!(!manifest.sandboxed, "legacy manifests default to unsandboxed");
    assert!(
        manifest.host_bridge == HostBridgeManifest::default(),
        "legacy manifests default host bridge to an empty snapshot"
    );
    assert_eq!(manifest.revision, 0, "legacy manifests default revision to zero");
    assert!(
        manifest.updated_at.is_empty(),
        "legacy manifests default updated_at to empty"
    );
}

#[test]
fn manifest_round_trip() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [("XDG_DATA_HOME", Some(tmp.path().to_str().expect("utf8 path")))],
        || {
            let manifest = sample_manifest(42, "http://127.0.0.1:9999");
            write_manifest(&manifest).expect("write");
            let loaded = load_manifest().expect("load").expect("manifest");
            assert_eq!(loaded.endpoint, manifest.endpoint);
            assert_eq!(loaded.pid, 42);
            assert_eq!(loaded.revision, 1, "first write bumps revision to 1");
            assert!(!loaded.updated_at.is_empty(), "updated_at is populated");
        },
    );
}

#[test]
fn clear_manifest_for_pid_only_removes_owned_manifest() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [("XDG_DATA_HOME", Some(tmp.path().to_str().expect("utf8 path")))],
        || {
            write_manifest(&sample_manifest(777, "http://127.0.0.1:7777")).expect("manifest");

            clear_manifest_for_pid(778).expect("skip foreign pid");
            assert!(manifest_path().exists(), "foreign pid should not clear manifest");

            clear_manifest_for_pid(777).expect("clear owned manifest");
            assert!(!manifest_path().exists(), "owned pid should clear manifest");
        },
    );
}

#[test]
fn load_running_manifest_clears_stale_manifest_when_lock_is_free() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [("XDG_DATA_HOME", Some(tmp.path().to_str().expect("utf8 path")))],
        || {
            write_manifest(&sample_manifest(9191, "http://127.0.0.1:9191")).expect("manifest");

            let manifest = load_running_manifest().expect("load running manifest");

            assert!(manifest.is_none(), "stale manifest should be hidden");
            assert!(!manifest_path().exists(), "stale manifest should be removed");
        },
    );
}

#[test]
fn write_manifest_serializes_concurrent_writers_before_loading_next_revision() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [("XDG_DATA_HOME", Some(tmp.path().to_str().expect("utf8 path")))],
        || {
            let base = sample_manifest(4242, "http://127.0.0.1:4242");
            let (event_tx, event_rx) = mpsc::channel();
            let released = Arc::new(AtomicBool::new(false));
            let call_index = Arc::new(AtomicUsize::new(0));
            let _hook_reset = install_manifest_write_hook({
                let released = Arc::clone(&released);
                let call_index = Arc::clone(&call_index);
                move || {
                    let current = call_index.fetch_add(1, Ordering::SeqCst);
                    event_tx.send(current).expect("send manifest hook event");
                    if current == 0 {
                        while !released.load(Ordering::SeqCst) {
                            thread::yield_now();
                        }
                    }
                }
            });

            let first_manifest = base.clone();
            let first = thread::spawn(move || write_manifest(&first_manifest));
            assert_eq!(
                event_rx
                    .recv_timeout(Duration::from_secs(2))
                    .expect("first hook"),
                0
            );

            let second_manifest = base.clone();
            let second = thread::spawn(move || write_manifest(&second_manifest));
            let second_before_release = event_rx.recv_timeout(Duration::from_millis(200)).ok();

            released.store(true, Ordering::SeqCst);

            let first_written = first.join().expect("join first").expect("first write");
            let second_hook = second_before_release
                .or_else(|| event_rx.recv_timeout(Duration::from_secs(2)).ok());
            let second_written = second.join().expect("join second").expect("second write");

            assert!(
                second_before_release.is_none(),
                "second writer should block until the first write completes"
            );
            assert_eq!(second_hook, Some(1));
            assert_eq!(first_written.revision, 1);
            assert_eq!(second_written.revision, 2);

            let loaded = load_manifest().expect("load").expect("manifest");
            assert_eq!(loaded.revision, 2);
        },
    );
}

#[test]
fn write_manifest_bumps_revision_monotonically() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [("XDG_DATA_HOME", Some(tmp.path().to_str().expect("utf8 path")))],
        || {
            let base = sample_manifest(123, "http://127.0.0.1:0");
            let first = write_manifest(&base).expect("first write");
            assert_eq!(first.revision, 1);
            assert!(!first.updated_at.is_empty());

            let second = write_manifest(&base).expect("second write");
            assert_eq!(second.revision, 2);

            let third = write_manifest(&base).expect("third write");
            assert_eq!(third.revision, 3);

            let loaded = load_manifest().expect("load").expect("manifest");
            assert_eq!(loaded.revision, 3);
            assert!(!loaded.updated_at.is_empty());
        },
    );
}

#[test]
fn write_manifest_sets_updated_at_to_non_empty_string() {
    let tmp = tempdir().expect("tempdir");
    temp_env::with_vars(
        [("XDG_DATA_HOME", Some(tmp.path().to_str().expect("utf8 path")))],
        || {
            let written =
                write_manifest(&sample_manifest(555, "http://127.0.0.1:0")).expect("write");
            assert!(
                !written.updated_at.is_empty(),
                "write_manifest must stamp updated_at with the current UTC time"
            );
            assert!(
                written.updated_at.contains('T'),
                "updated_at should be ISO-ish: {}",
                written.updated_at
            );
        },
    );
}
