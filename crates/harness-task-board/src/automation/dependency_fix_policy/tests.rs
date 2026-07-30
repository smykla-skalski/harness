use super::*;
use crate::github::PullRequestIdentity;
use crate::{
    TASK_BOARD_DEPENDENCY_FIX_RESULT_SCHEMA_VERSION, TASK_BOARD_DEPENDENCY_TRIAGE_SCHEMA_VERSION,
    TaskBoardDependencyApprovalEvidence, TaskBoardDependencyCheck,
    TaskBoardDependencyCheckResumeStatus, TaskBoardDependencyCheckState,
    TaskBoardDependencyConflictEvidence, TaskBoardDependencyConflictState,
    TaskBoardDependencyIdentity, TaskBoardDependencySettledCheck,
    TaskBoardDependencyTriageDisposition, TaskBoardDependencyTriageResult,
    TaskBoardDependencyTriageStep, TaskBoardDependencyUpdateClass,
    render_task_board_dependency_fix_prompt,
};

const HEAD_1: &str = "0123456789abcdef0123456789abcdef01234567";
const HEAD_2: &str = "123456789abcdef0123456789abcdef012345678";
const HEAD_3: &str = "23456789abcdef0123456789abcdef0123456789";

#[test]
fn automated_retry_records_visible_attempt_status_and_failure() {
    let request = request();
    let decision = task_board_dependency_fix_retry_decision(
        &TaskBoardDependencyFixAttemptPolicy::default(),
        &request,
        &run(&request, "2026-07-30T10:00:00Z"),
        &result(&request, HEAD_2),
        &failed_checks(HEAD_2, "test", "https://ci.example.test/1"),
        "2026-07-30T10:05:00Z",
    )
    .expect("retry decision");
    let TaskBoardDependencyFixRetryDecision::Retry(next) = decision else {
        panic!("first failure should retry");
    };
    let audit = next.audit.as_ref().expect("audit");

    assert_retry_summary(&next, audit);
    assert_failure_evidence(&request, audit);
}

fn assert_retry_summary(
    next: &TaskBoardDependencyFixRequest,
    audit: &TaskBoardDependencyFixAuditTrail,
) {
    assert_eq!(next.attempt, 2);
    assert_eq!(audit.attempt_count, 1);
    assert_eq!(audit.current_attempt, 2);
    assert_eq!(
        audit.status,
        TaskBoardDependencyFixAutomationStatus::RetryScheduled
    );
}

fn assert_failure_evidence(
    request: &TaskBoardDependencyFixRequest,
    audit: &TaskBoardDependencyFixAuditTrail,
) {
    assert_eq!(audit.failure_reason, "failed checks: test");
    assert_eq!(audit.attempts[0].run_id, request.dispatch_id);
    assert_eq!(audit.attempts[0].failure_fingerprint.len(), 64);
    assert_eq!(audit.stop_reason, None);
}

#[test]
fn repeated_equivalent_failure_stops_before_attempt_limit() {
    let policy = TaskBoardDependencyFixAttemptPolicy::default();
    let first = request();
    let retry = expect_retry(
        task_board_dependency_fix_retry_decision(
            &policy,
            &first,
            &run(&first, "2026-07-30T10:00:00Z"),
            &result(&first, HEAD_2),
            &failed_checks(HEAD_2, "test", "https://ci.example.test/1"),
            "2026-07-30T10:05:00Z",
        )
        .expect("first retry"),
    );
    let decision = task_board_dependency_fix_retry_decision(
        &policy,
        &retry,
        &run(&retry, "2026-07-30T10:06:00Z"),
        &result(&retry, HEAD_3),
        &failed_checks(HEAD_3, "test", "https://ci.example.test/2"),
        "2026-07-30T10:10:00Z",
    )
    .expect("second decision");
    let TaskBoardDependencyFixRetryDecision::HumanRequired(audit) = decision else {
        panic!("equivalent failure should stop");
    };

    assert_eq!(audit.attempt_count, 2);
    assert_eq!(audit.current_attempt, 2);
    assert_eq!(
        audit.status,
        TaskBoardDependencyFixAutomationStatus::HumanRequired
    );
    assert_eq!(
        audit.stop_reason,
        Some(TaskBoardDependencyFixStopReason::RepeatedEquivalentFailure)
    );
    assert_eq!(
        audit.attempts[0].failure_fingerprint,
        audit.attempts[1].failure_fingerprint
    );
}

