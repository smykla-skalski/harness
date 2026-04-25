use harness::session::service;
use harness::session::types::{AgentStatus, ReviewVerdict, TaskStatus};

use super::swarm_review_helpers::{prepare_in_progress_task, setup_two_reviewers_on_claimed_task};
use super::with_session_test_env;

fn drive_to_round_three_dispute(
    session_id: &str,
    project: &std::path::Path,
) -> (String, String, String) {
    let (worker_id, task_id, gemini_id, claude_id) =
        setup_two_reviewers_on_claimed_task(session_id, project);
    let leader_id = service::session_status(session_id, project)
        .unwrap()
        .leader_id
        .unwrap();

    for round in 0..3 {
        service::submit_review(
            session_id,
            &task_id,
            &gemini_id,
            ReviewVerdict::RequestChanges,
            &format!("round {round} rework"),
            vec![harness::session::types::ReviewPoint {
                point_id: format!("p{round}"),
                text: "tighten".to_string(),
                state: harness::session::types::ReviewPointState::Open,
                worker_note: None,
            }],
            project,
        )
        .unwrap();
        service::submit_review(
            session_id,
            &task_id,
            &claude_id,
            ReviewVerdict::RequestChanges,
            "agree",
            vec![],
            project,
        )
        .unwrap();
        service::respond_review(
            session_id,
            &task_id,
            &worker_id,
            &[],
            &[format!("p{round}")],
            Some("intentional"),
            project,
        )
        .unwrap();
    }

    (leader_id, worker_id, task_id)
}

#[test]
fn arbitrate_leader_approves_and_closes_task_as_done() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-arb-approve", || {
        let project = tmp.path().join("project");
        let (leader_id, _worker, task_id) = drive_to_round_three_dispute("arb-1", &project);

        service::arbitrate(
            "arb-1",
            &task_id,
            &leader_id,
            ReviewVerdict::Approve,
            "shipping",
            &project,
        )
        .expect("arbitrate approve");

        let state = service::session_status("arb-1", &project).unwrap();
        let task = state.tasks.get(&task_id).unwrap();
        assert_eq!(task.status, TaskStatus::Done);
        let outcome = task.arbitration.as_ref().expect("arbitration recorded");
        assert_eq!(outcome.arbiter_agent_id, leader_id);
        assert_eq!(outcome.verdict, ReviewVerdict::Approve);
        assert!(task.completed_at.is_some());
    });
}

#[test]
fn arbitrate_rejects_non_leader() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-arb-nonleader", || {
        let project = tmp.path().join("project");
        let (_leader, worker_id, task_id) = drive_to_round_three_dispute("arb-2", &project);

        let result = service::arbitrate(
            "arb-2",
            &task_id,
            &worker_id,
            ReviewVerdict::Approve,
            "",
            &project,
        );
        assert!(result.is_err(), "non-leader cannot arbitrate");
    });
}

#[test]
fn third_round_dispute_transitions_task_to_blocked_awaiting_arbitration() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-arb-blocked", || {
        let project = tmp.path().join("project");
        let (_leader, _worker, task_id) = drive_to_round_three_dispute("arb-blocked", &project);

        let state = service::session_status("arb-blocked", &project).unwrap();
        let task = state.tasks.get(&task_id).unwrap();
        assert_eq!(
            task.status,
            TaskStatus::Blocked,
            "unresolved third-round dispute must move task to Blocked"
        );
        assert_eq!(
            task.blocked_reason.as_deref(),
            Some("awaiting_arbitration"),
            "Blocked reason must marker awaiting_arbitration"
        );
        assert_eq!(task.review_round, 3);
    });
}

#[test]
fn arbitrate_rework_returns_task_to_in_progress_with_worker_reassigned() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-arb-rework", || {
        let project = tmp.path().join("project");
        let (leader_id, worker_id, task_id) = drive_to_round_three_dispute("arb-rw", &project);

        service::arbitrate(
            "arb-rw",
            &task_id,
            &leader_id,
            ReviewVerdict::RequestChanges,
            "worker must implement reviewer changes",
            &project,
        )
        .expect("arbitrate rework");

        let state = service::session_status("arb-rw", &project).unwrap();
        let task = state.tasks.get(&task_id).unwrap();
        assert_eq!(task.status, TaskStatus::InProgress);
        assert_eq!(task.assigned_to.as_deref(), Some(worker_id.as_str()));
        assert!(task.consensus.is_none(), "consensus cleared on rework");
        assert!(
            task.review_claim.is_none(),
            "reviewer claim cleared on rework"
        );
        assert!(
            task.awaiting_review.is_none(),
            "awaiting_review cleared on rework"
        );
        let outcome = task.arbitration.as_ref().expect("arbitration recorded");
        assert_eq!(outcome.verdict, ReviewVerdict::RequestChanges);
        let worker = state.agents.get(&worker_id).unwrap();
        assert_eq!(worker.status, AgentStatus::Active);
        assert_eq!(worker.current_task_id.as_deref(), Some(task_id.as_str()));
    });
}

#[test]
fn arbitrate_rejects_task_not_awaiting_arbitration() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-arb-notblocked", || {
        let project = tmp.path().join("project");
        // InReview task at round 0 never reached arbitration state.
        let (_worker, task_id, _gemini, _claude) =
            super::swarm_review_helpers::setup_two_reviewers_on_claimed_task("arb-nb", &project);
        let leader_id = service::session_status("arb-nb", &project)
            .unwrap()
            .leader_id
            .unwrap();

        // Even manually bumping rounds via submit_review isn't possible without
        // disputes; here verify that the task (which has round=0, status=InReview)
        // cannot be arbitrated.
        let err = service::arbitrate(
            "arb-nb",
            &task_id,
            &leader_id,
            ReviewVerdict::Approve,
            "",
            &project,
        )
        .expect_err("arbitrate must reject non-arbitration-state task");
        assert!(
            err.to_string().contains("arbitration")
                || err.to_string().contains("Blocked")
                || err.to_string().contains("awaiting_arbitration")
                || err.to_string().contains("review_round")
                || err.to_string().contains("rounds"),
            "error should mention arbitration state, got: {err}"
        );
    });
}

#[test]
fn arbitrate_requires_three_completed_rounds() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-arb-early", || {
        let project = tmp.path().join("project");
        let (_leader, _worker, task_id) = prepare_in_progress_task("arb-3", &project);
        let state = service::session_status("arb-3", &project).unwrap();
        let leader_id = state.leader_id.unwrap();

        let result = service::arbitrate(
            "arb-3",
            &task_id,
            &leader_id,
            ReviewVerdict::Approve,
            "",
            &project,
        );
        assert!(
            result.is_err(),
            "arbitration must wait until three review rounds have elapsed"
        );
    });
}
