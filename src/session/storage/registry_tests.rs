use crate::workspace::layout::SessionLayout;

use super::registry::{
    ProjectOriginRecord, deregister_active, load_active_registry_for_layout, merge_project_origin,
    register_active,
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
    assert_eq!(
        registry.sessions.len(),
        1,
        "expected 1 session after deregister"
    );
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
    assert_eq!(expected, tmp.path().join("sessions/demo/.active.json"),);
}

#[test]
fn merge_project_origin_preserves_existing_git_identity() {
    let merged = merge_project_origin(
        ProjectOriginRecord {
            recorded_from_dir: "/repo/.claude/worktrees/feature".to_string(),
            repository_root: None,
            checkout_root: None,
            adopted_session_roots: Default::default(),
            recorded_at: "2026-04-10T10:00:00Z".to_string(),
        },
        Some(&ProjectOriginRecord {
            recorded_from_dir: "/repo/.claude/worktrees/feature".to_string(),
            repository_root: Some("/repo".to_string()),
            checkout_root: Some("/repo/.claude/worktrees/feature".to_string()),
            adopted_session_roots: std::collections::BTreeMap::from([(
                "abc12345".to_string(),
                "/tmp/external/demo/abc12345".to_string(),
            )]),
            recorded_at: "2026-04-10T09:00:00Z".to_string(),
        }),
    );

    assert_eq!(merged.repository_root.as_deref(), Some("/repo"));
    assert_eq!(
        merged.checkout_root.as_deref(),
        Some("/repo/.claude/worktrees/feature")
    );
    assert_eq!(
        merged
            .adopted_session_roots
            .get("abc12345")
            .map(std::string::String::as_str),
        Some("/tmp/external/demo/abc12345")
    );
}
