use harness::session::service;
use harness::session::types::{AgentStatus, TaskSeverity, TaskStatus};

use super::swarm_review_helpers::{join_reviewer, prepare_in_progress_task};
use super::{session_uuid, with_session_test_env};

#[test]
fn submit_for_review_moves_task_to_awaiting_review_and_unassigns_worker() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-submit-review", || {
        let project = tmp.path().join("project");
        let session_id = session_uuid("submit-rev-1");
        let (_, worker_id, task_id) = prepare_in_progress_task(&session_id, &project);

        service::submit_for_review(
            &session_id,
            &task_id,
            &worker_id,
            Some("ready for review"),
            &project,
        )
        .expect("submit for review");

        let state = service::session_status(&session_id, &project).unwrap();
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
        let session_id = session_uuid("submit-rev-2");
        let (leader_id, _worker_id, task_id) = prepare_in_progress_task(&session_id, &project);

        let result = service::submit_for_review(&session_id, &task_id, &leader_id, None, &project);
        assert!(result.is_err(), "leader should not submit worker's task");
    });
}

#[test]
fn submit_for_review_requires_in_progress_status() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-submit-rev-open", || {
        let project = tmp.path().join("project");
        let session_id = session_uuid("submit-rev-3");
        service::start_session_with_policy(
            "",
            "ctx",
            &project,
            Some(&session_id),
            Some("swarm-default"),
        )
        .unwrap();
        let leader_id = super::swarm_review_helpers::join_leader(&session_id, &project);
        let joined = service::join_session(
            &session_id,
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
            &session_id,
            "open still",
            None,
            TaskSeverity::Medium,
            &leader_id,
            &project,
        )
        .unwrap();
        let result =
            service::submit_for_review(&session_id, &task.task_id, &worker_id, None, &project);
        assert!(result.is_err(), "open task cannot be submitted");
    });
}

#[test]
fn claim_review_transitions_task_to_in_review_and_records_reviewer() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-claim-review", || {
        let project = tmp.path().join("project");
        let session_id = session_uuid("claim-rev-1");
        let (_, worker_id, task_id) = prepare_in_progress_task(&session_id, &project);
        service::submit_for_review(&session_id, &task_id, &worker_id, None, &project).unwrap();

        let reviewer_id = join_reviewer(&session_id, "gemini", "GEMINI_SESSION_ID", &project);
        service::claim_review(&session_id, &task_id, &reviewer_id, &project).expect("claim review");

        let state = service::session_status(&session_id, &project).unwrap();
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
        let session_id = session_uuid("claim-dup-1");
        let (_, worker_id, task_id) = prepare_in_progress_task(&session_id, &project);
        service::submit_for_review(&session_id, &task_id, &worker_id, None, &project).unwrap();

        let first = join_reviewer(&session_id, "gemini", "GEMINI_SESSION_ID", &project);
        service::claim_review(&session_id, &task_id, &first, &project).unwrap();
        let second = join_reviewer(&session_id, "gemini", "GEMINI_SESSION_ID", &project);
        let result = service::claim_review(&session_id, &task_id, &second, &project);
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
        let session_id = session_uuid("claim-multi-1");
        let (_, worker_id, task_id) = prepare_in_progress_task(&session_id, &project);
        service::submit_for_review(&session_id, &task_id, &worker_id, None, &project).unwrap();

        let gemini_id = join_reviewer(&session_id, "gemini", "GEMINI_SESSION_ID", &project);
        let copilot_id = join_reviewer(&session_id, "copilot", "COPILOT_SESSION_ID", &project);
        service::claim_review(&session_id, &task_id, &gemini_id, &project).unwrap();
        service::claim_review(&session_id, &task_id, &copilot_id, &project).unwrap();

        let state = service::session_status(&session_id, &project).unwrap();
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
        let session_id = session_uuid("awaiting-refuse-1");
        let (leader_id, worker_id, task_id) = prepare_in_progress_task(&session_id, &project);

        service::submit_for_review(&session_id, &task_id, &worker_id, None, &project)
            .expect("submit");

        let second = service::create_task(
            &session_id,
            "second task",
            None,
            TaskSeverity::Medium,
            &leader_id,
            &project,
        )
        .unwrap();

        let result = service::assign_task(
            &session_id,
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
        let session_id = session_uuid("update-reject-1");
        let (_, worker_id, task_id) = prepare_in_progress_task(&session_id, &project);

        let result = service::update_task(
            &session_id,
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
        let session_id = session_uuid("update-reject-2");
        let (leader_id, _worker_id, task_id) = prepare_in_progress_task(&session_id, &project);

        let result = service::update_task(
            &session_id,
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
        let session_id = session_uuid("update-no-bypass");
        let (leader_id, worker_id, task_id) = prepare_in_progress_task(&session_id, &project);
        service::submit_for_review(&session_id, &task_id, &worker_id, None, &project).unwrap();

        // Now task is AwaitingReview. Generic update to Done/Blocked/Open/InProgress
        // must be rejected so review metadata can't be silently rewritten.
        for status in [
            TaskStatus::Done,
            TaskStatus::Blocked,
            TaskStatus::Open,
            TaskStatus::InProgress,
        ] {
            let err =
                service::update_task(&session_id, &task_id, status, None, &leader_id, &project)
                    .expect_err("generic update on AwaitingReview must fail");
            assert!(
                err.to_string().contains("respond_review") || err.to_string().contains("arbitrate"),
                "error should steer caller to review primitives, got: {err}"
            );
        }
    });
}

