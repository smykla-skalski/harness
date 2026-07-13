use crate::daemon::protocol::CodexRunStatus;
use crate::session::types::TaskStatus;

use super::durable_run_request;
use super::test_support::{
    codex_run_snapshot, controller_with_session_state, sample_session_state_with_open_task,
};

const SESSION_ID: &str = "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc";

fn register_bound_worker(
    controller: &crate::daemon::codex_controller::CodexControllerHandle,
) -> String {
    let mut request = durable_run_request();
    request.task_id = Some("task-1".into());
    controller
        .register_orchestration_agent(SESSION_ID, "codex-run-1", &request, "Codex Worker")
        .expect("register bound worker")
}

#[test]
fn registration_assigns_bound_task_and_starts_it() {
    let (controller, db, _tempdir) =
        controller_with_session_state(sample_session_state_with_open_task());
    let agent_id = register_bound_worker(&controller);

    let state = db
        .lock()
        .expect("db lock")
        .load_session_state_for_mutation(SESSION_ID)
        .expect("load session")
        .expect("session");
    let task = state.tasks.get("task-1").expect("bound task");
    assert_eq!(task.status, TaskStatus::InProgress);
    assert_eq!(task.assigned_to.as_deref(), Some(agent_id.as_str()));
    assert_eq!(
        state.agents[&agent_id].current_task_id.as_deref(),
        Some("task-1")
    );
}

#[test]
fn registration_is_idempotent_for_same_managed_run() {
    let (controller, db, _tempdir) =
        controller_with_session_state(sample_session_state_with_open_task());
    let first_agent_id = register_bound_worker(&controller);
    let second_agent_id = register_bound_worker(&controller);

    assert_eq!(second_agent_id, first_agent_id);
    let state = db
        .lock()
        .expect("db lock")
        .load_session_state_for_mutation(SESSION_ID)
        .expect("load session")
        .expect("session");
    assert_eq!(state.agents.len(), 1);
    assert_eq!(state.tasks["task-1"].status, TaskStatus::InProgress);
}

#[test]
fn completed_bound_run_submits_task_for_review() {
    let (controller, db, _tempdir) =
        controller_with_session_state(sample_session_state_with_open_task());
    let agent_id = register_bound_worker(&controller);
    let mut run = codex_run_snapshot(CodexRunStatus::Completed);
    run.task_id = Some("task-1".into());
    run.session_agent_id = Some(agent_id);
    run.final_message = Some("Implemented the requested flow.".into());

    controller
        .sync_orchestration_status_for_run(&run)
        .expect("bridge completed run");

    let state = db
        .lock()
        .expect("db lock")
        .load_session_state_for_mutation(SESSION_ID)
        .expect("load session")
        .expect("session");
    let task = state.tasks.get("task-1").expect("bound task");
    assert_eq!(task.status, TaskStatus::AwaitingReview);
    assert_eq!(
        task.awaiting_review
            .as_ref()
            .and_then(|review| review.summary.as_deref()),
        Some("Implemented the requested flow.")
    );
}

#[test]
fn failed_bound_run_blocks_task() {
    let (controller, db, _tempdir) =
        controller_with_session_state(sample_session_state_with_open_task());
    let agent_id = register_bound_worker(&controller);
    let mut run = codex_run_snapshot(CodexRunStatus::Failed);
    run.task_id = Some("task-1".into());
    run.session_agent_id = Some(agent_id);
    run.error = Some("transport closed".into());

    controller
        .sync_orchestration_status_for_run(&run)
        .expect("bridge failed run");

    let state = db
        .lock()
        .expect("db lock")
        .load_session_state_for_mutation(SESSION_ID)
        .expect("load session")
        .expect("session");
    let task = state.tasks.get("task-1").expect("bound task");
    assert_eq!(task.status, TaskStatus::Blocked);
    assert_eq!(
        task.blocked_reason.as_deref(),
        Some("Codex run failed: transport closed")
    );
}

#[test]
fn stale_bound_run_blocks_task() {
    let (controller, db, _tempdir) =
        controller_with_session_state(sample_session_state_with_open_task());
    let agent_id = register_bound_worker(&controller);
    let mut run = codex_run_snapshot(CodexRunStatus::Running);
    run.task_id = Some("task-1".into());
    run.session_agent_id = Some(agent_id);

    controller.reconcile_run(run).expect("reconcile stale run");

    let state = db
        .lock()
        .expect("db lock")
        .load_session_state_for_mutation(SESSION_ID)
        .expect("load session")
        .expect("session");
    assert_eq!(state.tasks["task-1"].status, TaskStatus::Blocked);
}
