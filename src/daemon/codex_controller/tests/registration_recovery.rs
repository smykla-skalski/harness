use crate::daemon::protocol::CodexRunRequest;
use crate::session::storage as session_storage;
use crate::session::types::{
    AgentStatus, ManagedAgentRef, SessionTransition, TaskNote, TaskQueuePolicy, TaskStatus,
};

use super::durable_run_request;
use super::test_support::{
    controller_with_async_session_state, controller_with_session_state,
    sample_session_state_with_open_task, sample_session_state_with_open_task_and_codex_agent,
    with_isolated_async_harness_env,
};

const SESSION_ID: &str = "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc";
const IDEMPOTENT_SESSION_ID: &str = "11111111-1111-4111-8111-111111111111";
const COMPENSATION_SESSION_ID: &str = "22222222-2222-4222-8222-222222222222";
const TASK_UPDATE_SESSION_ID: &str = "33333333-3333-4333-8333-333333333333";
const AGENT_UPDATE_SESSION_ID: &str = "44444444-4444-4444-8444-444444444444";

fn bound_request() -> CodexRunRequest {
    let mut request = durable_run_request();
    request.task_id = Some("task-1".into());
    request
}

fn state_for_session(
    session_id: &str,
    mut state: crate::session::types::SessionState,
) -> crate::session::types::SessionState {
    state.session_id = session_id.into();
    state
}

#[test]
fn idempotent_registration_does_not_duplicate_join_log() {
    let (controller, db, _tempdir) =
        controller_with_session_state(state_for_session(
            IDEMPOTENT_SESSION_ID,
            sample_session_state_with_open_task(),
        ));
    let request = bound_request();
    for _ in 0..2 {
        controller
            .register_orchestration_agent(
                IDEMPOTENT_SESSION_ID,
                "codex-run-1",
                &request,
                "Codex Worker",
            )
            .expect("idempotent registration");
    }

    let entries = db
        .lock()
        .expect("db lock")
        .load_session_log(IDEMPOTENT_SESSION_ID)
        .expect("load session log");
    assert_eq!(
        entries
            .iter()
            .filter(|entry| matches!(entry.transition, SessionTransition::AgentJoined { .. }))
            .count(),
        1
    );
}

#[test]
fn snapshot_failure_rollback_compensates_join_log() {
    let (controller, db, _tempdir) =
        controller_with_session_state(state_for_session(
            COMPENSATION_SESSION_ID,
            sample_session_state_with_open_task(),
        ));
    let registration = controller
        .register_orchestration_agent(
            COMPENSATION_SESSION_ID,
            "codex-run-1",
            &bound_request(),
            "Codex Worker",
        )
        .expect("registration");

    controller.rollback_orchestration_agent_registration(
        COMPENSATION_SESSION_ID,
        &registration.agent_id,
        &ManagedAgentRef::codex("codex-run-1"),
        &registration.mutation,
    );

    let db = db.lock().expect("db lock");
    let state = db
        .load_session_state_for_mutation(COMPENSATION_SESSION_ID)
        .expect("load session")
        .expect("session");
    assert!(state.agents.is_empty());
    let entries = db
        .load_session_log(COMPENSATION_SESSION_ID)
        .expect("load session log");
    assert!(matches!(entries[0].transition, SessionTransition::AgentJoined { .. }));
    assert!(matches!(entries[1].transition, SessionTransition::AgentRemoved { .. }));
}

