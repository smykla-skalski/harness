use crate::task_board::{
    TASK_BOARD_DEPENDENCY_TRIAGE_SCHEMA_VERSION, TaskBoardDependencyApprovalEvidence,
    TaskBoardDependencyCheck, TaskBoardDependencyCheckState, TaskBoardDependencyConflictEvidence,
    TaskBoardDependencyConflictState, TaskBoardDependencyIdentity, TaskBoardDependencyRouteStatus,
    TaskBoardDependencyTriageDisposition, TaskBoardDependencyTriageResult,
    TaskBoardDependencyTriageStep, TaskBoardDependencyUpdateClass, TaskBoardExecutionAttemptCas,
    TaskBoardWorkflowExecutionCas,
};

use super::*;

#[tokio::test]
async fn dependency_update_schedules_triage_before_workspace_write() {
    let fixture = Box::pin(write_fixture::seed_write_execution_kind(
        "dependency-triage-first",
        TaskBoardWorkflowKind::PrFixReview,
    ))
    .await;
    let runtime = FakeWriteRuntime::new([]);

    tick(&fixture, &runtime).await;

    let execution = load_execution(&fixture).await;
    assert_eq!(execution.attempts.len(), 1);
    assert_eq!(execution.attempts[0].action_key, "dependency_triage");
    assert_eq!(runtime.start_count(), 0);
}

#[tokio::test]
async fn starting_dependency_triage_resumes_after_restart() {
    let fixture = Box::pin(write_fixture::seed_write_execution_kind(
        "dependency-triage-start-recovery",
        TaskBoardWorkflowKind::PrFixReview,
    ))
    .await;
    let runtime = FakeWriteRuntime::new([]);
    runtime.plan_triage(safe_triage_result());
    tick(&fixture, &runtime).await;
    let prepared = load_execution(&fixture).await;
    let attempt = prepared.attempts.first().expect("prepared triage attempt");
    assert!(
        fixture
            .test
            .db
            .select_task_board_local_execution_target(
                &TaskBoardWorkflowExecutionCas::from(&prepared),
                &TaskBoardExecutionAttemptCas::from(attempt),
                NOW,
            )
            .await
            .expect("select local triage target"),
        "fixture must stop after target selection",
    );

    tick(&fixture, &runtime).await;

    let resumed = load_execution(&fixture).await;
    assert_eq!(runtime.triage_start_count(), 1);
    assert_ne!(resumed.attempts[0].state, TaskBoardAttemptState::Starting);
}

#[tokio::test]
async fn safe_dependency_triage_is_retained_and_skips_workspace_write() {
    let fixture = Box::pin(write_fixture::seed_write_execution_kind(
        "dependency-safe-triage",
        TaskBoardWorkflowKind::PrFixReview,
    ))
    .await;
    let runtime = FakeWriteRuntime::new([
        PlannedRun::review(1, BASE_HEAD, TaskBoardPhaseVerdict::Pass),
        PlannedRun::evaluation(1, BASE_HEAD),
    ]);
    runtime.plan_triage(safe_triage_result());

    drive_to_terminal(&fixture, &runtime).await;

    let execution = load_execution(&fixture).await;
    assert_eq!(runtime.triage_start_count(), 1);
    assert_eq!(runtime.start_count(), 2);
    assert_eq!(
        execution
            .artifacts
            .dependency_triage
            .as_ref()
            .map(|route| &route.status),
        Some(&TaskBoardDependencyRouteStatus::ReadyToContinue)
    );
    assert!(
        execution
            .attempts
            .iter()
            .all(|attempt| !attempt.action_key.starts_with("implementation:"))
    );
}

