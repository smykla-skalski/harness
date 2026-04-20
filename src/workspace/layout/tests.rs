use std::path::PathBuf;
use super::*;

fn fixture() -> SessionLayout {
    SessionLayout {
        sessions_root: PathBuf::from("/data/sessions"),
        project_name: "kuma".into(),
        session_id: "abc12345".into(),
    }
}

#[test]
fn session_root_composes_correctly() {
    assert_eq!(fixture().session_root(), PathBuf::from("/data/sessions/kuma/abc12345"));
}

#[test]
fn workspace_subdir() {
    assert_eq!(fixture().workspace(), PathBuf::from("/data/sessions/kuma/abc12345/workspace"));
}

#[test]
fn memory_subdir() {
    assert_eq!(fixture().memory(), PathBuf::from("/data/sessions/kuma/abc12345/memory"));
}

#[test]
fn state_file_sibling() {
    assert_eq!(fixture().state_file(), PathBuf::from("/data/sessions/kuma/abc12345/state.json"));
}

#[test]
fn branch_ref_flat() {
    assert_eq!(fixture().branch_ref(), "harness/abc12345");
}

#[test]
fn active_json_is_per_project_hidden_file() {
    assert_eq!(
        fixture().active_registry(),
        PathBuf::from("/data/sessions/kuma/.active.json")
    );
}
