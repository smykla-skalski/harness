use tempfile::tempdir;

use super::*;
use crate::session::service as session_service;
use crate::session::storage;
use crate::session::types::SessionRole;

const LEGACY_KEY_SESSION_ID: &str = "00000000-0000-4001-8000-000000000003";

#[test]
fn resolve_session_id_uses_legacy_session_key_only_for_unbound_agents() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let project_dir = tmp.path().join("workspace").join("alpha");
        harness_testkit::init_git_repo_with_seed(&project_dir);

        let active = temp_env::with_var("CLAUDE_SESSION_ID", Some("leader-runtime"), || {
            let state = session_service::start_session(
                "ctx",
                "title",
                &project_dir,
                Some(LEGACY_KEY_SESSION_ID),
            )
            .expect("start session");
            session_service::join_session(
                &state.session_id,
                SessionRole::Leader,
                "claude",
                &[],
                None,
                &project_dir,
                None,
            )
            .expect("join leader")
        });
        let leader_id = active.leader_id.expect("leader id");

        temp_env::with_vars(
            [
                ("CODEX_SESSION_ID", None::<&str>),
                ("CODEX_THREAD_ID", None::<&str>),
            ],
            || {
                session_service::join_session(
                    LEGACY_KEY_SESSION_ID,
                    SessionRole::Worker,
                    "codex",
                    &[],
                    None,
                    &project_dir,
                    None,
                )
                .expect("join worker");
            },
        );

        let project = discovered_project_for_checkout(&project_dir);
        let worker_id = load_session_state(&project, LEGACY_KEY_SESSION_ID)
            .expect("load state")
            .expect("state")
            .agents
            .keys()
            .find(|agent_id| agent_id.as_str() != leader_id)
            .cloned()
            .expect("worker id");

        let legacy_match =
            resolve_session_id_for_runtime_session(&project, "codex", LEGACY_KEY_SESSION_ID)
                .expect("legacy runtime session");
        assert_eq!(legacy_match.as_deref(), Some(LEGACY_KEY_SESSION_ID));

        let layout =
            storage::layout_from_project_dir(&project_dir, LEGACY_KEY_SESSION_ID).expect("layout");
        storage::update_state(&layout, |state| {
            let worker = state.agents.get_mut(&worker_id).expect("worker");
            worker.agent_session_id = Some("runtime-worker-1".into());
            Ok(())
        })
        .expect("bind worker runtime session");

        let bound_match =
            resolve_session_id_for_runtime_session(&project, "codex", LEGACY_KEY_SESSION_ID)
                .expect("bound lookup");
        assert!(bound_match.is_none());

        let explicit_match =
            resolve_session_id_for_runtime_session(&project, "codex", "runtime-worker-1")
                .expect("explicit lookup");
        assert_eq!(explicit_match.as_deref(), Some(LEGACY_KEY_SESSION_ID));
    });
}
