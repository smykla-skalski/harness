//! Integration coverage for the `spawn_reviewer` auto-emission path
//! on `submit_for_review` when no reviewer is present.

use harness::session::service;
use harness::session::types::SessionRole;

use super::swarm_review_helpers::{join_reviewer, prepare_in_progress_task};
use super::{session_uuid, with_session_test_env};

#[test]
fn submit_for_review_with_no_reviewer_emits_spawn_reviewer_signal() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-auto-spawn", || {
        let project = tmp.path().join("project");
        let session_id = session_uuid("auto-1");
        let (_leader_id, worker_id, task_id) = prepare_in_progress_task(&session_id, &project);

        service::submit_for_review(&session_id, &task_id, &worker_id, None, &project).unwrap();

        let signals = service::list_signals(&session_id, None, &project).expect("list signals");
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
        let state = service::session_status(&session_id, &project).unwrap();
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
        let session_id = session_uuid("auto-2");
        let (_leader_id, worker_id, task_id) = prepare_in_progress_task(&session_id, &project);
        let _reviewer = join_reviewer(&session_id, "gemini", "GEMINI_SESSION_ID", &project);

        service::submit_for_review(&session_id, &task_id, &worker_id, None, &project).unwrap();

        let signals = service::list_signals(&session_id, None, &project).expect("list signals");
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