#[test]
fn submit_for_review_stores_suggested_persona_on_task() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-persona-hint", || {
        let project = tmp.path().join("project");
        let session_id = session_uuid("persona-hint-1");
        let (_, worker_id, task_id) = prepare_in_progress_task(&session_id, &project);

        service::submit_for_review_with_persona(
            &session_id,
            &task_id,
            &worker_id,
            Some("ready"),
            Some("test-writer"),
            &project,
        )
        .expect("submit with persona");

        let state = service::session_status(&session_id, &project).unwrap();
        let task = state.tasks.get(&task_id).expect("task present");
        assert_eq!(task.suggested_persona.as_deref(), Some("test-writer"));
    });
}

#[test]
fn claim_review_second_claim_does_not_emit_false_status_change_log() {
    use harness::session::storage::layout_from_project_dir;
    use std::fs;

    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-claim-log", || {
        let project = tmp.path().join("project");
        let session_id = session_uuid("claim-log-1");
        let (_, worker_id, task_id) = prepare_in_progress_task(&session_id, &project);
        service::submit_for_review(&session_id, &task_id, &worker_id, None, &project).unwrap();

        let first = super::swarm_review_helpers::join_reviewer(
            &session_id,
            "gemini",
            "GEMINI_SESSION_ID",
            &project,
        );
        let second = super::swarm_review_helpers::join_reviewer(
            &session_id,
            "claude",
            "CLAUDE_SESSION_ID",
            &project,
        );
        service::claim_review(&session_id, &task_id, &first, &project).unwrap();
        service::claim_review(&session_id, &task_id, &second, &project).unwrap();

        let layout = layout_from_project_dir(&project, &session_id).unwrap();
        let log = fs::read_to_string(layout.log_file()).unwrap_or_default();
        let transitions: Vec<_> = log
            .lines()
            .filter(|line| line.contains("task_status_changed") && line.contains(&task_id))
            .collect();
        // Each AwaitingReview→InReview entry should appear at most once; the
        // second claim stayed in `InReview` and must not emit a fake
        // transition.
        let aw_to_ir = transitions
            .iter()
            .filter(|line| line.contains("awaiting_review") && line.contains("in_review"))
            .count();
        assert_eq!(
            aw_to_ir, 1,
            "second claim must not emit a spurious AwaitingReview→InReview log entry; got log: {log}"
        );
    });
}

#[test]
fn drop_task_rejects_review_state_task() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-drop-no-bypass", || {
        let project = tmp.path().join("project");
        let session_id = session_uuid("drop-no-bypass");
        let (leader_id, worker_id, task_id) = prepare_in_progress_task(&session_id, &project);
        service::submit_for_review(&session_id, &task_id, &worker_id, None, &project).unwrap();

        // Second fresh worker so drop target is valid for non-review guard.
        let second = temp_env::with_var("GEMINI_SESSION_ID", Some("drop-fresh"), || {
            service::join_session(
                &session_id,
                harness::session::types::SessionRole::Worker,
                "gemini",
                &[],
                None,
                &project,
                None,
            )
            .unwrap()
        });
        let fresh_id = second
            .agents
            .values()
            .find(|agent| agent.runtime == "gemini")
            .unwrap()
            .agent_id
            .clone();

        let err = service::drop_task(
            &session_id,
            &task_id,
            &harness::daemon::protocol::TaskDropTarget::Agent { agent_id: fresh_id },
            harness::session::types::TaskQueuePolicy::Locked,
            &leader_id,
            &project,
        )
        .expect_err("drop_task on AwaitingReview must fail");
        assert!(
            err.to_string().contains("respond_review")
                || err.to_string().contains("arbitrate")
                || err.to_string().contains("reassigned"),
            "error should steer caller to review primitives, got: {err}"
        );

        // Task metadata and status must remain intact.
        let state = service::session_status(&session_id, &project).unwrap();
        let task = state.tasks.get(&task_id).unwrap();
        assert_eq!(task.status, TaskStatus::AwaitingReview);
        assert!(task.awaiting_review.is_some());
        assert!(task.assigned_to.is_none());
        assert_eq!(
            state.agents.get(&worker_id).unwrap().status,
            AgentStatus::AwaitingReview
        );
    });
}

#[test]
fn assign_task_rejects_awaiting_review_task() {
    let tmp = tempfile::tempdir().unwrap();
    with_session_test_env(tmp.path(), "integ-assign-no-bypass", || {
        let project = tmp.path().join("project");
        let session_id = session_uuid("assign-no-bypass");
        let (leader_id, worker_id, task_id) = prepare_in_progress_task(&session_id, &project);
        service::submit_for_review(&session_id, &task_id, &worker_id, None, &project).unwrap();

        // Second fresh worker so the task-level guard runs even though the
        // original submitter is stuck in AgentStatus::AwaitingReview.
        let second_worker = temp_env::with_var("GEMINI_SESSION_ID", Some("fresh-worker"), || {
            service::join_session(
                &session_id,
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
        let err = service::assign_task(&session_id, &task_id, &fresh_id, &leader_id, &project)
            .expect_err("assign on AwaitingReview must fail");
        assert!(
            err.to_string().contains("reassigned") || err.to_string().contains("respond_review"),
            "error should steer caller to review primitives, got: {err}"
        );

        // Task metadata must remain intact.
        let state = service::session_status(&session_id, &project).unwrap();
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
