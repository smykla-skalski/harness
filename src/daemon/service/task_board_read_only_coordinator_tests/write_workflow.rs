use std::collections::BTreeMap;

use crate::task_board::{
    AgentMode, TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION, TaskBoardAttemptResultArtifact,
    TaskBoardExecutionOwnership, TaskBoardExecutionPhase, TaskBoardExecutionState,
    TaskBoardPhaseVerdict, TaskBoardPlanApprovalInvalidation, TaskBoardReadOnlyRunContext,
    TaskBoardStatus, TaskBoardWorkflowExecutionArtifacts, TaskBoardWorkflowExecutionRecord,
    TaskBoardWorkflowKind, TaskBoardWorkflowSnapshot, TaskBoardWorkflowStatus,
    TaskBoardWorkflowTransitionState, bind_plan_approval, build_planning_result,
};

use super::super::task_board_read_only_coordinator::reconcile_task_board_read_only_workflows_with_runtime;
use super::super::task_board_workflow_test_support::{TestDatabase, reviewers};
use super::fixture::{Fixture, NOW, insert_committed_admission};
use runtime::{FakeWriteRuntime, PlannedRun};

mod runtime;

const BASE_HEAD: &str = "head-base";
const FIRST_HEAD: &str = "head-first";
const SECOND_HEAD: &str = "head-second";
const RETRY_AT: &str = "2026-07-17T10:05:00Z";

#[tokio::test]
async fn write_workflow_runs_revision_cycle_publish_cleanup_and_projection() {
    let fixture = seed_write_execution("write-lifecycle").await;
    let runtime = FakeWriteRuntime::new([
        PlannedRun::implementation(1, 1, BASE_HEAD, FIRST_HEAD),
        PlannedRun::review(1, FIRST_HEAD, TaskBoardPhaseVerdict::ChangesRequired),
        PlannedRun::implementation(2, 1, FIRST_HEAD, SECOND_HEAD),
        PlannedRun::review(2, SECOND_HEAD, TaskBoardPhaseVerdict::Pass),
        PlannedRun::evaluation(2, SECOND_HEAD),
    ]);

    drive_to_terminal(&fixture, &runtime).await;

    let execution = load_execution(&fixture).await;
    assert_eq!(execution.artifacts.current_revision_cycle, 2);
    assert_eq!(
        execution.transition.phase,
        Some(TaskBoardExecutionPhase::Terminal)
    );
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::Completed
    );
    assert_eq!(
        execution.transition.exact_head_revision.as_deref(),
        Some(SECOND_HEAD)
    );
    assert_eq!(
        execution
            .transition
            .pull_request
            .as_ref()
            .map(|pr| pr.number),
        Some(42)
    );
    assert_eq!(execution.artifacts.review_cycles.len(), 2);
    assert!(
        execution.attempts.iter().all(|attempt| {
            attempt.state == crate::task_board::TaskBoardAttemptState::Completed
        })
    );
    assert_eq!(runtime.start_count(), 5);
    assert_eq!(runtime.publish_count(), 1);
    let item = fixture
        .test
        .db
        .task_board_item(&fixture.item_id)
        .await
        .expect("load projected item");
    assert_eq!(item.status, TaskBoardStatus::Done);
    assert_eq!(item.workflow.status, TaskBoardWorkflowStatus::Completed);
    assert_eq!(item.workflow.pr_number, Some(42));
    assert_eq!(
        item.workflow.pr_url.as_deref(),
        Some("https://github.com/example/compass/pull/42")
    );
}

#[tokio::test]
async fn transient_publication_verification_recovers_on_bounded_retry() {
    let fixture = seed_write_execution("write-publication-verification-retry").await;
    let runtime = FakeWriteRuntime::new([
        PlannedRun::implementation(1, 1, BASE_HEAD, FIRST_HEAD),
        PlannedRun::review(1, FIRST_HEAD, TaskBoardPhaseVerdict::Pass),
        PlannedRun::evaluation(1, FIRST_HEAD),
    ]);
    runtime.fail_next_verification("GitHub head is not visible yet");

    for _ in 0..24 {
        tick(&fixture, &runtime).await;
        if runtime.verification_count() == 1 {
            break;
        }
    }
    let waiting = load_execution(&fixture).await;
    assert_eq!(runtime.publish_count(), 1);
    assert_eq!(runtime.verification_count(), 1);
    assert_eq!(
        waiting.transition.execution_state,
        TaskBoardExecutionState::Running
    );

    for _ in 0..12 {
        tick_at(&fixture, &runtime, RETRY_AT).await;
        if load_execution(&fixture).await.transition.phase
            == Some(TaskBoardExecutionPhase::Terminal)
        {
            break;
        }
    }
    let completed = load_execution(&fixture).await;
    assert_eq!(runtime.verification_count(), 2);
    assert_eq!(
        runtime.verification_urls(),
        vec![
            Some("https://github.com/example/compass/pull/42".into()),
            Some("https://github.com/example/compass/pull/42".into()),
        ]
    );
    assert_eq!(
        completed.transition.phase,
        Some(TaskBoardExecutionPhase::Terminal)
    );
    assert!(completed.attempts.iter().any(|attempt| {
        matches!(
            attempt.artifact.as_ref(),
            Some(TaskBoardAttemptResultArtifact::Lifecycle(outcome)) if outcome.mutated
        )
    }));
}

