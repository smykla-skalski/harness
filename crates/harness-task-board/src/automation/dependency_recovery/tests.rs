use super::*;
use crate::github::{PullRequestAction, PullRequestActionKind, PullRequestIdentity};
use crate::{
    TaskBoardEvaluationResult, TaskBoardExecutionOwnership, TaskBoardLifecycleOutcome,
    TaskBoardPhaseVerdict, TaskBoardResolvedReviewer, TaskBoardReviewResult,
    TaskBoardReviewerOutcome, TaskBoardWorkflowExecutionArtifacts, TaskBoardWorkflowKind,
    TaskBoardWorkflowSnapshot, TaskBoardWorkflowTransitionState,
};

const HEAD: &str = "0123456789abcdef0123456789abcdef01234567";

#[test]
fn agent_publish_and_terminal_attempts_have_distinct_recovery_classes() {
    let mut execution = execution(TaskBoardExecutionPhase::Implementation);
    execution
        .attempts
        .push(attempt("implementation:1", TaskBoardAttemptState::Running));
    assert_eq!(
        classify_task_board_dependency_workflow_recovery(&execution)
            .expect("classify")
            .class,
        TaskBoardDependencyRecoveryClass::Resumable
    );

    execution.transition.phase = Some(TaskBoardExecutionPhase::Publish);
    execution.attempts = vec![attempt("publish", TaskBoardAttemptState::Running)];
    let publish =
        classify_task_board_dependency_workflow_recovery(&execution).expect("publish recovery");
    assert_eq!(publish.class, TaskBoardDependencyRecoveryClass::Uncertain);
    assert_eq!(publish.step, TaskBoardDependencyRecoveryStep::GitHubAction);

    execution.attempts[0].state = TaskBoardAttemptState::Completed;
    execution.attempts[0].artifact = Some(TaskBoardAttemptResultArtifact::Lifecycle(
        TaskBoardLifecycleOutcome {
            mutated: true,
            terminal: false,
            provider_revision: None,
            external_url: None,
        },
    ));
    let completed =
        classify_task_board_dependency_workflow_recovery(&execution).expect("completed recovery");
    assert_eq!(completed.class, TaskBoardDependencyRecoveryClass::Completed);
    assert_eq!(completed.step, TaskBoardDependencyRecoveryStep::Advance);
}

#[test]
fn retry_wait_and_transient_failure_resume_the_same_agent_step() {
    let mut execution = execution(TaskBoardExecutionPhase::Evaluate);
    execution
        .attempts
        .push(attempt("evaluate:1", TaskBoardAttemptState::RetryWait));

    let recovery =
        classify_task_board_dependency_workflow_recovery(&execution).expect("classify wait");

    assert_eq!(recovery.class, TaskBoardDependencyRecoveryClass::Resumable);
    assert_eq!(recovery.step, TaskBoardDependencyRecoveryStep::AgentRun);
    assert_eq!(recovery.exact_head_revision.as_deref(), Some(HEAD));

    execution.attempts[0].state = TaskBoardAttemptState::Failed;
    execution.attempts[0].failure_class = Some(TaskBoardFailureClass::Transient);
    let transient =
        classify_task_board_dependency_workflow_recovery(&execution).expect("transient failure");
    assert_eq!(transient.class, TaskBoardDependencyRecoveryClass::Resumable);
    assert_eq!(transient.step, TaskBoardDependencyRecoveryStep::AgentRun);
}

#[test]
fn check_recovery_reuses_one_exact_head_and_one_terminal_result() {
    let wait = check_wait();
    let resumable =
        classify_task_board_dependency_check_recovery(&wait, None).expect("resumable wait");
    assert_eq!(resumable.class, TaskBoardDependencyRecoveryClass::Resumable);
    assert_eq!(resumable.exact_head_revision.as_deref(), Some(HEAD));

    let result = TaskBoardDependencyCheckResumeRecord {
        resume_id: wait.resume_id.clone(),
        route_id: wait.route_id.clone(),
        identity: wait.identity.clone(),
        exact_head_revision: HEAD.into(),
        status: super::super::TaskBoardDependencyCheckResumeStatus::TimedOut,
    };
    let completed = classify_task_board_dependency_check_recovery(&wait, Some(&result))
        .expect("completed wait");
    assert_eq!(completed.class, TaskBoardDependencyRecoveryClass::Completed);

    let mut stale = result;
    stale.exact_head_revision = "123456789abcdef0123456789abcdef012345678".into();
    assert!(
        classify_task_board_dependency_check_recovery(&wait, Some(&stale))
            .expect_err("stale result")
            .to_string()
            .contains("exact-head wait")
    );
}

