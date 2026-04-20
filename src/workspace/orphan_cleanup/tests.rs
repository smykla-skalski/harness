use super::*;
use tempfile::TempDir;

#[test]
fn removes_session_dir_without_state_json() {
    let tmp = TempDir::new().unwrap();
    let sessions = tmp.path().join("sessions");
    let orphan = sessions.join("proj/ab123456");
    std::fs::create_dir_all(&orphan).unwrap();
    let healthy = sessions.join("proj/cd789012");
    std::fs::create_dir_all(&healthy).unwrap();
    std::fs::write(healthy.join("state.json"), b"{}").unwrap();
    cleanup_orphans(&sessions).unwrap();
    assert!(!orphan.exists());
    assert!(healthy.exists());
}

#[test]
fn idempotent() {
    let tmp = TempDir::new().unwrap();
    let sessions = tmp.path().join("sessions");
    std::fs::create_dir_all(sessions.join("proj/abc12345")).unwrap();
    cleanup_orphans(&sessions).unwrap();
    cleanup_orphans(&sessions).unwrap();
}
