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
