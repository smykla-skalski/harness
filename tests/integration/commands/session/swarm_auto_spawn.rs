//! Integration coverage for the `spawn_reviewer` auto-emission path
//! on `submit_for_review` when no reviewer is present.

use harness::session::service;
use harness::session::types::SessionRole;

use super::swarm_review_helpers::{join_reviewer, prepare_in_progress_task};
use super::with_session_test_env;

#[test]
fn submit_for_review_with_no_reviewer_emits_spawn_reviewer_signal() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-auto-spawn", || {
        let project = tmp.path().join("project");
        let (_leader_id, worker_id, task_id) = prepare_in_progress_task("auto-1", &project);

        service::submit_for_review("auto-1", &task_id, &worker_id, None, &project).unwrap();

        let signals = service::list_signals("auto-1", None, &project).expect("list signals");
        assert!(
            signals
                .iter()
                .any(|rec| rec.signal.command == "spawn_reviewer"),
            "expected spawn_reviewer signal, got {:?}",
            signals
                .iter()
                .map(|r| r.signal.command.clone())
                .collect::<Vec<_>>()
        );
        let leader = signals
            .iter()
            .find(|rec| rec.signal.command == "spawn_reviewer")
            .expect("spawn_reviewer record");
        // spawn_reviewer is addressed to the session leader.
        let state = service::session_status("auto-1", &project).unwrap();
        let leader_agent = state
            .agents
            .values()
            .find(|agent| agent.role == SessionRole::Leader)
            .expect("leader present");
        assert_eq!(leader.agent_id, leader_agent.agent_id);
    });
}

#[test]
fn submit_for_review_with_reviewer_does_not_emit_spawn_reviewer() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-auto-spawn-skip", || {
        let project = tmp.path().join("project");
        let (_leader_id, worker_id, task_id) = prepare_in_progress_task("auto-2", &project);
        let _reviewer = join_reviewer("auto-2", "gemini", "GEMINI_SESSION_ID", &project);

        service::submit_for_review("auto-2", &task_id, &worker_id, None, &project).unwrap();

        let signals = service::list_signals("auto-2", None, &project).expect("list signals");
        assert!(
            !signals
                .iter()
                .any(|rec| rec.signal.command == "spawn_reviewer"),
            "spawn_reviewer must NOT fire when a reviewer is already present; got {:?}",
            signals
                .iter()
                .map(|r| r.signal.command.clone())
                .collect::<Vec<_>>()
        );
    });
}
