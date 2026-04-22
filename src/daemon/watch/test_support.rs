use std::path::Path;

use fs_err as fs;
use harness_testkit::with_isolated_harness_env;
use tempfile::tempdir;

use crate::session::service as session_service;
use crate::session::types::{SessionRole, SessionState};

pub(super) fn with_temp_project<F: FnOnce(&Path)>(test_fn: F) {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        temp_env::with_var("CLAUDE_SESSION_ID", Some("leader-session"), || {
            let project = tmp.path().join("project");
            fs::create_dir_all(&project).expect("create project dir");
            test_fn(&project);
        });
    });
}

pub(super) fn start_active_session(
    project_dir: &Path,
    session_id: &str,
    context: &str,
) -> SessionState {
    let state = session_service::start_session(context, "", project_dir, Some(session_id))
        .expect("start session");
    session_service::join_session(
        &state.session_id,
        SessionRole::Leader,
        "claude",
        &[],
        Some("leader"),
        project_dir,
        None,
    )
    .expect("join leader")
}

pub(super) fn append_project_ledger_entry(project_dir: &Path) {
    let ledger_path = crate::workspace::project_context_dir(project_dir)
        .join("agents")
        .join("ledger")
        .join("events.jsonl");
    fs::create_dir_all(ledger_path.parent().expect("ledger dir")).expect("create ledger dir");
    fs::write(
        &ledger_path,
        format!(
            "{{\"sequence\":1,\"recorded_at\":\"2026-03-28T12:00:00Z\",\"cwd\":\"{}\"}}\n",
            project_dir.display()
        ),
    )
    .expect("write ledger");
}