#[test]
fn uncertain_github_actions_reconcile_before_any_retry() {
    let mut action = action(ActionState::Uncertain);
    let uncertain = classify_task_board_dependency_action_recovery(&action);
    assert_eq!(uncertain.class, TaskBoardDependencyRecoveryClass::Uncertain);
    assert!(uncertain.detail.contains("before retrying"));

    action.state = ActionState::Succeeded;
    assert_eq!(
        classify_task_board_dependency_action_recovery(&action).class,
        TaskBoardDependencyRecoveryClass::Completed
    );
    action.state = ActionState::Failed(PullRequestActionFailureClass::Transient);
    assert_eq!(
        classify_task_board_dependency_action_recovery(&action).class,
        TaskBoardDependencyRecoveryClass::Resumable
    );
    action.state = ActionState::Failed(PullRequestActionFailureClass::Permanent);
    assert_eq!(
        classify_task_board_dependency_action_recovery(&action).class,
        TaskBoardDependencyRecoveryClass::Failed
    );
}

#[test]
fn multiple_active_attempts_are_rejected_before_recovery() {
    let mut execution = execution(TaskBoardExecutionPhase::Implementation);
    execution.attempts = vec![
        attempt("implementation:1", TaskBoardAttemptState::Starting),
        attempt("implementation:1", TaskBoardAttemptState::Running),
    ];

    assert!(
        classify_task_board_dependency_workflow_recovery(&execution)
            .expect_err("ambiguous active attempts")
            .to_string()
            .contains("multiple active attempts")
    );
}

#[test]
fn active_attempt_must_belong_to_the_current_step() {
    let mut execution = execution(TaskBoardExecutionPhase::Implementation);
    execution.attempts.push(attempt(
        "review:reviewer-amber",
        TaskBoardAttemptState::Running,
    ));

    assert!(
        classify_task_board_dependency_workflow_recovery(&execution)
            .expect_err("stale active attempt")
            .to_string()
            .contains("does not match its current step")
    );
}

#[test]
fn review_attempt_requires_a_non_empty_profile_id() {
    let mut execution = execution(TaskBoardExecutionPhase::Review);
    execution
        .attempts
        .push(attempt("review:", TaskBoardAttemptState::Running));

    assert!(
        classify_task_board_dependency_workflow_recovery(&execution)
            .expect_err("empty reviewer profile")
            .to_string()
            .contains("does not match its current step")
    );
}

#[test]
fn completed_current_attempt_requires_a_result_artifact() {
    let mut execution = execution(TaskBoardExecutionPhase::Review);
    execution.attempts.push(attempt(
        "review:reviewer-amber",
        TaskBoardAttemptState::Completed,
    ));

    assert!(
        classify_task_board_dependency_workflow_recovery(&execution)
            .expect_err("missing completed result")
            .to_string()
            .contains("has no result artifact")
    );
}

#[test]
fn completed_review_from_an_old_head_does_not_advance_the_current_step() {
    let mut execution = execution(TaskBoardExecutionPhase::Review);
    let mut stale = attempt("review:reviewer-amber", TaskBoardAttemptState::Completed);
    stale.artifact = Some(TaskBoardAttemptResultArtifact::Review(
        TaskBoardReviewerOutcome {
            profile_id: "reviewer-amber".into(),
            result: TaskBoardReviewResult {
                verdict: TaskBoardPhaseVerdict::Pass,
                head_revision: "123456789abcdef0123456789abcdef012345678".into(),
                summary: "approved an older head".into(),
                findings: Vec::new(),
                structured_findings: Vec::new(),
            },
        },
    ));
    execution.attempts.push(stale);

    let recovery = classify_task_board_dependency_workflow_recovery(&execution)
        .expect("classify stale review");

    assert_eq!(recovery.class, TaskBoardDependencyRecoveryClass::Resumable);
    assert_eq!(recovery.step, TaskBoardDependencyRecoveryStep::AgentRun);
    assert_eq!(recovery.action_key, None);
}

