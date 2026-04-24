use harness::session::service;
use harness::session::types::{SessionRole, TaskSeverity, TaskStatus};

/// Join a Leader agent via `claude` runtime and return its agent id.
pub(super) fn join_leader(session_id: &str, project: &std::path::Path) -> String {
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

/// Start a session, join a leader and a codex worker, create and assign a
/// task, and drive it to `InProgress`. Returns `(leader_id, worker_id,
/// task_id)`.
pub(super) fn prepare_in_progress_task(
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

/// Join a reviewer under a deterministic runtime session id so agent ids
/// stay unique across calls.
pub(super) fn join_reviewer(
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

/// Drive a task all the way through submit_for_review and two reviewer
/// claims (gemini + claude). Returns `(worker_id, task_id, gemini_id,
/// claude_id)`.
pub(super) fn setup_two_reviewers_on_claimed_task(
    session_id: &str,
    project: &std::path::Path,
) -> (String, String, String, String) {
    let (_leader, worker_id, task_id) = prepare_in_progress_task(session_id, project);
    service::submit_for_review(session_id, &task_id, &worker_id, None, project).unwrap();
    let gemini_id = join_reviewer(session_id, "gemini", "GEMINI_SESSION_ID", project);
    let claude_id = join_reviewer(session_id, "claude", "CLAUDE_SESSION_ID", project);
    service::claim_review(session_id, &task_id, &gemini_id, project).unwrap();
    service::claim_review(session_id, &task_id, &claude_id, project).unwrap();
    (worker_id, task_id, gemini_id, claude_id)
}
