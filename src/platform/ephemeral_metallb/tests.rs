use std::fs;
use std::path::{Path, PathBuf};

use super::*;

#[test]
fn state_path_includes_state_dir() {
    let path = state_path(Path::new("/runs/r1"));
    assert_eq!(
        path,
        PathBuf::from("/runs/r1/state/ephemeral-metallb-templates.json")
    );
}

#[test]
fn cleanup_resources_removes_recorded_files() {
    let dir = tempfile::tempdir().unwrap();
    let run_dir = dir.path().join("run");
    let state_dir = run_dir.join("state");
    fs::create_dir_all(&state_dir).unwrap();
    let generated = dir.path().join(".kuma-dev").join("metallb-kuma-local.yaml");
    fs::create_dir_all(generated.parent().unwrap()).unwrap();
    fs::write(&generated, "generated").unwrap();
    fs::write(
        state_dir.join(STATE_FILE),
        serde_json::json!({
            "schema_version": 1,
            "entries": [{
                "template_path": generated,
            }],
        })
        .to_string(),
    )
    .unwrap();

    let removed = cleanup_resources(&run_dir).unwrap();
    assert_eq!(removed.len(), 1);
    assert!(!generated.exists());
}

#[test]
fn cleanup_resources_returns_empty_when_no_state() {
    let dir = tempfile::tempdir().unwrap();
    let removed = cleanup_resources(dir.path()).unwrap();
    assert!(removed.is_empty());
}

#[test]
fn load_entries_propagates_corrupt_state() {
    let dir = tempfile::tempdir().unwrap();
    let run_dir = dir.path().join("run");
    let state_dir = run_dir.join("state");
    fs::create_dir_all(&state_dir).unwrap();
    fs::write(state_dir.join(STATE_FILE), "not json {").unwrap();
    let err = load_entries(Some(&run_dir)).unwrap_err();
    assert_eq!(err.code(), "KSRCLI019");
}