#[test]
fn completed_write_evaluation_without_provenance_does_not_advance() {
    let mut execution = execution(TaskBoardExecutionPhase::Evaluate);
    let mut incomplete = attempt("evaluate:1", TaskBoardAttemptState::Completed);
    incomplete.artifact = Some(TaskBoardAttemptResultArtifact::Evaluation(
        TaskBoardEvaluationResult {
            verdict: TaskBoardPhaseVerdict::Pass,
            summary: "missing write provenance".into(),
            evidence: Vec::new(),
            head_revision: None,
            revision_cycle: None,
        },
    ));
    execution.attempts.push(incomplete);

    let recovery =
        classify_task_board_dependency_workflow_recovery(&execution).expect("classify evaluation");

    assert_eq!(recovery.class, TaskBoardDependencyRecoveryClass::Resumable);
    assert_eq!(recovery.step, TaskBoardDependencyRecoveryStep::AgentRun);
    assert_eq!(recovery.action_key, None);
}

fn check_wait() -> TaskBoardDependencyCheckWait {
    TaskBoardDependencyCheckWait {
        resume_id: "route-1:checks".into(),
        route_id: "route-1".into(),
        identity: PullRequestIdentity::from_slug("acme/widgets", 17),
        exact_head_revision: HEAD.into(),
        required_checks: vec!["build".into()],
    }
}

fn action(state: ActionState) -> RecordedAction {
    RecordedAction {
        action: PullRequestAction {
            id: "route-1:dependency-merge:head".into(),
            kind: PullRequestActionKind::Merge,
            identity: PullRequestIdentity::from_slug("acme/widgets", 17),
            head_revision: HEAD.into(),
        },
        state,
        detail: None,
    }
}

fn attempt(action_key: &str, state: TaskBoardAttemptState) -> TaskBoardExecutionAttemptRecord {
    TaskBoardExecutionAttemptRecord {
        execution_id: "execution-1".into(),
        action_key: action_key.into(),
        attempt: 1,
        idempotency_key: format!("execution-1:{action_key}:1"),
        state,
        failure_class: None,
        available_at: None,
        error: None,
        artifact: None,
        started_at: "2026-07-30T00:00:00Z".into(),
        updated_at: "2026-07-30T00:00:00Z".into(),
        completed_at: None,
    }
}

fn execution(phase: TaskBoardExecutionPhase) -> TaskBoardWorkflowExecutionRecord {
    let reviewers = TaskBoardResolvedReviewer {
        reviewer_count: 0,
        required_approvals: 0,
        max_revision_cycles: 3,
        profiles: Vec::new(),
    };
    TaskBoardWorkflowExecutionRecord {
        execution_id: "execution-1".into(),
        item_id: "item-1".into(),
        snapshot: TaskBoardWorkflowSnapshot {
            workflow_kind: TaskBoardWorkflowKind::PrFixReview,
            execution_repository: Some("acme/widgets".into()),
            item_revision: 1,
            configuration_revision: 1,
            policy_version: "policy-v1".into(),
            reviewer: reviewers.clone(),
            read_only_run_context: None,
            provider_revision: None,
        },
        resolved_reviewers: reviewers,
        transition: TaskBoardWorkflowTransitionState {
            workflow_kind: TaskBoardWorkflowKind::PrFixReview,
            phase: Some(phase),
            execution_state: TaskBoardExecutionState::Running,
            pull_request: None,
            exact_head_revision: Some(HEAD.into()),
        },
        artifacts: TaskBoardWorkflowExecutionArtifacts {
            current_revision_cycle: 1,
            ..TaskBoardWorkflowExecutionArtifacts::default()
        },
        ownership: TaskBoardExecutionOwnership::default(),
        available_at: None,
        blocked_reason: None,
        created_at: "2026-07-30T00:00:00Z".into(),
        updated_at: "2026-07-30T00:00:00Z".into(),
        completed_at: None,
        attempts: Vec::new(),
    }
}
