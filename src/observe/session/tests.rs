use std::fs;

use super::find_session;

#[test]
fn find_session_in_temp_dir() {
    let tmp = tempfile::tempdir().unwrap();
    let project_dir = tmp
        .path()
        .join(".claude")
        .join("projects")
        .join("test-project");
    fs::create_dir_all(&project_dir).unwrap();
    let session_file = project_dir.join("abc123.jsonl");
    fs::write(&session_file, "{}\n").unwrap();

    temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
        let result = find_session("abc123", None);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), session_file);
    });
}

#[test]
fn find_session_with_hint() {
    let tmp = tempfile::tempdir().unwrap();
    let project_a = tmp.path().join(".claude").join("projects").join("alpha");
    let project_b = tmp.path().join(".claude").join("projects").join("beta");
    fs::create_dir_all(&project_a).unwrap();
    fs::create_dir_all(&project_b).unwrap();
    fs::write(project_a.join("sess.jsonl"), "{}\n").unwrap();
    fs::write(project_b.join("sess.jsonl"), "{}\n").unwrap();

    temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
        let result = find_session("sess", Some("beta"));
        assert!(result.is_ok());
        let path = result.unwrap();
        assert!(path.to_string_lossy().contains("beta"));
    });
}

#[test]
fn find_session_not_found() {
    let tmp = tempfile::tempdir().unwrap();
    let project_dir = tmp.path().join(".claude").join("projects").join("proj");
    fs::create_dir_all(&project_dir).unwrap();

    temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
        let result = find_session("nonexistent", None);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert_eq!(err.code(), "KSRCLI080");
    });
}

#[test]
fn find_session_no_claude_dir() {
    let tmp = tempfile::tempdir().unwrap();
    temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
        let result = find_session("whatever", None);
        assert!(result.is_err());
    });
}

#[test]
fn find_session_ambiguous_without_hint() {
    let tmp = tempfile::tempdir().unwrap();
    let project_a = tmp.path().join(".claude").join("projects").join("alpha");
    let project_b = tmp.path().join(".claude").join("projects").join("beta");
    fs::create_dir_all(&project_a).unwrap();
    fs::create_dir_all(&project_b).unwrap();
    fs::write(project_a.join("shared.jsonl"), "{}\n").unwrap();
    fs::write(project_b.join("shared.jsonl"), "{}\n").unwrap();

    temp_env::with_vars([("HOME", Some(tmp.path().to_str().unwrap()))], || {
        let result = find_session("shared", None);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert_eq!(err.code(), "KSRCLI085");
    });
}
