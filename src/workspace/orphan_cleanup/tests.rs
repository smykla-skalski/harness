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

#[test]
fn skips_dot_prefixed_siblings() {
    let tmp = TempDir::new().unwrap();
    let sessions = tmp.path().join("sessions");
    // Dot-prefixed file at project level
    let dot_file = sessions.join("proj/.active.json");
    std::fs::create_dir_all(dot_file.parent().unwrap()).unwrap();
    std::fs::write(&dot_file, b"{}").unwrap();
    // Dot-prefixed directory at session level (no state.json)
    let dot_dir = sessions.join("proj/.something");
    std::fs::create_dir_all(&dot_dir).unwrap();
    cleanup_orphans(&sessions).unwrap();
    assert!(dot_file.exists(), ".active.json must survive sweep");
    assert!(dot_dir.exists(), ".something dir must survive sweep");
}

#[cfg(unix)]
#[test]
fn skips_symlinked_session_dirs() {
    use std::os::unix::fs::symlink;

    let tmp = TempDir::new().unwrap();
    let sessions = tmp.path().join("sessions");
    let project = sessions.join("proj");
    std::fs::create_dir_all(&project).unwrap();

    // A symlink pointing at a non-existent target (dangling)
    let link = project.join("deadbeef");
    let absent_target = tmp.path().join("elsewhere");
    symlink(&absent_target, &link).unwrap();

    cleanup_orphans(&sessions).unwrap();

    // The symlink itself must still exist; the sweep must not have followed it
    assert!(
        link.symlink_metadata().is_ok(),
        "symlink must not be removed by orphan sweep"
    );
}
