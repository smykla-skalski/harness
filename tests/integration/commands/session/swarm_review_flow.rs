use harness::session::service;
use harness::session::types::{AgentStatus, TaskSeverity, TaskStatus};

use super::swarm_review_helpers::{join_reviewer, prepare_in_progress_task};
use super::with_session_test_env;

#[test]
fn submit_for_review_moves_task_to_awaiting_review_and_unassigns_worker() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-submit-review", || {
        let project = tmp.path().join("project");
        let (_, worker_id, task_id) = prepare_in_progress_task("submit-rev-1", &project);

        service::submit_for_review(
            "submit-rev-1",
            &task_id,
            &worker_id,
            Some("ready for review"),
            &project,
        )
        .expect("submit for review");

        let state = service::session_status("submit-rev-1", &project).unwrap();
        let task = state.tasks.get(&task_id).expect("task present");
        assert_eq!(task.status, TaskStatus::AwaitingReview);
        assert!(task.assigned_to.is_none());
        let awaiting = task.awaiting_review.as_ref().expect("awaiting_review set");
        assert_eq!(awaiting.submitter_agent_id, worker_id);
        assert_eq!(awaiting.summary.as_deref(), Some("ready for review"));
        assert_eq!(awaiting.required_consensus, 2);

        let worker = state.agents.get(&worker_id).expect("worker present");
        assert_eq!(worker.status, AgentStatus::AwaitingReview);
        assert!(worker.current_task_id.is_none());
    });
}

#[test]
fn submit_for_review_rejects_non_assignee() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-submit-rev-other", || {
        let project = tmp.path().join("project");
        let (leader_id, _worker_id, task_id) = prepare_in_progress_task("submit-rev-2", &project);

        let result =
            service::submit_for_review("submit-rev-2", &task_id, &leader_id, None, &project);
        assert!(result.is_err(), "leader should not submit worker's task");
    });
}

#[test]
fn submit_for_review_requires_in_progress_status() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-submit-rev-open", || {
        let project = tmp.path().join("project");
        service::start_session_with_policy(
            "",
            "ctx",
            &project,
            Some("submit-rev-3"),
            Some("swarm-default"),
        )
        .unwrap();
        let leader_id = super::swarm_review_helpers::join_leader("submit-rev-3", &project);
        let joined = service::join_session(
            "submit-rev-3",
            harness::session::types::SessionRole::Worker,
            "codex",
            &[],
            None,
            &project,
            None,
        )
        .unwrap();
        let worker_id = joined
            .agents
            .keys()
            .find(|id| id.starts_with("codex"))
            .unwrap()
            .clone();
        let task = service::create_task(
            "submit-rev-3",
            "open still",
            None,
            TaskSeverity::Medium,
            &leader_id,
            &project,
        )
        .unwrap();
        let result =
            service::submit_for_review("submit-rev-3", &task.task_id, &worker_id, None, &project);
        assert!(result.is_err(), "open task cannot be submitted");
    });
}

#[test]
fn claim_review_transitions_task_to_in_review_and_records_reviewer() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-claim-review", || {
        let project = tmp.path().join("project");
        let (_, worker_id, task_id) = prepare_in_progress_task("claim-rev-1", &project);
        service::submit_for_review("claim-rev-1", &task_id, &worker_id, None, &project).unwrap();

        let reviewer_id = join_reviewer("claim-rev-1", "gemini", "GEMINI_SESSION_ID", &project);
        service::claim_review("claim-rev-1", &task_id, &reviewer_id, &project)
            .expect("claim review");

        let state = service::session_status("claim-rev-1", &project).unwrap();
        let task = state.tasks.get(&task_id).unwrap();
        assert_eq!(task.status, TaskStatus::InReview);
        let claim = task.review_claim.as_ref().expect("claim present");
        assert_eq!(claim.reviewers.len(), 1);
        assert_eq!(claim.reviewers[0].reviewer_agent_id, reviewer_id);
        assert_eq!(claim.reviewers[0].reviewer_runtime, "gemini");
    });
}

#[test]
fn claim_review_rejects_same_runtime_second_reviewer() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-claim-dup", || {
        let project = tmp.path().join("project");
        let (_, worker_id, task_id) = prepare_in_progress_task("claim-dup-1", &project);
        service::submit_for_review("claim-dup-1", &task_id, &worker_id, None, &project).unwrap();

        let first = join_reviewer("claim-dup-1", "gemini", "GEMINI_SESSION_ID", &project);
        service::claim_review("claim-dup-1", &task_id, &first, &project).unwrap();
        let second = join_reviewer("claim-dup-1", "gemini", "GEMINI_SESSION_ID", &project);
        let result = service::claim_review("claim-dup-1", &task_id, &second, &project);
        let err = result.expect_err("same-runtime second claim must fail");
        assert!(
            err.to_string().contains("runtime_already_reviewing"),
            "error should signal runtime_already_reviewing, got: {err}"
        );
    });
}

