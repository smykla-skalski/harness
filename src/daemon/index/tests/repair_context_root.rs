use super::*;
use crate::hooks::adapters::HookAgent;

#[test]
fn repair_context_root_keeps_agent_only_context_without_git_checkout() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let project_dir = tmp.path().join("project-no-git");
        fs::create_dir_all(&project_dir).expect("create project dir");
        crate::agents::storage::append_session_marker(
            &project_dir,
            HookAgent::Codex,
            "codex-session",
            "session_start",
        )
        .expect("write agent ledger");
        let context_root = project_context_dir(&project_dir);
        assert!(context_root.is_dir(), "agent-only context should exist");

        let repaired = repair_context_root(&context_root).expect("repair context root");

        assert_eq!(repaired.as_deref(), Some(context_root.as_path()));
        assert!(
            context_root.is_dir(),
            "agent-only context should not be pruned during discovery"
        );
    });
}