#[test]
fn attempt_and_elapsed_bounds_require_a_person_with_evidence() {
    let request = request();
    for (policy, completed_at, expected) in [
        (
            TaskBoardDependencyFixAttemptPolicy {
                max_attempts: 1,
                max_elapsed_seconds: 3_600,
                max_equivalent_failures: 3,
            },
            "2026-07-30T10:05:00Z",
            TaskBoardDependencyFixStopReason::AttemptLimitReached,
        ),
        (
            TaskBoardDependencyFixAttemptPolicy {
                max_attempts: 3,
                max_elapsed_seconds: 300,
                max_equivalent_failures: 3,
            },
            "2026-07-30T10:05:00Z",
            TaskBoardDependencyFixStopReason::TimeBudgetExhausted,
        ),
    ] {
        let decision = task_board_dependency_fix_retry_decision(
            &policy,
            &request,
            &run(&request, "2026-07-30T10:00:00Z"),
            &result(&request, HEAD_2),
            &failed_checks(HEAD_2, "test", "https://ci.example.test/1"),
            completed_at,
        )
        .expect("bounded decision");
        let TaskBoardDependencyFixRetryDecision::HumanRequired(audit) = decision else {
            panic!("bound should stop");
        };
        assert_eq!(audit.stop_reason, Some(expected));
        assert_eq!(audit.attempt_count, 1);
        assert_eq!(audit.failure_reason, "failed checks: test");
    }
}

#[test]
fn explicit_retry_continues_stopped_audit_without_resetting_attempts() {
    let policy = TaskBoardDependencyFixAttemptPolicy::default();
    let first = request();
    let second = expect_retry(
        task_board_dependency_fix_retry_decision(
            &policy,
            &first,
            &run(&first, "2026-07-30T10:00:00Z"),
            &result(&first, HEAD_2),
            &failed_checks(HEAD_2, "test", "https://ci.example.test/1"),
            "2026-07-30T10:05:00Z",
        )
        .expect("first retry"),
    );
    let second_run = run(&second, "2026-07-30T10:06:00Z");
    let second_result = result(&second, HEAD_3);
    let second_checks = failed_checks(HEAD_3, "test", "https://ci.example.test/2");
    let stopped = match task_board_dependency_fix_retry_decision(
        &policy,
        &second,
        &second_run,
        &second_result,
        &second_checks,
        "2026-07-30T10:10:00Z",
    )
    .expect("stopped decision")
    {
        TaskBoardDependencyFixRetryDecision::HumanRequired(audit) => audit,
        TaskBoardDependencyFixRetryDecision::Retry(_) => panic!("second equivalent failure stops"),
    };

    let explicit = task_board_dependency_fix_explicit_retry_request(
        &second,
        &second_run,
        Some(&second_result),
        Some(&second_checks),
        &stopped,
        "2026-07-30T10:11:00Z",
    )
    .expect("explicit retry");
    let audit = explicit.audit.as_ref().expect("retained audit");

    assert_explicit_retry_summary(&explicit, audit);
    assert_explicit_retry_prompt(&explicit);
}

fn assert_explicit_retry_summary(
    explicit: &TaskBoardDependencyFixRequest,
    audit: &TaskBoardDependencyFixAuditTrail,
) {
    assert_eq!(explicit.attempt, 3);
    assert_eq!(audit.attempt_count, 2);
    assert_eq!(audit.current_attempt, 3);
    assert_eq!(audit.deadline_at, "2026-07-30T11:11:00Z");
    assert_eq!(
        audit.status,
        TaskBoardDependencyFixAutomationStatus::RetryScheduled
    );
    assert_eq!(audit.stop_reason, None);
}

fn assert_explicit_retry_prompt(explicit: &TaskBoardDependencyFixRequest) {
    let prompt = render_task_board_dependency_fix_prompt(explicit).expect("prompt");
    assert!(prompt.contains("Dependency fix audit trail"));
    assert!(prompt.contains("\"attempt_count\": 2"));
    assert!(prompt.contains("2026-07-30T10:10:00Z"));
}

