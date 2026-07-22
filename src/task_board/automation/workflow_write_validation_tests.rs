use std::collections::BTreeMap;

use super::workflow_execution_write_validation::{
    validate_write_attempt_artifact, validate_write_frozen_contract,
};
use super::*;
use crate::task_board::{
    AgentMode, TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION, TaskBoardReadOnlyRunContext,
};

const NOW: &str = "2026-07-18T10:00:00Z";

#[test]
fn implementation_phase_requires_revision_bound_plan_approval() {
    let mut record = write_execution();
    record.artifacts.plan_approval = None;

    let error = validate_task_board_workflow_execution(&record).expect_err("approval required");

    assert_eq!(
        error,
        TaskBoardWorkflowExecutionValidationError::InvalidField {
            field: "artifacts.plan_approval",
            detail: "write phase has no revision-bound approval".into(),
        }
    );
}

#[test]
fn implementation_result_binds_action_cycle_and_head_transition() {
    let mut record = write_execution();
    record.attempts.push(implementation_attempt(1));
    validate_task_board_workflow_execution(&record).expect("valid implementation evidence");

    let mut wrong_action = record.clone();
    wrong_action.attempts[0].action_key = "implementation:2".into();
    assert_invalid_field(
        &wrong_action,
        "attempt.artifact.implementation",
        "wrong action must fail",
    );

    let mut unchanged_head = record;
    let Some(TaskBoardAttemptResultArtifact::Implementation(result)) =
        unchanged_head.attempts[0].artifact.as_mut()
    else {
        panic!("implementation artifact")
    };
    result.head_revision.clone_from(&result.base_head_revision);
    assert_invalid_field(
        &unchanged_head,
        "attempt.artifact.implementation",
        "unchanged head must fail",
    );
}

#[test]
fn later_implementation_cycle_is_chained_to_the_preceding_review_head() {
    let mut record = write_execution();
    record.artifacts.current_revision_cycle = 2;
    record.artifacts.review_cycles.push(TaskBoardReviewCycle {
        revision_cycle: 1,
        head_revision: "head-cycle-1".into(),
        outcomes: Vec::new(),
        decision: None,
    });
    let mut attempt = implementation_attempt(2);
    let Some(TaskBoardAttemptResultArtifact::Implementation(result)) = attempt.artifact.as_mut()
    else {
        panic!("implementation artifact")
    };
    result.base_head_revision = "head-cycle-1".into();
    result.head_revision = "head-cycle-2".into();
    record.attempts.push(attempt);
    validate_task_board_workflow_execution(&record).expect("chained cycle");

    let Some(TaskBoardAttemptResultArtifact::Implementation(result)) =
        record.attempts[0].artifact.as_mut()
    else {
        panic!("implementation artifact")
    };
    result.base_head_revision = "head-forged".into();
    assert_invalid_field(
        &record,
        "attempt.artifact.implementation",
        "forged base must fail",
    );
}

#[test]
fn pr_fix_cycle_one_implementation_binds_the_frozen_pull_request_head() {
    let mut record = write_execution();
    record.snapshot.workflow_kind = TaskBoardWorkflowKind::PrFix;
    record.transition.workflow_kind = TaskBoardWorkflowKind::PrFix;
    record.transition.pull_request = Some(TaskBoardPullRequestIdentity {
        repository: "example/compass".into(),
        number: 42,
        head: Some(TaskBoardPullRequestHeadIdentity {
            repository: "contributor/compass".into(),
            branch: "feature/fix".into(),
            revision: "head-base".into(),
        }),
    });
    let valid = implementation_attempt(1);
    assert!(validate_write_attempt_artifact(&record, &valid).expect("frozen cycle-one base"));

    let mut missing_head = record.clone();
    missing_head
        .transition
        .pull_request
        .as_mut()
        .expect("pull request")
        .head = None;
    let error = validate_write_attempt_artifact(&missing_head, &valid)
        .expect_err("missing frozen cycle-one base must fail");
    assert_eq!(
        error,
        TaskBoardWorkflowExecutionValidationError::InvalidField {
            field: "attempt.artifact.implementation",
            detail: "frozen pull request head is missing".into(),
        }
    );

    let mut forged = valid;
    let Some(TaskBoardAttemptResultArtifact::Implementation(result)) = forged.artifact.as_mut()
    else {
        panic!("implementation artifact")
    };
    result.base_head_revision = "head-forged".into();
    let error = validate_write_attempt_artifact(&record, &forged)
        .expect_err("forged cycle-one base must fail");
    assert_eq!(
        error,
        TaskBoardWorkflowExecutionValidationError::InvalidField {
            field: "attempt.artifact.implementation",
            detail: "base head does not match the frozen pull request head".into(),
        }
    );
}

