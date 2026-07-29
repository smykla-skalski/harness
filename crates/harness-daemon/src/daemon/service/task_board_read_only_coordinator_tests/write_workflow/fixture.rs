use std::collections::BTreeMap;

use crate::task_board::{
    AgentMode, TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION, TaskBoardExecutionOwnership,
    TaskBoardExecutionPhase, TaskBoardExecutionState, TaskBoardPullRequestHeadIdentity,
    TaskBoardPullRequestIdentity, TaskBoardReadOnlyRunContext, TaskBoardStatus,
    TaskBoardWorkflowExecutionArtifacts, TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind,
    TaskBoardWorkflowSnapshot, TaskBoardWorkflowStatus, TaskBoardWorkflowTransitionState,
    bind_plan_approval, build_planning_result,
};

use super::super::super::task_board_workflow_test_support::{TestDatabase, reviewers};
use super::super::fixture::{Fixture, NOW, insert_committed_admission};
use super::BASE_HEAD;

pub(super) async fn seed_write_execution(label: &str) -> Fixture {
    Box::pin(seed_write_execution_kind(
        label,
        TaskBoardWorkflowKind::DefaultTask,
    ))
    .await
}

pub(super) async fn seed_write_execution_kind(
    label: &str,
    workflow_kind: TaskBoardWorkflowKind,
) -> Fixture {
    Box::pin(seed_write_execution_configured(
        label,
        workflow_kind,
        Some(format!("work-coordinator-{label}")),
        None,
    ))
    .await
}

pub(super) async fn seed_write_execution_with_task(
    label: &str,
    task_id: Option<String>,
) -> Fixture {
    Box::pin(seed_write_execution_configured(
        label,
        TaskBoardWorkflowKind::DefaultTask,
        task_id,
        None,
    ))
    .await
}

pub(super) async fn seed_write_execution_with_retry_limit(
    label: &str,
    max_attempts: u32,
) -> Fixture {
    Box::pin(seed_write_execution_configured(
        label,
        TaskBoardWorkflowKind::DefaultTask,
        Some(format!("work-coordinator-{label}")),
        Some(max_attempts),
    ))
    .await
}

async fn seed_write_execution_configured(
    label: &str,
    workflow_kind: TaskBoardWorkflowKind,
    task_id: Option<String>,
    max_attempts: Option<u32>,
) -> Fixture {
    let test = TestDatabase::open().await;
    let item_id = format!("coordinator-{label}");
    let execution_id = format!("execution-{label}");
    let mut settings = crate::task_board::TaskBoardOrchestratorSettings {
        policy_version: "policy-v1".into(),
        ..crate::task_board::TaskBoardOrchestratorSettings::default()
    };
    if let Some(max_attempts) = max_attempts {
        settings.retry.max_attempts = max_attempts;
    }
    test.db
        .replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("seed settings");
    let mutation = test
        .db
        .create_task_board_item(write_item(label, &item_id, &execution_id, workflow_kind))
        .await
        .expect("create write item");
    let settings = test
        .db
        .task_board_orchestrator_settings_snapshot()
        .await
        .expect("settings snapshot");
    let resolved_reviewers = reviewers(1, 1);
    let snapshot = write_snapshot(
        label,
        &item_id,
        mutation.item_revision,
        settings.row_revision,
        settings.settings.policy_version,
        resolved_reviewers.clone(),
        workflow_kind,
    );
    let execution = write_execution(
        &item_id,
        &execution_id,
        snapshot,
        resolved_reviewers,
        task_id,
        workflow_kind,
    );
    test.db
        .create_or_load_task_board_workflow_execution(&execution)
        .await
        .expect("create write execution");
    insert_committed_admission(&test.db, &item_id, &execution_id, mutation.item_revision).await;
    Fixture {
        test,
        item_id,
        execution_id,
    }
}

