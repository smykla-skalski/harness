use crate::workspace::layout::SessionLayout;

use super::registry::{
    deregister_active, load_active_registry_for_layout, register_active,
};

fn layout(tmp: &std::path::Path, session_id: &str) -> SessionLayout {
    SessionLayout {
        sessions_root: tmp.join("sessions"),
        project_name: "demo".into(),
        session_id: session_id.to_string(),
    }
}

#[test]
fn active_registry_round_trip() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let layout_a = layout(tmp.path(), "sess-a");
    let layout_b = layout(tmp.path(), "sess-b");

    // Ensure the project dir exists so the lock file can be created.
    fs_err::create_dir_all(layout_a.project_dir()).expect("create project dir");

    register_active(&layout_a).expect("register a");
    register_active(&layout_b).expect("register b");

    let registry = load_active_registry_for_layout(&layout_a);
    assert_eq!(registry.sessions.len(), 2, "expected 2 sessions");

    deregister_active(&layout_a).expect("remove a");
    let registry = load_active_registry_for_layout(&layout_a);
    assert_eq!(registry.sessions.len(), 1, "expected 1 session after deregister");
    assert!(registry.sessions.contains_key("sess-b"));
}

#[test]
fn registry_stored_at_project_dir_active_json() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let layout = layout(tmp.path(), "abc12345");
    fs_err::create_dir_all(layout.project_dir()).expect("create project dir");

    register_active(&layout).expect("register");

    let expected = layout.active_registry();
    assert!(expected.exists(), ".active.json must exist at project dir");
    assert_eq!(
        expected,
        tmp.path().join("sessions/demo/.active.json"),
    );
}