#[test]
fn write_evaluation_requires_exact_head_and_revision_cycle() {
    let mut record = write_execution();
    record.transition.phase = Some(TaskBoardExecutionPhase::Evaluate);
    record.transition.exact_head_revision = Some("head-result".into());
    record
        .attempts
        .push(evaluation_attempt(Some("head-result"), Some(1)));
    validate_task_board_workflow_execution(&record).expect("bound evaluation");

    let mut missing = record.clone();
    let Some(TaskBoardAttemptResultArtifact::Evaluation(result)) =
        missing.attempts[0].artifact.as_mut()
    else {
        panic!("evaluation artifact")
    };
    result.head_revision = None;
    assert_invalid_field(
        &missing,
        "attempt.artifact.evaluation",
        "missing head must fail",
    );

    let mut replayed = record;
    let Some(TaskBoardAttemptResultArtifact::Evaluation(result)) =
        replayed.attempts[0].artifact.as_mut()
    else {
        panic!("evaluation artifact")
    };
    result.head_revision = Some("head-other".into());
    assert_invalid_field(
        &replayed,
        "attempt.artifact.evaluation",
        "other head must fail",
    );
}

#[test]
fn provisional_publication_is_write_only_non_authoritative_and_revision_bound() {
    let mut record = write_execution();
    record.transition.phase = Some(TaskBoardExecutionPhase::Publish);
    record.artifacts.provisional_publication = Some(TaskBoardLifecycleOutcome {
        mutated: true,
        terminal: false,
        provider_revision: Some("provider-v3".into()),
        external_url: Some("https://github.com/example/compass/pull/42".into()),
    });
    validate_write_frozen_contract(&record).expect("valid provisional evidence");

    let mut blank_url = record.clone();
    blank_url
        .artifacts
        .provisional_publication
        .as_mut()
        .expect("provisional evidence")
        .external_url = Some("  ".into());
    assert_invalid_write_contract(&blank_url, "artifacts.provisional_publication.external_url");

    let mut terminal = record.clone();
    terminal
        .artifacts
        .provisional_publication
        .as_mut()
        .expect("provisional evidence")
        .terminal = true;
    assert_invalid_write_contract(&terminal, "artifacts.provisional_publication");

    let mut provider_drift = record.clone();
    provider_drift
        .artifacts
        .provisional_publication
        .as_mut()
        .expect("provisional evidence")
        .provider_revision = Some("provider-v4".into());
    assert_invalid_write_contract(
        &provider_drift,
        "artifacts.provisional_publication.provider_revision",
    );

    let mut wrong_phase = record.clone();
    wrong_phase.transition.phase = Some(TaskBoardExecutionPhase::Evaluate);
    assert_invalid_write_contract(&wrong_phase, "artifacts.provisional_publication");

    let mut read_only = record;
    read_only.snapshot.workflow_kind = TaskBoardWorkflowKind::Review;
    read_only.artifacts.planning_result = None;
    read_only.artifacts.plan_approval = None;
    assert_invalid_write_contract(&read_only, "artifacts");
}