fn write_item(
    label: &str,
    item_id: &str,
    execution_id: &str,
    workflow_kind: TaskBoardWorkflowKind,
) -> crate::task_board::TaskBoardItem {
    let mut item = crate::task_board::TaskBoardItem::new(
        item_id.to_string(),
        format!("Write workflow {label}"),
        "Implement and validate the approved change".into(),
        NOW.into(),
    );
    item.agent_mode = AgentMode::Headless;
    item.workflow_kind = workflow_kind;
    item.execution_repository = Some("example/compass".into());
    item.session_id = Some(format!("session-{item_id}"));
    item.work_item_id = Some(format!("work-{item_id}"));
    item.workflow.execution_id = Some(execution_id.to_string());
    item.workflow.status = TaskBoardWorkflowStatus::Running;
    item.workflow.current_step_id = Some("implementation".into());
    item.workflow.worktree = Some("/tmp/read-only-worktree".into());
    item.workflow.branch = Some(format!("c/{item_id}"));
    item.planning.summary = Some("# Plan\n\nImplement the approved change.".into());
    item.planning.approved_by = Some("lead".into());
    item.planning.approved_at = Some(NOW.into());
    item.status = TaskBoardStatus::InProgress;
    item
}

fn write_snapshot(
    label: &str,
    item_id: &str,
    item_revision: i64,
    settings_revision: i64,
    policy_version: String,
    reviewer: crate::task_board::TaskBoardResolvedReviewer,
    workflow_kind: TaskBoardWorkflowKind,
) -> TaskBoardWorkflowSnapshot {
    TaskBoardWorkflowSnapshot {
        workflow_kind,
        execution_repository: Some("example/compass".into()),
        item_revision,
        configuration_revision: u64::try_from(settings_revision).expect("settings revision"),
        policy_version,
        reviewer,
        read_only_run_context: Some(TaskBoardReadOnlyRunContext {
            schema_version: TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
            session_id: format!("session-{item_id}"),
            title: format!("Write workflow {label}"),
            body: "Implement and validate the approved change".into(),
            tags: Vec::new(),
            worktree: "/tmp/read-only-worktree".into(),
        }),
        provider_revision: None,
    }
}

fn write_execution(
    item_id: &str,
    execution_id: &str,
    snapshot: TaskBoardWorkflowSnapshot,
    resolved_reviewers: crate::task_board::TaskBoardResolvedReviewer,
    task_id: Option<String>,
    workflow_kind: TaskBoardWorkflowKind,
) -> TaskBoardWorkflowExecutionRecord {
    let planning_result = build_planning_result(
        "# Plan\n\nImplement the approved change.",
        ["Implement and validate the approved change".into()],
        &snapshot,
        execution_id,
    )
    .expect("planning result");
    let plan_approval = bind_plan_approval(&planning_result, &snapshot, execution_id, "lead", NOW)
        .expect("plan approval");
    let mut resources = BTreeMap::from([(
        "admission_owner".into(),
        crate::daemon::db::workflow_owner(execution_id),
    )]);
    if let Some(task_id) = task_id {
        resources.insert("task_id".into(), task_id);
    }
    TaskBoardWorkflowExecutionRecord {
        execution_id: execution_id.to_string(),
        item_id: item_id.to_string(),
        snapshot,
        resolved_reviewers,
        transition: TaskBoardWorkflowTransitionState {
            workflow_kind,
            phase: Some(TaskBoardExecutionPhase::Implementation),
            execution_state: TaskBoardExecutionState::Pending,
            pull_request: workflow_kind
                .is_pull_request()
                .then(|| TaskBoardPullRequestIdentity {
                    repository: "example/compass".into(),
                    number: 17,
                    head: Some(TaskBoardPullRequestHeadIdentity {
                        repository: "example/compass".into(),
                        branch: "renovate/dependency-update".into(),
                        revision: BASE_HEAD.into(),
                    }),
                }),
            exact_head_revision: Some(BASE_HEAD.into()),
        },
        artifacts: TaskBoardWorkflowExecutionArtifacts {
            planning_result: Some(planning_result),
            plan_approval: Some(plan_approval),
            ..TaskBoardWorkflowExecutionArtifacts::default()
        },
        ownership: TaskBoardExecutionOwnership {
            host_id: None,
            fencing_epoch: 0,
            resources,
        },
        available_at: None,
        blocked_reason: None,
        created_at: NOW.into(),
        updated_at: NOW.into(),
        completed_at: None,
        attempts: Vec::new(),
    }
}
