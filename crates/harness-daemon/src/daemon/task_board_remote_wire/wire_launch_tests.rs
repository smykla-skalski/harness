use super::wire::{RemoteAttemptBinding, RemoteCodexLaunchEnvelope, RemoteWireError};
use crate::daemon::protocol::{CodexRunMode, CodexRunRequest};
use crate::session::types::{CONTROL_PLANE_ACTOR_ID, SessionRole};
use crate::task_board::{TaskBoardExecutionPhase, TaskBoardWorkflowKind};

#[test]
fn review_and_evaluate_launches_preserve_nondefault_profile_contract() {
    for (phase, action) in [
        (TaskBoardExecutionPhase::Review, "review:security"),
        (TaskBoardExecutionPhase::Evaluate, "evaluate:1"),
    ] {
        let request = report_request(action);
        let launch = RemoteCodexLaunchEnvelope::from_codex_request("codex", &request)
            .expect("freeze nondefault report launch");
        launch
            .validate(&binding(phase, action))
            .expect("validate exact report launch");
        assert_request(&launch.codex_request(), &request);
    }
}

#[test]
fn implementation_launch_preserves_task_item_and_write_capabilities() {
    let request = implementation_request();
    let launch = RemoteCodexLaunchEnvelope::from_codex_request("codex", &request)
        .expect("freeze implementation launch");
    launch
        .validate(&binding(
            TaskBoardExecutionPhase::Implementation,
            "implementation:1",
        ))
        .expect("validate exact implementation launch");
    let reconstructed = launch.codex_request();
    assert_request(&reconstructed, &request);
    assert_eq!(reconstructed.task_id.as_deref(), Some("task-17"));
    assert_eq!(reconstructed.board_item_id.as_deref(), Some("item-17"));
    assert!(
        reconstructed
            .capabilities
            .contains(&"task-board:workflow:write".to_string())
    );
}

#[test]
fn phase_and_custom_model_tampering_fail_closed() {
    let mut launch =
        RemoteCodexLaunchEnvelope::from_codex_request("codex", &report_request("review:security"))
            .expect("freeze report launch");
    launch.allow_custom_model = true;
    assert_eq!(
        launch.validate(&binding(TaskBoardExecutionPhase::Review, "review:security")),
        Err(RemoteWireError::MissingField("canonical_codex_launch"))
    );

    let mut implementation =
        RemoteCodexLaunchEnvelope::from_codex_request("codex", &implementation_request())
            .expect("freeze implementation launch");
    implementation.task_id = None;
    assert_eq!(
        implementation.validate(&binding(
            TaskBoardExecutionPhase::Implementation,
            "implementation:1"
        )),
        Err(RemoteWireError::ResultBindingMismatch)
    );
}

fn report_request(action: &str) -> CodexRunRequest {
    CodexRunRequest {
        actor: Some(CONTROL_PLANE_ACTOR_ID.into()),
        prompt: format!("Run the exact {action} contract"),
        mode: CodexRunMode::Report,
        role: SessionRole::Leader,
        fallback_role: Some(SessionRole::Worker),
        capabilities: vec![
            "task-board".into(),
            "task-board:tag:security".into(),
            format!("task-board:attempt:{action}"),
        ],
        name: Some("Task Board Review: Harden transport".into()),
        persona: Some("security-reviewer".into()),
        resume_thread_id: None,
        task_id: None,
        board_item_id: Some("item-17".into()),
        workflow_execution_id: Some("execution-17".into()),
        model: Some("gpt-5.4".into()),
        effort: Some("xhigh".into()),
        allow_custom_model: false,
    }
}

fn implementation_request() -> CodexRunRequest {
    CodexRunRequest {
        actor: Some(CONTROL_PLANE_ACTOR_ID.into()),
        prompt: "Implement the exact approved plan".into(),
        mode: CodexRunMode::WorkspaceWrite,
        role: SessionRole::Leader,
        fallback_role: Some(SessionRole::Worker),
        capabilities: vec![
            "task-board".into(),
            "task-board:item:item-17".into(),
            "task-board:workflow:write".into(),
        ],
        name: Some("Task Board Implementation: Harden transport".into()),
        persona: None,
        resume_thread_id: None,
        task_id: Some("task-17".into()),
        board_item_id: Some("item-17".into()),
        workflow_execution_id: Some("execution-17".into()),
        model: None,
        effort: None,
        allow_custom_model: false,
    }
}

fn binding(phase: TaskBoardExecutionPhase, action_key: &str) -> RemoteAttemptBinding {
    RemoteAttemptBinding {
        assignment_id: "assignment-17".into(),
        execution_id: "execution-17".into(),
        phase,
        workflow_kind: TaskBoardWorkflowKind::DefaultTask,
        action_key: action_key.into(),
        attempt: 1,
        idempotency_key: "attempt-17".into(),
        host_id: "executor-a".into(),
        host_instance_id: "instance-a".into(),
        fencing_epoch: 1,
        configuration_revision: 7,
        execution_record_sha256: "a".repeat(64),
        repository: "example/harness".into(),
        base_revision: "1".repeat(40),
        expected_head_revision: None,
    }
}

fn assert_request(actual: &CodexRunRequest, expected: &CodexRunRequest) {
    assert_eq!(actual.actor, expected.actor);
    assert_eq!(actual.prompt, expected.prompt);
    assert_eq!(actual.mode, expected.mode);
    assert_eq!(actual.role, expected.role);
    assert_eq!(actual.fallback_role, expected.fallback_role);
    assert_eq!(actual.capabilities, expected.capabilities);
    assert_eq!(actual.name, expected.name);
    assert_eq!(actual.persona, expected.persona);
    assert_eq!(actual.resume_thread_id, expected.resume_thread_id);
    assert_eq!(actual.task_id, expected.task_id);
    assert_eq!(actual.board_item_id, expected.board_item_id);
    assert_eq!(actual.workflow_execution_id, expected.workflow_execution_id);
    assert_eq!(actual.model, expected.model);
    assert_eq!(actual.effort, expected.effort);
    assert_eq!(actual.allow_custom_model, expected.allow_custom_model);
}