pub(super) fn write_execution() -> TaskBoardWorkflowExecutionRecord {
    let reviewer = reviewers();
    let snapshot = TaskBoardWorkflowSnapshot {
        workflow_kind: TaskBoardWorkflowKind::DefaultTask,
        execution_repository: Some("example/compass".into()),
        item_revision: 7,
        configuration_revision: 11,
        policy_version: "policy-v1".into(),
        reviewer: reviewer.clone(),
        read_only_run_context: Some(TaskBoardReadOnlyRunContext {
            schema_version: TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
            session_id: "session-write".into(),
            title: "Write workflow".into(),
            body: "Implement safely".into(),
            tags: Vec::new(),
            worktree: "/tmp/write-worktree".into(),
        }),
        provider_revision: Some("provider-v3".into()),
    };
    let planning_result = build_planning_result(
        "# Plan\n\nImplement safely.",
        ["Tests pass".into()],
        &snapshot,
        "execution-write",
    )
    .expect("build plan");
    let plan_approval =
        bind_plan_approval(&planning_result, &snapshot, "execution-write", "lead", NOW)
            .expect("bind approval");
    TaskBoardWorkflowExecutionRecord {
        execution_id: "execution-write".into(),
        item_id: "item-write".into(),
        snapshot,
        resolved_reviewers: reviewer,
        transition: TaskBoardWorkflowTransitionState {
            workflow_kind: TaskBoardWorkflowKind::DefaultTask,
            phase: Some(TaskBoardExecutionPhase::Implementation),
            execution_state: TaskBoardExecutionState::Running,
            pull_request: None,
            exact_head_revision: Some("head-base".into()),
        },
        artifacts: TaskBoardWorkflowExecutionArtifacts {
            planning_result: Some(planning_result),
            plan_approval: Some(plan_approval),
            ..TaskBoardWorkflowExecutionArtifacts::default()
        },
        ownership: TaskBoardExecutionOwnership {
            host_id: None,
            fencing_epoch: 0,
            resources: BTreeMap::new(),
        },
        available_at: None,
        blocked_reason: None,
        created_at: NOW.into(),
        updated_at: NOW.into(),
        completed_at: None,
        attempts: Vec::new(),
    }
}

fn reviewers() -> TaskBoardResolvedReviewer {
    TaskBoardResolvedReviewer {
        reviewer_count: 1,
        required_approvals: 1,
        max_revision_cycles: 3,
        profiles: vec![TaskBoardReviewerProfile {
            id: "reviewer-1".into(),
            runtime: "codex".into(),
            persona: "code-reviewer".into(),
            agent_mode: AgentMode::Evaluate,
            model: None,
            effort: None,
        }],
    }
}

pub(super) fn implementation_attempt(cycle: u32) -> TaskBoardExecutionAttemptRecord {
    completed_attempt(
        &format!("implementation:{cycle}"),
        TaskBoardAttemptResultArtifact::Implementation(TaskBoardImplementationResult {
            revision_cycle: cycle,
            base_head_revision: "head-base".into(),
            head_revision: "head-result".into(),
            summary: "Implemented approved plan".into(),
            evidence: vec!["focused tests passed".into()],
        }),
    )
}

fn evaluation_attempt(
    head_revision: Option<&str>,
    revision_cycle: Option<u32>,
) -> TaskBoardExecutionAttemptRecord {
    completed_attempt(
        "evaluate:1",
        TaskBoardAttemptResultArtifact::Evaluation(TaskBoardEvaluationResult {
            verdict: TaskBoardPhaseVerdict::Pass,
            summary: "Acceptance criteria satisfied".into(),
            evidence: vec!["tests green".into()],
            head_revision: head_revision.map(str::to_owned),
            revision_cycle,
        }),
    )
}

fn completed_attempt(
    action_key: &str,
    artifact: TaskBoardAttemptResultArtifact,
) -> TaskBoardExecutionAttemptRecord {
    TaskBoardExecutionAttemptRecord {
        execution_id: "execution-write".into(),
        action_key: action_key.into(),
        attempt: 1,
        idempotency_key: format!("run-{action_key}"),
        state: TaskBoardAttemptState::Completed,
        failure_class: None,
        available_at: None,
        error: None,
        artifact: Some(artifact),
        started_at: NOW.into(),
        updated_at: NOW.into(),
        completed_at: Some(NOW.into()),
    }
}

fn assert_invalid_field(
    record: &TaskBoardWorkflowExecutionRecord,
    expected: &'static str,
    message: &str,
) {
    let error = validate_task_board_workflow_execution(record).expect_err(message);
    assert!(matches!(
        error,
        TaskBoardWorkflowExecutionValidationError::InvalidField { field, .. }
            if field == expected
    ));
}

fn assert_invalid_write_contract(
    record: &TaskBoardWorkflowExecutionRecord,
    expected: &'static str,
) {
    let error = validate_write_frozen_contract(record).expect_err("invalid write contract");
    assert!(matches!(
        error,
        TaskBoardWorkflowExecutionValidationError::InvalidField { field, .. }
            if field == expected
    ));
}
