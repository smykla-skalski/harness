use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;

use harness::create;
use harness::create::{CreateBeginArgs, CreateSaveArgs};
use harness::workspace;

use super::super::super::helpers::*;

pub(super) fn check_record_isolates_run_context_by_session_id() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg-iso");

    let dir_a = Mutex::new(PathBuf::new());
    let dir_b = Mutex::new(PathBuf::new());

    let da = &dir_a;
    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("session-alpha")),
        ],
        || {
            *da.lock().unwrap() = workspace::session_context_dir().unwrap();
        },
    );
    let db = &dir_b;
    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("session-beta")),
        ],
        || {
            *db.lock().unwrap() = workspace::session_context_dir().unwrap();
        },
    );

    let a = dir_a.lock().unwrap().clone();
    let b = dir_b.lock().unwrap().clone();
    assert_ne!(
        a, b,
        "different sessions should have different context dirs"
    );
}

pub(super) fn check_create_begin_persists_suite_default_repo_root() {
    let tmp = tempfile::tempdir().unwrap();
    let repo_root = tmp.path().join("repo");
    fs::create_dir_all(&repo_root).unwrap();
    let suite_dir = tmp.path().join("suite");
    fs::create_dir_all(&suite_dir).unwrap();

    let xdg = tmp.path().join("xdg-begin");

    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("create-begin-integ")),
        ],
        || {
            let result = create_begin_cmd(CreateBeginArgs {
                repo_root: repo_root.to_string_lossy().to_string(),
                feature: "mesh".to_string(),
                mode: "interactive".to_string(),
                suite_dir: suite_dir.to_string_lossy().to_string(),
                suite_name: "install".to_string(),
            })
            .execute();
            assert!(result.is_ok(), "create_begin should succeed: {result:?}");

            let session = create::load_create_session().unwrap().unwrap();
            assert_eq!(session.feature, "mesh");
            assert_eq!(session.suite_name, "install");
            assert!(!session.repo_root.is_empty());
        },
    );
}

pub(super) fn check_create_save_accepts_inline_payload() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg-save");
    let repo_root = tmp.path().join("repo");
    fs::create_dir_all(&repo_root).unwrap();
    let suite_dir = tmp.path().join("suite");
    fs::create_dir_all(&suite_dir).unwrap();

    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("create-save-inline")),
        ],
        || {
            let _ = create_begin_cmd(CreateBeginArgs {
                repo_root: repo_root.to_string_lossy().to_string(),
                feature: "mesh".to_string(),
                mode: "interactive".to_string(),
                suite_dir: suite_dir.to_string_lossy().to_string(),
                suite_name: "install".to_string(),
            })
            .execute();

            let result = create_save_cmd(CreateSaveArgs {
                kind: "inventory".to_string(),
                payload: Some(r#"{"files":[]}"#.to_string()),
                input: None,
            })
            .execute();
            assert!(
                result.is_ok(),
                "save with inline payload should succeed: {result:?}"
            );

            let workspace = create::create_workspace_dir().unwrap();
            let saved = workspace.join("inventory.json");
            assert!(saved.exists(), "inventory.json should be saved");
        },
    );
}

pub(super) fn check_create_save_accepts_stdin() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg-stdin");
    let repo_root = tmp.path().join("repo");
    fs::create_dir_all(&repo_root).unwrap();
    let suite_dir = tmp.path().join("suite");
    fs::create_dir_all(&suite_dir).unwrap();
    let input_file = tmp.path().join("input.json");
    fs::write(&input_file, r#"{"files":["a.yaml"]}"#).unwrap();

    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("create-save-stdin")),
        ],
        || {
            let _ = create_begin_cmd(CreateBeginArgs {
                repo_root: repo_root.to_string_lossy().to_string(),
                feature: "mesh".to_string(),
                mode: "interactive".to_string(),
                suite_dir: suite_dir.to_string_lossy().to_string(),
                suite_name: "install".to_string(),
            })
            .execute();

            let result = create_save_cmd(CreateSaveArgs {
                kind: "inventory".to_string(),
                payload: None,
                input: Some(input_file.to_str().unwrap().to_string()),
            })
            .execute();
            assert!(result.is_ok(), "save from file should succeed: {result:?}");
        },
    );
}

pub(super) fn check_create_save_rejects_schema_missing_fields() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg-reject");
    let repo_root = tmp.path().join("repo");
    fs::create_dir_all(&repo_root).unwrap();
    let suite_dir = tmp.path().join("suite");
    fs::create_dir_all(&suite_dir).unwrap();

    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("create-save-reject")),
        ],
        || {
            let _ = create_begin_cmd(CreateBeginArgs {
                repo_root: repo_root.to_string_lossy().to_string(),
                feature: "mesh".to_string(),
                mode: "interactive".to_string(),
                suite_dir: suite_dir.to_string_lossy().to_string(),
                suite_name: "install".to_string(),
            })
            .execute();

            let result = create_save_cmd(CreateSaveArgs {
                kind: "schema".to_string(),
                payload: Some(String::new()),
                input: None,
            })
            .execute();
            assert!(result.is_err(), "empty payload should be rejected");
        },
    );
}
