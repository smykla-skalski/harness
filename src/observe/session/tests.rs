use std::fs;

use crate::hooks::adapters::HookAgent;
use crate::workspace::project_context_dir;

use super::{find_session, find_session_for_agent};

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

#[test]
fn find_session_prefers_canonical_agent_log() {
    let tmp = tempfile::tempdir().unwrap();
    let project_dir = tmp.path().join("repo");
    fs::create_dir_all(&project_dir).unwrap();

    let data_dir = tmp.path().join("xdg_data");
    let legacy_dir = tmp
        .path()
        .join(".claude")
        .join("projects")
        .join("test-project");
    fs::create_dir_all(&legacy_dir).unwrap();
    fs::write(legacy_dir.join("abc123.jsonl"), "{}\n").unwrap();

    temp_env::with_vars(
        [
            ("HOME", Some(tmp.path().to_str().unwrap())),
            ("XDG_DATA_HOME", Some(data_dir.to_str().unwrap())),
        ],
        || {
            let canonical = project_context_dir(&project_dir)
                .join("agents")
                .join("sessions")
                .join("claude")
                .join("abc123")
                .join("raw.jsonl");
            fs::create_dir_all(canonical.parent().unwrap()).unwrap();
            fs::write(&canonical, "{}\n").unwrap();
            let result = find_session_for_agent("abc123", None, Some(HookAgent::Claude)).unwrap();
            assert_eq!(result, canonical);
        },
    );
}
