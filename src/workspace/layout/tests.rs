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

#[test]
fn project_dir_composes() {
    assert_eq!(fixture().project_dir(), PathBuf::from("/data/sessions/kuma"));
}

#[test]
fn log_file_sibling() {
    assert_eq!(fixture().log_file(), PathBuf::from("/data/sessions/kuma/abc12345/log.jsonl"));
}

#[test]
fn tasks_and_locks_subdirs() {
    assert_eq!(fixture().tasks_dir(), PathBuf::from("/data/sessions/kuma/abc12345/tasks"));
    assert_eq!(fixture().locks_dir(), PathBuf::from("/data/sessions/kuma/abc12345/.locks"));
}

#[test]
fn origin_marker_in_session_root() {
    assert_eq!(
        fixture().origin_marker(),
        PathBuf::from("/data/sessions/kuma/abc12345/.origin"),
    );
}

#[test]
fn sessions_root_helper_appends_sessions_segment() {
    assert_eq!(
        sessions_root(&PathBuf::from("/data")),
        PathBuf::from("/data/sessions"),
    );
}