#[test]
fn claim_review_allows_second_reviewer_on_different_runtime() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-claim-multi", || {
        let project = tmp.path().join("project");
        let (_, worker_id, task_id) = prepare_in_progress_task("claim-multi-1", &project);
        service::submit_for_review("claim-multi-1", &task_id, &worker_id, None, &project).unwrap();

        let gemini_id = join_reviewer("claim-multi-1", "gemini", "GEMINI_SESSION_ID", &project);
        let copilot_id = join_reviewer("claim-multi-1", "copilot", "COPILOT_SESSION_ID", &project);
        service::claim_review("claim-multi-1", &task_id, &gemini_id, &project).unwrap();
        service::claim_review("claim-multi-1", &task_id, &copilot_id, &project).unwrap();

        let state = service::session_status("claim-multi-1", &project).unwrap();
        let task = state.tasks.get(&task_id).unwrap();
        let claim = task.review_claim.as_ref().unwrap();
        assert_eq!(claim.reviewers.len(), 2);
    });
}

#[test]
fn awaiting_review_worker_refuses_new_assignment() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-awaiting-refuse", || {
        let project = tmp.path().join("project");
        let (leader_id, worker_id, task_id) = prepare_in_progress_task("awaiting-refuse-1", &project);

        service::submit_for_review("awaiting-refuse-1", &task_id, &worker_id, None, &project)
            .expect("submit");

        let second = service::create_task(
            "awaiting-refuse-1",
            "second task",
            None,
            TaskSeverity::Medium,
            &leader_id,
            &project,
        )
        .unwrap();

        let result = service::assign_task(
            "awaiting-refuse-1",
            &second.task_id,
            &worker_id,
            &leader_id,
            &project,
        );
        assert!(
            result.is_err(),
            "assigning to awaiting-review worker must fail"
        );
    });
}

#[test]
fn update_task_rejects_direct_awaiting_review_transition() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-update-reject-ar", || {
        let project = tmp.path().join("project");
        let (_, worker_id, task_id) = prepare_in_progress_task("update-reject-1", &project);

        let result = service::update_task(
            "update-reject-1",
            &task_id,
            TaskStatus::AwaitingReview,
            None,
            &worker_id,
            &project,
        );
        let err = result.expect_err("direct AwaitingReview via update_task must fail");
        assert!(
            err.to_string().contains("submit_for_review"),
            "error should steer caller to submit_for_review, got: {err}"
        );
    });
}

#[test]
fn update_task_rejects_direct_in_review_transition() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-update-reject-ir", || {
        let project = tmp.path().join("project");
        let (leader_id, _worker_id, task_id) = prepare_in_progress_task("update-reject-2", &project);

        let result = service::update_task(
            "update-reject-2",
            &task_id,
            TaskStatus::InReview,
            None,
            &leader_id,
            &project,
        );
        let err = result.expect_err("direct InReview via update_task must fail");
        assert!(
            err.to_string().contains("claim_review"),
            "error should steer caller to claim_review, got: {err}"
        );
    });
}

#[test]
fn update_task_rejects_generic_status_on_awaiting_review_task() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-update-no-bypass", || {
        let project = tmp.path().join("project");
        let (leader_id, worker_id, task_id) =
            prepare_in_progress_task("update-no-bypass", &project);
        service::submit_for_review("update-no-bypass", &task_id, &worker_id, None, &project)
            .unwrap();

        // Now task is AwaitingReview. Generic update to Done/Blocked/Open/InProgress
        // must be rejected so review metadata can't be silently rewritten.
        for status in [
            TaskStatus::Done,
            TaskStatus::Blocked,
            TaskStatus::Open,
            TaskStatus::InProgress,
        ] {
            let err = service::update_task(
                "update-no-bypass",
                &task_id,
                status,
                None,
                &leader_id,
                &project,
            )
            .expect_err("generic update on AwaitingReview must fail");
            assert!(
                err.to_string().contains("respond_review")
                    || err.to_string().contains("arbitrate"),
                "error should steer caller to review primitives, got: {err}"
            );
        }
    });
}

#[test]
fn assign_task_rejects_awaiting_review_task() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-assign-no-bypass", || {
        let project = tmp.path().join("project");
        let (leader_id, worker_id, task_id) =
            prepare_in_progress_task("assign-no-bypass", &project);
        service::submit_for_review("assign-no-bypass", &task_id, &worker_id, None, &project)
            .unwrap();

        // Second fresh worker so the task-level guard runs even though the
        // original submitter is stuck in AgentStatus::AwaitingReview.
        let second_worker = temp_env::with_var("GEMINI_SESSION_ID", Some("fresh-worker"), || {
            service::join_session(
                "assign-no-bypass",
                harness::session::types::SessionRole::Worker,
                "gemini",
                &[],
                None,
                &project,
                None,
            )
            .unwrap()
        });
        let fresh_id = second_worker
            .agents
            .values()
            .find(|agent| agent.runtime == "gemini")
            .unwrap()
            .agent_id
            .clone();
        let err = service::assign_task(
            "assign-no-bypass",
            &task_id,
            &fresh_id,
            &leader_id,
            &project,
        )
        .expect_err("assign on AwaitingReview must fail");
        assert!(
            err.to_string().contains("reassigned")
                || err.to_string().contains("respond_review"),
            "error should steer caller to review primitives, got: {err}"
        );

        // Task metadata must remain intact.
        let state = service::session_status("assign-no-bypass", &project).unwrap();
        let task = state.tasks.get(&task_id).unwrap();
        assert_eq!(task.status, TaskStatus::AwaitingReview);
        assert!(task.awaiting_review.is_some());
        assert!(task.assigned_to.is_none());
        // Submitter stays AwaitingReview until review closes.
        assert_eq!(
            state.agents.get(&worker_id).unwrap().status,
            AgentStatus::AwaitingReview
        );
    });
}