#[test]
fn snapshot_failure_rollback_preserves_concurrent_task_update() {
    let (controller, db, _tempdir) =
        controller_with_session_state(state_for_session(
            TASK_UPDATE_SESSION_ID,
            sample_session_state_with_open_task(),
        ));
    let registration = controller
        .register_orchestration_agent(
            TASK_UPDATE_SESSION_ID,
            "codex-run-1",
            &bound_request(),
            "Codex Worker",
        )
        .expect("registration");
    {
        let db = db.lock().expect("db lock");
        let mut state = db
            .load_session_state_for_mutation(TASK_UPDATE_SESSION_ID)
            .expect("load session")
            .expect("session");
        state.tasks.get_mut("task-1").expect("task").notes.push(TaskNote {
            timestamp: "2026-04-09T10:00:04Z".into(),
            agent_id: Some(registration.agent_id.clone()),
            text: "Concurrent checkpoint detail".into(),
        });
        db.save_session_state("project-1", &state)
            .expect("save concurrent update");
    }

    controller.rollback_orchestration_agent_registration(
        TASK_UPDATE_SESSION_ID,
        &registration.agent_id,
        &ManagedAgentRef::codex("codex-run-1"),
        &registration.mutation,
    );

    let state = db
        .lock()
        .expect("db lock")
        .load_session_state_for_mutation(TASK_UPDATE_SESSION_ID)
        .expect("load session")
        .expect("session");
    assert!(state.agents.contains_key(&registration.agent_id));
    assert_eq!(state.tasks["task-1"].notes.len(), 1);
    assert_eq!(state.tasks["task-1"].status, TaskStatus::InProgress);
}

#[test]
fn snapshot_failure_rollback_preserves_concurrent_agent_update() {
    let (controller, db, _tempdir) =
        controller_with_session_state(state_for_session(
            AGENT_UPDATE_SESSION_ID,
            sample_session_state_with_open_task(),
        ));
    let registration = controller
        .register_orchestration_agent(
            AGENT_UPDATE_SESSION_ID,
            "codex-run-1",
            &bound_request(),
            "Codex Worker",
        )
        .expect("registration");
    {
        let db = db.lock().expect("db lock");
        let mut state = db
            .load_session_state_for_mutation(AGENT_UPDATE_SESSION_ID)
            .expect("load session")
            .expect("session");
        state
            .agents
            .get_mut(&registration.agent_id)
            .expect("registered agent")
            .status = AgentStatus::AwaitingReview;
        db.save_session_state("project-1", &state)
            .expect("save concurrent update");
    }

    controller.rollback_orchestration_agent_registration(
        AGENT_UPDATE_SESSION_ID,
        &registration.agent_id,
        &ManagedAgentRef::codex("codex-run-1"),
        &registration.mutation,
    );

    let state = db
        .lock()
        .expect("db lock")
        .load_session_state_for_mutation(AGENT_UPDATE_SESSION_ID)
        .expect("load session")
        .expect("session");
    assert_eq!(
        state.agents[&registration.agent_id].status,
        AgentStatus::AwaitingReview
    );
    assert_eq!(state.tasks["task-1"].status, TaskStatus::InProgress);
}

#[tokio::test(flavor = "multi_thread")]
async fn failed_registration_restores_preexisting_queued_task() {
    with_isolated_async_harness_env(|_| async move {
        let mut initial = sample_session_state_with_open_task_and_codex_agent();
        let task = initial.tasks.get_mut("task-1").expect("task");
        task.assigned_to = Some("agent-1".into());
        task.queue_policy = TaskQueuePolicy::ReassignWhenFree;
        task.queued_at = Some("2026-04-09T10:00:03Z".into());
        let expected = task.clone();
        let (controller, db, tempdir) = controller_with_async_session_state(initial).await;
        let layout = session_storage::layout_from_project_dir(
            &tempdir.path().join("project"),
            SESSION_ID,
        )
        .expect("session layout");
        fs_err::remove_dir_all(layout.session_root()).expect("remove session mirror root");
        fs_err::write(layout.session_root(), "not a directory")
            .expect("block session mirror root");

        controller
            .register_orchestration_agent(
                SESSION_ID,
                "codex-run-1",
                &bound_request(),
                "Codex Worker",
            )
            .expect_err("mirror failure must fail registration");

        let resolved = db
            .resolve_session(SESSION_ID)
            .await
            .expect("load session")
            .expect("session");
        let task = &resolved.state.tasks["task-1"];
        assert_eq!(task.status, TaskStatus::Open);
        assert_eq!(task.assigned_to, expected.assigned_to);
        assert_eq!(task.queue_policy, expected.queue_policy);
        assert_eq!(task.queued_at, expected.queued_at);
        assert!(resolved.state.agents["agent-1"].current_task_id.is_none());
    })
    .await;
}
