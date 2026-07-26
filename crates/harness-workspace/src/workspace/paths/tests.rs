use super::*;

#[test]
fn utc_now_ends_with_z() {
    let now = utc_now();
    assert!(now.ends_with('Z'), "expected Z suffix, got: {now}");
    assert!(!now.contains('+'), "expected no +, got: {now}");
}

#[test]
fn dirs_home_prefers_home_env() {
    let tmp = tempfile::tempdir().unwrap();
    temp_env::with_var("HOME", Some(tmp.path()), || {
        assert_eq!(dirs_home(), tmp.path());
    });
}

#[test]
fn ensure_non_indexable_creates_marker_idempotently() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("harness");

    ensure_non_indexable(&root).expect("first call");
    let marker = root.join(NON_INDEXABLE_MARKER_NAME);
    assert!(marker.is_file(), "marker missing after first call");

    ensure_non_indexable(&root).expect("second call");
    assert!(marker.is_file(), "marker disappeared after second call");
}