#[test]
fn malformed_policy_time_and_stopped_audit_fail_closed() {
    let request = request();
    let run = run(&request, "2026-07-30T10:00:00Z");
    let result = result(&request, HEAD_2);
    let checks = failed_checks(HEAD_2, "test", "https://ci.example.test/1");
    let invalid = TaskBoardDependencyFixAttemptPolicy {
        max_attempts: 0,
        ..TaskBoardDependencyFixAttemptPolicy::default()
    };
    assert!(
        task_board_dependency_fix_retry_decision(
            &invalid,
            &request,
            &run,
            &result,
            &checks,
            "2026-07-30T10:05:00Z",
        )
        .is_err()
    );
    assert!(
        task_board_dependency_fix_retry_decision(
            &TaskBoardDependencyFixAttemptPolicy::default(),
            &request,
            &run,
            &result,
            &checks,
            "not-a-time",
        )
        .is_err()
    );

    let mut stopped = stopped_audit(&request, &run, &result, &checks);
    stopped.attempts[0].run_id = "different-run".into();
    assert!(
        task_board_dependency_fix_explicit_retry_request(
            &request,
            &run,
            Some(&result),
            Some(&checks),
            &stopped,
            "2026-07-30T10:06:00Z",
        )
        .is_err()
    );

    let mut stopped = stopped_audit(&request, &run, &result, &checks);
    stopped.attempts[0].failure_fingerprint = "0".repeat(64);
    assert!(
        task_board_dependency_fix_explicit_retry_request(
            &request,
            &run,
            Some(&result),
            Some(&checks),
            &stopped,
            "2026-07-30T10:06:00Z",
        )
        .is_err()
    );
}

#[test]
fn deadline_cancellation_records_human_required_timeout_evidence() {
    let mut request = request();
    request.attempt_policy.max_elapsed_seconds = 300;
    let audit = task_board_dependency_fix_timeout_audit(
        &request,
        &run(&request, "2026-07-30T10:00:00Z"),
        "2026-07-30T10:05:00Z",
    )
    .expect("timeout audit");

    assert_eq!(
        audit.status,
        TaskBoardDependencyFixAutomationStatus::HumanRequired
    );
    assert_eq!(
        audit.stop_reason,
        Some(TaskBoardDependencyFixStopReason::TimeBudgetExhausted)
    );
    assert_eq!(audit.deadline_at, "2026-07-30T10:05:00Z");
    assert_eq!(
        audit.failure_reason,
        "automated repair time budget exhausted"
    );
    assert_eq!(audit.attempts.len(), 1);
}

#[test]
fn explicit_retry_after_deadline_cancellation_needs_no_completion_evidence() {
    let mut request = request();
    request.attempt_policy.max_elapsed_seconds = 300;
    let run = run(&request, "2026-07-30T10:00:00Z");
    let stopped = task_board_dependency_fix_timeout_audit(&request, &run, "2026-07-30T10:05:00Z")
        .expect("timeout audit");

    let retry = task_board_dependency_fix_explicit_retry_request(
        &request,
        &run,
        None,
        None,
        &stopped,
        "2026-07-30T10:06:00Z",
    )
    .expect("explicit timeout retry");
    let audit = retry.audit.as_ref().expect("retained timeout audit");

    assert_timeout_retry_request(&retry);
    assert_timeout_retry_audit(audit);
}

fn assert_timeout_retry_request(retry: &TaskBoardDependencyFixRequest) {
    assert_eq!(retry.attempt, 2);
    assert_eq!(retry.exact_head_revision, HEAD_1);
    assert_eq!(retry.retry_evidence, None);
}

fn assert_timeout_retry_audit(audit: &TaskBoardDependencyFixAuditTrail) {
    assert_eq!(audit.attempt_count, 1);
    assert_eq!(audit.current_attempt, 2);
    assert_eq!(audit.deadline_at, "2026-07-30T10:11:00Z");
    assert_eq!(
        audit.status,
        TaskBoardDependencyFixAutomationStatus::RetryScheduled
    );
    assert_eq!(audit.stop_reason, None);
}

fn stopped_audit(
    request: &TaskBoardDependencyFixRequest,
    run: &TaskBoardDependencyFixRun,
    result: &TaskBoardDependencyFixResult,
    checks: &TaskBoardDependencyCheckResumeRecord,
) -> TaskBoardDependencyFixAuditTrail {
    let policy = TaskBoardDependencyFixAttemptPolicy {
        max_attempts: 1,
        max_elapsed_seconds: 3_600,
        max_equivalent_failures: 3,
    };
    match task_board_dependency_fix_retry_decision(
        &policy,
        request,
        run,
        result,
        checks,
        "2026-07-30T10:05:00Z",
    )
    .expect("stopped audit")
    {
        TaskBoardDependencyFixRetryDecision::HumanRequired(audit) => *audit,
        TaskBoardDependencyFixRetryDecision::Retry(_) => panic!("attempt bound stops"),
    }
}

fn expect_retry(decision: TaskBoardDependencyFixRetryDecision) -> TaskBoardDependencyFixRequest {
    match decision {
        TaskBoardDependencyFixRetryDecision::Retry(request) => *request,
        TaskBoardDependencyFixRetryDecision::HumanRequired(_) => panic!("expected retry"),
    }
}