#[tokio::test]
async fn ambiguous_write_publication_is_verified_without_a_second_mutation() {
    let fixture = seed_write_execution("write-publication-ambiguous").await;
    let runtime = FakeWriteRuntime::new([
        PlannedRun::implementation(1, 1, BASE_HEAD, FIRST_HEAD),
        PlannedRun::review(1, FIRST_HEAD, TaskBoardPhaseVerdict::Pass),
        PlannedRun::evaluation(1, FIRST_HEAD),
    ]);
    runtime.fail_next_publish_after_mutation("connection closed after push");

    drive_to_terminal(&fixture, &runtime).await;

    assert_eq!(runtime.publish_count(), 1);
    assert_eq!(runtime.verification_count(), 1);
    assert_eq!(
        load_execution(&fixture).await.transition.phase,
        Some(TaskBoardExecutionPhase::Terminal)
    );
}

#[tokio::test]
async fn implementation_result_with_unrelated_base_is_rejected_before_review() {
    let fixture = seed_write_execution("write-unrelated-implementation").await;
    let runtime = FakeWriteRuntime::new([PlannedRun::implementation(1, 1, BASE_HEAD, FIRST_HEAD)]);
    runtime.reject_implementation_ancestry();

    for _ in 0..4 {
        tick(&fixture, &runtime).await;
    }

    let execution = load_execution(&fixture).await;
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(
        execution.blocked_reason.as_deref(),
        Some("implementation_ancestry_invalid")
    );
    assert_eq!(runtime.start_count(), 1);
    assert_eq!(runtime.publish_count(), 0);
}

#[tokio::test]
async fn write_workflow_policy_drift_invalidates_the_approved_plan() {
    let fixture = seed_write_execution("write-policy-drift").await;
    let runtime = FakeWriteRuntime::new([]);
    let mut settings = fixture
        .test
        .db
        .task_board_orchestrator_settings()
        .await
        .expect("load settings");
    settings.policy_version = "policy-v2".into();
    fixture
        .test
        .db
        .replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("replace settings");

    tick(&fixture, &runtime).await;

    let execution = load_execution(&fixture).await;
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(
        execution.blocked_reason.as_deref(),
        Some("plan_approval_invalidated")
    );
    assert_eq!(
        execution.artifacts.approval_invalidations,
        vec![
            TaskBoardPlanApprovalInvalidation::ConfigurationRevisionChanged,
            TaskBoardPlanApprovalInvalidation::PolicyVersionChanged,
        ]
    );
    assert_eq!(runtime.start_count(), 0);
}

#[tokio::test]
async fn legacy_write_execution_without_task_identity_fails_closed() {
    let fixture = seed_write_execution_with_task("write-missing-task", None).await;
    let runtime = FakeWriteRuntime::new([]);

    tick(&fixture, &runtime).await;

    let execution = load_execution(&fixture).await;
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(
        execution.blocked_reason.as_deref(),
        Some("write_task_id_missing")
    );
    assert_eq!(runtime.start_count(), 0);
}

async fn seed_write_execution(label: &str) -> Fixture {
    seed_write_execution_with_task(label, Some(format!("work-coordinator-{label}"))).await
}

async fn seed_write_execution_with_task(label: &str, task_id: Option<String>) -> Fixture {
    let test = TestDatabase::open().await;
    let item_id = format!("coordinator-{label}");
    let execution_id = format!("execution-{label}");
    let mut settings = crate::task_board::TaskBoardOrchestratorSettings::default();
    settings.policy_version = "policy-v1".into();
    test.db
        .replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("seed settings");
    let mutation = test
        .db
        .create_task_board_item(write_item(label, &item_id, &execution_id))
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
    );
    let execution = write_execution(
        &item_id,
        &execution_id,
        snapshot,
        resolved_reviewers,
        task_id,
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

fn write_item(label: &str, item_id: &str, execution_id: &str) -> crate::task_board::TaskBoardItem {
    let mut item = crate::task_board::TaskBoardItem::new(
        item_id.to_string(),
        format!("Write workflow {label}"),
        "Implement and validate the approved change".into(),
        NOW.into(),
    );
    item.agent_mode = AgentMode::Headless;
    item.workflow_kind = TaskBoardWorkflowKind::DefaultTask;
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
) -> TaskBoardWorkflowSnapshot {
    TaskBoardWorkflowSnapshot {
        workflow_kind: TaskBoardWorkflowKind::DefaultTask,
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
            workflow_kind: TaskBoardWorkflowKind::DefaultTask,
            phase: Some(TaskBoardExecutionPhase::Implementation),
            execution_state: TaskBoardExecutionState::Pending,
            pull_request: None,
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

async fn drive_to_terminal(fixture: &Fixture, runtime: &FakeWriteRuntime) {
    for _ in 0..32 {
        tick(fixture, runtime).await;
        if fixture
            .test
            .db
            .task_board_item(&fixture.item_id)
            .await
            .expect("load item")
            .status
            == TaskBoardStatus::Done
        {
            return;
        }
    }
    panic!("write workflow did not reach terminal projection");
}

async fn tick(fixture: &Fixture, runtime: &FakeWriteRuntime) {
    tick_at(fixture, runtime, NOW).await;
}

async fn tick_at(fixture: &Fixture, runtime: &FakeWriteRuntime, now: &str) {
    let report =
        reconcile_task_board_read_only_workflows_with_runtime(&fixture.test.db, runtime, now, 8)
            .await
            .expect("reconcile write workflow");
    if !report.failures.is_empty() {
        let execution = load_execution(fixture).await;
        panic!(
            "{:?}; phase={:?}; state={:?}; cycle={}",
            report.failures,
            execution.transition.phase,
            execution.transition.execution_state,
            execution.artifacts.current_revision_cycle
        );
    }
}

async fn load_execution(fixture: &Fixture) -> TaskBoardWorkflowExecutionRecord {
    fixture
        .test
        .db
        .task_board_workflow_execution(&fixture.execution_id)
        .await
        .expect("load execution")
        .expect("execution exists")
}
