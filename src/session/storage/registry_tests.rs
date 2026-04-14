use super::registry::{deregister_active, load_active_registry_for, register_active};

#[test]
fn active_registry_round_trip() {
    let tmp = tempfile::tempdir().expect("tempdir");
    temp_env::with_vars(
        [
            (
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            ),
            ("CLAUDE_SESSION_ID", Some("test-registry")),
        ],
        || {
            let project = tmp.path().join("project");
            register_active(&project, "sess-a").expect("register a");
            register_active(&project, "sess-b").expect("register b");
            let registry = load_active_registry_for(&project);
            assert_eq!(registry.sessions.len(), 2);
            deregister_active(&project, "sess-a").expect("remove a");
            let registry = load_active_registry_for(&project);
            assert_eq!(registry.sessions.len(), 1);
            assert!(registry.sessions.contains_key("sess-b"));
        },
    );
}
