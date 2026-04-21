use std::path::Path;

use fs_err as fs;
use harness_testkit::with_isolated_harness_env;
use tempfile::tempdir;

use crate::daemon::index::{
    discover_sessions_for, discovered_project_for_checkout, resolve_session,
};
use crate::daemon::{db::DaemonDb, service::adopt_session_record};
use crate::session::types::CURRENT_VERSION;
use crate::workspace::adopter::SessionAdopter;

fn write_text(path: &Path, contents: &str) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("create parent");
    }
    fs::write(path, contents).expect("write file");
}

fn write_adoptable_session(session_root: &Path, session_id: &str, origin: &Path) {
    fs::create_dir_all(session_root.join("workspace")).expect("create workspace");
    fs::create_dir_all(session_root.join("memory")).expect("create memory");
    let state = serde_json::json!({
        "schema_version": CURRENT_VERSION,
        "state_version": 0,
        "session_id": session_id,
        "project_name": session_root
            .parent()
            .and_then(Path::file_name)
            .expect("project name")
            .to_string_lossy(),
        "origin_path": origin,
        "worktree_path": session_root.join("workspace"),
        "shared_path": session_root.join("memory"),
        "branch_ref": format!("harness/{session_id}"),
        "title": "Adopted Session",
        "context": "external session stays discoverable",
        "status": "active",
        "created_at": "2026-04-20T00:00:00Z",
        "updated_at": "2026-04-20T00:00:00Z",
    });
    write_text(
        &session_root.join("state.json"),
        &serde_json::to_string_pretty(&state).expect("serialize state"),
    );
    write_text(&session_root.join(".origin"), &origin.display().to_string());
}

#[test]
fn discover_sessions_finds_adopted_external_session_root() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let project_dir = tmp.path().join("workspace").join("alpha");
        harness_testkit::init_git_repo_with_seed(&project_dir);

        let session_id = "adopted01";
        let session_root = tmp
            .path()
            .join("external-sessions")
            .join("alpha")
            .join(session_id);
        write_adoptable_session(&session_root, session_id, &project_dir);

        let probed = SessionAdopter::probe(&session_root).expect("probe adopted session");
        let data_root_sessions =
            crate::workspace::layout::sessions_root(&crate::workspace::harness_data_root());
        let outcome =
            SessionAdopter::register(probed, &data_root_sessions).expect("register adoption");
        let db = DaemonDb::open_in_memory().expect("open db");
        adopt_session_record(&outcome, &db).expect("record adoption");

        crate::session::storage::update_state(&outcome.layout, |state| {
            state.context = "updated adopted context".into();
            Ok(())
        })
        .expect("update adopted state");

        let project = discovered_project_for_checkout(&project_dir);
        let discovered =
            discover_sessions_for(std::slice::from_ref(&project), true).expect("discover");
        assert_eq!(discovered.len(), 1);
        assert_eq!(discovered[0].state.session_id, session_id);
        assert_eq!(discovered[0].state.context, "updated adopted context");
        assert_eq!(
            discovered[0].state.external_origin.as_deref(),
            Some(session_root.as_path())
        );

        let resolved = resolve_session(session_id).expect("resolve adopted session");
        assert_eq!(resolved.state.context, "updated adopted context");
        assert_eq!(
            resolved.state.external_origin.as_deref(),
            Some(session_root.as_path())
        );
    });
}
