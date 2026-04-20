use super::*;
use std::fs;
use tempfile::TempDir;

fn write_valid_session(root: &Path, sid: &str, origin: &str) {
    fs::create_dir_all(root.join("workspace")).unwrap();
    fs::create_dir_all(root.join("memory")).unwrap();
    let state = format!(
        "{{\"schema_version\":{CURRENT_VERSION},\"session_id\":\"{sid}\",\"project_name\":\"demo\",\
          \"origin_path\":\"{origin}\",\"worktree_path\":\"\",\"shared_path\":\"\",\
          \"branch_ref\":\"harness/{sid}\",\"title\":\"t\",\"context\":\"c\",\
          \"status\":\"active\",\"created_at\":\"2026-04-20T00:00:00Z\",\
          \"updated_at\":\"2026-04-20T00:00:00Z\"}}"
    );
    fs::write(root.join("state.json"), state).unwrap();
    fs::write(root.join(".origin"), origin).unwrap();
}

#[test]
fn probe_accepts_valid_b_layout() {
    let tmp = TempDir::new().unwrap();
    let session = tmp.path().join("kuma/abc12345");
    fs::create_dir_all(&session).unwrap();
    write_valid_session(&session, "abc12345", "/Users/me/src/kuma");

    let probed = SessionAdopter::probe(&session).expect("probe ok");
    assert_eq!(probed.session_id(), "abc12345");
    assert_eq!(probed.project_name(), "demo");
}

#[test]
fn probe_rejects_missing_state_json() {
    let tmp = TempDir::new().unwrap();
    let session = tmp.path().join("kuma/abc12345");
    fs::create_dir_all(&session).unwrap();
    let err = SessionAdopter::probe(&session).expect_err("layout violation");
    assert!(matches!(err, AdoptionError::LayoutViolation { .. }));
}

#[test]
fn probe_rejects_missing_workspace() {
    let tmp = TempDir::new().unwrap();
    let session = tmp.path().join("kuma/abc12345");
    fs::create_dir_all(&session).unwrap();
    write_valid_session(&session, "abc12345", "/o");
    fs::remove_dir_all(session.join("workspace")).unwrap();

    let err = SessionAdopter::probe(&session).expect_err("layout violation");
    assert!(matches!(err, AdoptionError::LayoutViolation { .. }));
}

#[test]
fn probe_rejects_origin_mismatch() {
    let tmp = TempDir::new().unwrap();
    let session = tmp.path().join("kuma/abc12345");
    fs::create_dir_all(&session).unwrap();
    write_valid_session(&session, "abc12345", "/a");
    fs::write(session.join(".origin"), "/b").unwrap();

    let err = SessionAdopter::probe(&session).expect_err("origin mismatch");
    assert!(matches!(err, AdoptionError::OriginMismatch { .. }));
}

#[test]
fn probe_rejects_schema_mismatch() {
    let tmp = TempDir::new().unwrap();
    let session = tmp.path().join("kuma/abc12345");
    fs::create_dir_all(&session).unwrap();
    fs::create_dir_all(session.join("workspace")).unwrap();
    fs::create_dir_all(session.join("memory")).unwrap();
    fs::write(session.join(".origin"), "/o").unwrap();
    fs::write(
        session.join("state.json"),
        "{\"schema_version\":7,\"session_id\":\"abc12345\",\"project_name\":\"demo\",\"origin_path\":\"/o\",\"status\":\"active\",\"context\":\"c\",\"created_at\":\"2026-04-20T00:00:00Z\",\"updated_at\":\"2026-04-20T00:00:00Z\"}",
    ).unwrap();
    let err = SessionAdopter::probe(&session).expect_err("schema");
    assert!(matches!(
        err,
        AdoptionError::UnsupportedSchemaVersion {
            found: 7,
            supported: 9
        }
    ));
}

#[test]
fn register_persists_state_and_flags_external() {
    let tmp = TempDir::new().unwrap();
    let session = tmp.path().join("external-root/demo/abc12345");
    fs::create_dir_all(&session).unwrap();
    let origin = tmp.path().join("src/demo");
    fs::create_dir_all(&origin).unwrap();
    write_valid_session(&session, "abc12345", origin.to_str().unwrap());

    let probed = SessionAdopter::probe(&session).expect("probe");
    // data_root_sessions is some unrelated path so the session is "external"
    let data_root_sessions = tmp.path().join("harness-data/sessions");
    fs::create_dir_all(&data_root_sessions).unwrap();

    let outcome = SessionAdopter::register(probed, &data_root_sessions).expect("register");
    assert_eq!(outcome.external_origin.as_deref(), Some(session.as_path()));
    assert_eq!(outcome.state.session_id, "abc12345");
    assert!(outcome.state.external_origin.is_some());
    assert!(outcome.state.adopted_at.is_some());

    // Duplicate register → AlreadyAttached
    let probed_again = SessionAdopter::probe(&session).expect("probe2");
    let err = SessionAdopter::register(probed_again, &data_root_sessions).expect_err("dup");
    assert!(matches!(err, AdoptionError::AlreadyAttached { .. }));
}

#[test]
fn register_internal_session_has_no_external_origin() {
    let tmp = TempDir::new().unwrap();
    let sessions_root = tmp.path().join("harness-data/sessions");
    let session = sessions_root.join("demo/zxc98765");
    fs::create_dir_all(&session).unwrap();
    let origin = tmp.path().join("src/demo");
    fs::create_dir_all(&origin).unwrap();
    write_valid_session(&session, "zxc98765", origin.to_str().unwrap());

    let probed = SessionAdopter::probe(&session).expect("probe");
    let outcome = SessionAdopter::register(probed, &sessions_root).expect("register");
    assert!(outcome.external_origin.is_none());
    assert!(outcome.state.external_origin.is_none());
}
