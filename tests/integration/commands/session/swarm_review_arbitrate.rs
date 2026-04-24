use harness::session::service;
use harness::session::types::{ReviewVerdict, TaskStatus};

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
