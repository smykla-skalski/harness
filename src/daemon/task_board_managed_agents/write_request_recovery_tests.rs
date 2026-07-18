use std::collections::BTreeMap;

use crate::task_board::{
    AgentMode, TaskBoardAttemptState, TaskBoardExecutionAttemptRecord, TaskBoardExecutionOwnership,
    TaskBoardExecutionPhase, TaskBoardExecutionState, TaskBoardWorkflowExecutionArtifacts,
    TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowSnapshot, TaskBoardWorkflowTransitionState,
    TaskBoardWriteWorkflowLaunch, validate_task_board_read_only_run_context,
};

use super::super::codex_worker_request;
use super::super::test_support::applied_task;
use super::write_launch;

#[test]
fn durable_initial_write_request_matches_the_managed_launch() {
    let mut applied = applied_task(AgentMode::Headless);
    let launch = write_launch();
    applied.write_workflow = Some(Box::new(launch.clone()));
    let run_id = "codex-implementation-attempt";
    let managed = codex_worker_request(&applied, run_id);
    let attempt = TaskBoardExecutionAttemptRecord {
        execution_id: "workflow-1".into(),
        action_key: "implementation:1".into(),
        attempt: 1,
        idempotency_key: run_id.into(),
        state: TaskBoardAttemptState::Running,
        failure_class: None,
        available_at: None,
        error: None,
        artifact: None,
        started_at: "2026-07-18T10:00:00Z".into(),
        updated_at: "2026-07-18T10:00:00Z".into(),
        completed_at: None,
    };
    let execution = TaskBoardWorkflowExecutionRecord {
        execution_id: "workflow-1".into(),
        item_id: "board-1".into(),
        snapshot: TaskBoardWorkflowSnapshot {
            workflow_kind: launch.workflow_kind,
            execution_repository: launch.execution_repository.clone(),
            item_revision: 3,
            configuration_revision: launch.configuration_revision,
            policy_version: launch.policy_version.clone(),
            reviewer: launch.resolved_reviewers.clone(),
            read_only_run_context: Some(launch.run_context.clone()),
            provider_revision: launch.provider_revision.clone(),
        },
        resolved_reviewers: launch.resolved_reviewers,
        transition: TaskBoardWorkflowTransitionState {
            workflow_kind: launch.workflow_kind,
            phase: Some(TaskBoardExecutionPhase::Implementation),
            execution_state: TaskBoardExecutionState::Running,
            pull_request: launch.pull_request,
            exact_head_revision: Some(launch.base_head_revision),
        },
        artifacts: TaskBoardWorkflowExecutionArtifacts {
            planning_result: Some(launch.planning_result),
            plan_approval: Some(launch.plan_approval),
            ..TaskBoardWorkflowExecutionArtifacts::default()
        },
        ownership: TaskBoardExecutionOwnership {
            host_id: None,
            fencing_epoch: 0,
            resources: BTreeMap::from([("task_id".into(), launch.task_id)]),
        },
        available_at: None,
        blocked_reason: None,
        created_at: "2026-07-18T10:00:00Z".into(),
        updated_at: "2026-07-18T10:00:00Z".into(),
        completed_at: None,
        attempts: vec![attempt.clone()],
    };

    let recovered =
        crate::daemon::service::task_board_read_only_coordinator::requests::codex_attempt_request(
            &execution, &attempt,
        )
        .expect("reconstruct durable request");

    assert_eq!(
        serde_json::to_value(recovered).expect("serialize recovered request"),
        serde_json::to_value(managed).expect("serialize managed request")
    );
}

#[test]
fn legacy_write_launch_decodes_to_invalid_empty_identity() {
    let mut value = serde_json::to_value(write_launch()).expect("serialize write launch");
    let object = value.as_object_mut().expect("write launch object");
    object.remove("task_id");
    object.remove("run_context");

    let decoded = serde_json::from_value::<TaskBoardWriteWorkflowLaunch>(value)
        .expect("decode legacy write launch");

    assert!(decoded.task_id.is_empty());
    assert!(validate_task_board_read_only_run_context(&decoded.run_context).is_err());
}
