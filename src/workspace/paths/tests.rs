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
