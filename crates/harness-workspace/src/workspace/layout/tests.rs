use super::*;
use std::path::PathBuf;

const SESSION_ID: &str = "00000000-0000-4000-8000-000000000201";

fn fixture() -> SessionLayout {
    SessionLayout {
        sessions_root: PathBuf::from("/data/sessions"),
        project_name: "kuma".into(),
        session_id: SESSION_ID.into(),
    }
}

#[test]
fn session_root_composes_correctly() {
    assert_eq!(
        fixture().session_root(),
        PathBuf::from(format!("/data/sessions/kuma/{SESSION_ID}"))
    );
}

#[test]
fn workspace_subdir() {
    assert_eq!(
        fixture().workspace(),
        PathBuf::from(format!("/data/sessions/kuma/{SESSION_ID}/workspace"))
    );
}

#[test]
fn memory_subdir() {
    assert_eq!(
        fixture().memory(),
        PathBuf::from(format!("/data/sessions/kuma/{SESSION_ID}/memory"))
    );
}

#[test]
fn state_file_sibling() {
    assert_eq!(
        fixture().state_file(),
        PathBuf::from(format!("/data/sessions/kuma/{SESSION_ID}/state.json"))
    );
}

#[test]
fn branch_ref_flat() {
    assert_eq!(fixture().branch_ref(), format!("harness/{SESSION_ID}"));
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
    assert_eq!(
        fixture().project_dir(),
        PathBuf::from("/data/sessions/kuma")
    );
}

#[test]
fn log_file_sibling() {
    assert_eq!(
        fixture().log_file(),
        PathBuf::from(format!("/data/sessions/kuma/{SESSION_ID}/log.jsonl"))
    );
}

#[test]
fn tasks_and_locks_subdirs() {
    assert_eq!(
        fixture().tasks_dir(),
        PathBuf::from(format!("/data/sessions/kuma/{SESSION_ID}/tasks"))
    );
    assert_eq!(
        fixture().locks_dir(),
        PathBuf::from(format!("/data/sessions/kuma/{SESSION_ID}/.locks"))
    );
}

#[test]
fn origin_marker_in_session_root() {
    assert_eq!(
        fixture().origin_marker(),
        PathBuf::from(format!("/data/sessions/kuma/{SESSION_ID}/.origin")),
    );
}

#[test]
fn sessions_root_helper_appends_sessions_segment() {
    assert_eq!(
        sessions_root(&PathBuf::from("/data")),
        PathBuf::from("/data/sessions"),
    );
}
