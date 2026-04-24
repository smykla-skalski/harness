use harness::session::service;
use harness::session::types::{AgentStatus, SessionRole, TaskSeverity, TaskStatus};

use super::with_session_test_env;

/// Helper: start session, join one worker, create + assign + start a task.
/// Returns `(leader_id, worker_id, task_id)`.
fn join_leader(session_id: &str, project: &std::path::Path) -> String {
    let state = service::join_session(
        session_id,
        SessionRole::Leader,
        "claude",
        &[],
        Some("leader"),
        project,
        None,
    )
    .unwrap();
    state
        .agents
        .values()
        .find(|agent| agent.role == SessionRole::Leader)
        .expect("leader joined")
        .agent_id
        .clone()
}

fn prepare_in_progress_task(
    session_id: &str,
    project: &std::path::Path,
) -> (String, String, String) {
    service::start_session_with_policy(
        "",
        "review flow",
        project,
        Some(session_id),
        Some("swarm-default"),
    )
    .unwrap();
    let leader_id = join_leader(session_id, project);

    let joined = service::join_session(
        session_id,
        SessionRole::Worker,
        "codex",
        &[],
        None,
        project,
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
        session_id,
        "ship review flow",
        None,
        TaskSeverity::Medium,
        &leader_id,
        project,
    )
    .unwrap();
    service::assign_task(session_id, &task.task_id, &worker_id, &leader_id, project).unwrap();
    service::update_task(
        session_id,
        &task.task_id,
        TaskStatus::InProgress,
        None,
        &worker_id,
        project,
    )
    .unwrap();

    (leader_id, worker_id, task.task_id)
}

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
            "review flow",
            &project,
            Some("submit-rev-3"),
            Some("swarm-default"),
        )
        .unwrap();
        let leader_id = join_leader("submit-rev-3", &project);
        let joined = service::join_session(
            "submit-rev-3",
            SessionRole::Worker,
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
            "open task",
            None,
            TaskSeverity::Low,
            &leader_id,
            &project,
        )
        .unwrap();
        service::assign_task("submit-rev-3", &task.task_id, &worker_id, &leader_id, &project)
            .unwrap();

        let result =
            service::submit_for_review("submit-rev-3", &task.task_id, &worker_id, None, &project);
        assert!(result.is_err(), "open task cannot be submitted");
    });
}

fn join_reviewer(
    session_id: &str,
    runtime: &str,
    runtime_session_env: &str,
    project: &std::path::Path,
) -> String {
    let joined = temp_env::with_var(runtime_session_env, Some("rev-session"), || {
        service::join_session(
            session_id,
            SessionRole::Reviewer,
            runtime,
            &[],
            None,
            project,
            None,
        )
        .unwrap()
    });
    joined
        .agents
        .values()
        .filter(|agent| agent.role == SessionRole::Reviewer && agent.runtime == runtime)
        .max_by(|a, b| a.joined_at.cmp(&b.joined_at))
        .expect("reviewer joined")
        .agent_id
        .clone()
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

        let second = temp_env::with_var("GEMINI_SESSION_ID", Some("rev-session-2"), || {
            service::join_session(
                "claim-dup-1",
                SessionRole::Reviewer,
                "gemini",
                &[],
                Some("gemini-two"),
                &project,
                None,
            )
            .unwrap()
        });
        let second_id = second
            .agents
            .values()
            .filter(|agent| agent.role == SessionRole::Reviewer && agent.runtime == "gemini")
            .map(|agent| agent.agent_id.clone())
            .find(|id| id != &first)
            .expect("second gemini reviewer joined");

        let result = service::claim_review("claim-dup-1", &task_id, &second_id, &project);
        let err = result.expect_err("second same-runtime claim must fail");
        assert!(
            err.to_string().contains("runtime_already_reviewing"),
            "expected runtime_already_reviewing in error, got: {err}"
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

        let first = join_reviewer("claim-multi-1", "gemini", "GEMINI_SESSION_ID", &project);
        service::claim_review("claim-multi-1", &task_id, &first, &project).unwrap();

        let second = join_reviewer("claim-multi-1", "copilot", "COPILOT_SESSION_ID", &project);
        service::claim_review("claim-multi-1", &task_id, &second, &project)
            .expect("cross-runtime claim");

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