#[tokio::test]
async fn dependency_fixer_starts_only_after_explicit_triage_route() {
    let fixture = Box::pin(write_fixture::seed_write_execution_kind(
        "dependency-fix-triage",
        TaskBoardWorkflowKind::PrFixReview,
    ))
    .await;
    let runtime = FakeWriteRuntime::new([
        PlannedRun::implementation(1, 1, BASE_HEAD, FIRST_HEAD),
        PlannedRun::review(1, FIRST_HEAD, TaskBoardPhaseVerdict::Pass),
        PlannedRun::evaluation(1, FIRST_HEAD),
    ]);
    runtime.plan_triage(fix_required_triage_result());

    for _ in 0..8 {
        tick(&fixture, &runtime).await;
        if load_execution(&fixture)
            .await
            .artifacts
            .dependency_triage
            .is_some()
        {
            break;
        }
    }
    assert_eq!(
        runtime.start_count(),
        0,
        "workspace write started before triage was durably routed"
    );
    tick(&fixture, &runtime).await;
    let routed = load_execution(&fixture).await;
    let implementation = routed
        .attempts
        .iter()
        .find(|attempt| attempt.action_key == "implementation:1")
        .expect("routed implementation attempt");
    let request = crate::daemon::task_board_read_only_coordinator::requests::codex_attempt_request(
        &routed,
        implementation,
    )
    .expect("dependency fixer request");
    assert_eq!(request.model.as_deref(), Some("gpt-5.3-codex-spark"));
    assert_eq!(request.effort.as_deref(), Some("low"));
    assert!(request.prompt.contains("\"disposition\": \"fix_required\""));
    assert_eq!(runtime.start_count(), 0);
    drive_to_terminal(&fixture, &runtime).await;

    let execution = load_execution(&fixture).await;
    assert_eq!(runtime.triage_start_count(), 1);
    assert_eq!(runtime.start_count(), 3);
    assert!(
        execution
            .attempts
            .iter()
            .any(|attempt| attempt.action_key == "dependency_triage")
    );
    assert!(
        execution
            .attempts
            .iter()
            .any(|attempt| attempt.action_key == "implementation:1")
    );
    assert_eq!(
        execution
            .artifacts
            .dependency_triage
            .as_ref()
            .map(|route| &route.status),
        Some(&TaskBoardDependencyRouteStatus::FixRequested)
    );
}

#[tokio::test]
async fn invalid_dependency_triage_fails_closed_without_workspace_write() {
    let fixture = Box::pin(write_fixture::seed_write_execution_kind(
        "dependency-invalid-triage",
        TaskBoardWorkflowKind::PrFixReview,
    ))
    .await;
    let runtime = FakeWriteRuntime::new([]);
    let mut invalid = safe_triage_result();
    invalid.exact_head_revision = "abcdefabcdefabcdefabcdefabcdefabcdefabcd".into();
    runtime.plan_triage(invalid);

    for _ in 0..8 {
        tick(&fixture, &runtime).await;
        if load_execution(&fixture).await.transition.execution_state
            == TaskBoardExecutionState::HumanRequired
        {
            break;
        }
    }

    let execution = load_execution(&fixture).await;
    let attempt = execution
        .attempts
        .iter()
        .find(|attempt| attempt.action_key == "dependency_triage")
        .expect("dependency triage attempt");
    assert_eq!(attempt.state, TaskBoardAttemptState::Unknown);
    assert_eq!(
        execution.transition.execution_state,
        TaskBoardExecutionState::HumanRequired
    );
    assert_eq!(
        execution.blocked_reason.as_deref(),
        Some("attempt_outcome_unknown")
    );
    assert_eq!(runtime.start_count(), 0);
}

pub(super) fn safe_triage_result() -> TaskBoardDependencyTriageResult {
    TaskBoardDependencyTriageResult {
        schema_version: TASK_BOARD_DEPENDENCY_TRIAGE_SCHEMA_VERSION,
        repository: "example/compass".into(),
        pull_request_number: 17,
        exact_head_revision: BASE_HEAD.into(),
        dependency: TaskBoardDependencyIdentity {
            name: "serde".into(),
            ecosystem: "cargo".into(),
            current_version: "1.0.200".into(),
            target_version: "1.0.201".into(),
            update_class: TaskBoardDependencyUpdateClass::Patch,
        },
        checks: vec![TaskBoardDependencyCheck {
            name: "test".into(),
            state: TaskBoardDependencyCheckState::Passed,
            details_url: None,
        }],
        conflicts: TaskBoardDependencyConflictEvidence {
            state: TaskBoardDependencyConflictState::Clean,
            summary: "clean".into(),
        },
        approvals: TaskBoardDependencyApprovalEvidence {
            current: 1,
            required: 1,
        },
        safety_assumption: "green patch update".into(),
        disposition: TaskBoardDependencyTriageDisposition::ContinueSafe,
        required_tools: vec!["task_board.audit".into(), "task_board.advance".into()],
        next_steps: vec![
            TaskBoardDependencyTriageStep {
                order: 1,
                action: "record_result".into(),
                reason: "retain decision".into(),
            },
            TaskBoardDependencyTriageStep {
                order: 2,
                action: "continue_workflow".into(),
                reason: "advance safe update".into(),
            },
        ],
    }
}

pub(super) fn fix_required_triage_result() -> TaskBoardDependencyTriageResult {
    let mut result = safe_triage_result();
    result.disposition = TaskBoardDependencyTriageDisposition::FixRequired;
    result.required_tools = vec!["task_board.audit".into(), "codex.dispatch".into()];
    result.next_steps[1].action = "dispatch_fixer".into();
    result.next_steps[1].reason = "repair the dependency update".into();
    result
}
