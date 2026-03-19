// Tests for session stop cleanup.
// Verifies ephemeral MetalLB template cleanup and pointer file removal.

use std::fs;

use harness::core_defs::current_run_context_path;
use harness::platform::ephemeral_metallb;
use harness::run::context::{CurrentRunRecord, RunLayout};
use harness::setup::SessionStopArgs;

use super::super::helpers::*;

#[test]
fn session_stop_cleans_up_templates_and_removes_pointer() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg");
    let run_dir = init_run(tmp.path(), "run-stop", "single-zone");

    // Create ephemeral templates
    let mk_dir = tmp.path().join("mk");
    fs::create_dir_all(&mk_dir).unwrap();
    fs::write(mk_dir.join("metallb-k3d-kuma.yaml"), "template").unwrap();
    ephemeral_metallb::ensure_templates(tmp.path(), &["local"], Some(&run_dir)).unwrap();
    let template = ephemeral_metallb::template_path(tmp.path(), "local").unwrap();
    assert!(template.exists());

    // Write a current-run pointer
    let record = CurrentRunRecord {
        layout: RunLayout::from_run_dir(&run_dir),
        profile: Some("single-zone".into()),
        repo_root: None,
        suite_dir: None,
        suite_id: None,
        suite_path: None,
        cluster: None,
        keep_clusters: false,
        user_stories: vec![],
        requires: vec![],
    };

    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("stop-test")),
        ],
        || {
            let ctx_path = current_run_context_path().unwrap();
            if let Some(parent) = ctx_path.parent() {
                fs::create_dir_all(parent).unwrap();
            }
            fs::write(&ctx_path, serde_json::to_string_pretty(&record).unwrap()).unwrap();
            assert!(ctx_path.exists());

            let code =
                run_command(session_stop_cmd(SessionStopArgs { project_dir: None })).unwrap();
            assert_eq!(code, 0);

            // Template should be cleaned up
            assert!(!template.exists(), "template should have been removed");
            // Pointer should be removed
            assert!(!ctx_path.exists(), "pointer should have been removed");
        },
    );
}

#[test]
fn session_stop_returns_ok_with_no_pointer() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg");

    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("no-pointer-test")),
        ],
        || {
            let code =
                run_command(session_stop_cmd(SessionStopArgs { project_dir: None })).unwrap();
            assert_eq!(code, 0);
        },
    );
}

#[test]
fn session_stop_rejects_corrupt_pointer_json() {
    let tmp = tempfile::tempdir().unwrap();
    let xdg = tmp.path().join("xdg");

    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg.to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("corrupt-json-test")),
        ],
        || {
            let ctx_path = current_run_context_path().unwrap();
            if let Some(parent) = ctx_path.parent() {
                fs::create_dir_all(parent).unwrap();
            }
            fs::write(&ctx_path, "not valid json {{{{").unwrap();
            assert!(ctx_path.exists());

            let error =
                run_command(session_stop_cmd(SessionStopArgs { project_dir: None })).unwrap_err();
            assert_eq!(error.code(), "KSRCLI019");
            assert!(
                ctx_path.exists(),
                "corrupt pointer should be preserved for inspection"
            );
        },
    );
}
