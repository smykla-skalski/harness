use std::path::Path;

use fs_err as fs;
use harness_testkit::with_isolated_harness_env;
use tempfile::tempdir;

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