fn run(request: &TaskBoardDependencyFixRequest, started_at: &str) -> TaskBoardDependencyFixRun {
    TaskBoardDependencyFixRun {
        run_id: request.dispatch_id.clone(),
        runtime: "codex".into(),
        requested_model: "gpt-5.3-codex-spark".into(),
        requested_effort: "low".into(),
        attempt: request.attempt,
        started_at: started_at.into(),
        failure_evidence_id: request
            .retry_evidence
            .as_ref()
            .map(|evidence| evidence.evidence_id.clone()),
    }
}

fn result(
    request: &TaskBoardDependencyFixRequest,
    head_revision: &str,
) -> TaskBoardDependencyFixResult {
    TaskBoardDependencyFixResult {
        schema_version: TASK_BOARD_DEPENDENCY_FIX_RESULT_SCHEMA_VERSION,
        dispatch_id: request.dispatch_id.clone(),
        route_id: request.route_id.clone(),
        base_head_revision: request.exact_head_revision.clone(),
        head_revision: head_revision.into(),
        summary: "Updated the lockfile".into(),
        changed_paths: vec!["Cargo.lock".into()],
        validation: vec!["mise run harness:check passed".into()],
        remaining_blockers: Vec::new(),
    }
}

fn failed_checks(
    exact_head_revision: &str,
    failed_name: &str,
    details_url: &str,
) -> TaskBoardDependencyCheckResumeRecord {
    TaskBoardDependencyCheckResumeRecord {
        resume_id: format!("route-1:checks:{exact_head_revision}"),
        route_id: "route-1".into(),
        identity: PullRequestIdentity::from_slug("acme/widgets", 17),
        exact_head_revision: exact_head_revision.into(),
        status: TaskBoardDependencyCheckResumeStatus::ChecksFailed {
            checks: vec![
                TaskBoardDependencySettledCheck {
                    name: failed_name.into(),
                    conclusion: TaskBoardDependencyCheckConclusion::Failure,
                    details_url: Some(details_url.into()),
                },
                TaskBoardDependencySettledCheck {
                    name: "security".into(),
                    conclusion: TaskBoardDependencyCheckConclusion::Success,
                    details_url: None,
                },
            ],
        },
    }
}

fn request() -> TaskBoardDependencyFixRequest {
    TaskBoardDependencyFixRequest {
        dispatch_id: "route-1:fix".into(),
        route_id: "route-1".into(),
        session_id: "session-1".into(),
        board_item_id: "item-1".into(),
        workflow_execution_id: "execution-1".into(),
        attempt: 1,
        attempt_policy: TaskBoardDependencyFixAttemptPolicy::default(),
        repository: "acme/widgets".into(),
        pull_request_number: 17,
        exact_head_revision: HEAD_1.into(),
        requested_repair: "repair the failing build".into(),
        triage_result: triage(),
        retry_evidence: None,
        audit: None,
    }
}

fn triage() -> TaskBoardDependencyTriageResult {
    TaskBoardDependencyTriageResult {
        schema_version: TASK_BOARD_DEPENDENCY_TRIAGE_SCHEMA_VERSION,
        repository: "acme/widgets".into(),
        pull_request_number: 17,
        exact_head_revision: HEAD_1.into(),
        dependency: TaskBoardDependencyIdentity {
            name: "serde".into(),
            ecosystem: "cargo".into(),
            current_version: "1.0.0".into(),
            target_version: "1.0.1".into(),
            update_class: TaskBoardDependencyUpdateClass::Patch,
        },
        checks: vec![TaskBoardDependencyCheck {
            name: "test".into(),
            state: TaskBoardDependencyCheckState::Failed,
            details_url: Some("https://ci.example.test/initial".into()),
        }],
        conflicts: TaskBoardDependencyConflictEvidence {
            state: TaskBoardDependencyConflictState::Clean,
            summary: "clean".into(),
        },
        approvals: TaskBoardDependencyApprovalEvidence {
            current: 1,
            required: 1,
        },
        safety_assumption: "the exact-head evidence is current".into(),
        disposition: TaskBoardDependencyTriageDisposition::FixRequired,
        required_tools: vec!["task_board.audit".into(), "codex.dispatch".into()],
        next_steps: vec![TaskBoardDependencyTriageStep {
            order: 1,
            action: "dispatch_fixer".into(),
            reason: "repair the failing build".into(),
        }],
    }
}
