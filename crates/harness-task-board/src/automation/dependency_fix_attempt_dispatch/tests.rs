use std::{slice::from_ref, sync::Mutex};

use super::*;
use crate::github::PullRequestIdentity;
use crate::{
    TASK_BOARD_DEPENDENCY_FIX_RESULT_SCHEMA_VERSION, TASK_BOARD_DEPENDENCY_TRIAGE_SCHEMA_VERSION,
    TaskBoardDependencyApprovalEvidence, TaskBoardDependencyCheck,
    TaskBoardDependencyCheckConclusion, TaskBoardDependencyCheckResumeStatus,
    TaskBoardDependencyCheckState, TaskBoardDependencyConflictEvidence,
    TaskBoardDependencyConflictState, TaskBoardDependencyFixAttemptPolicy,
    TaskBoardDependencyIdentity, TaskBoardDependencySettledCheck,
    TaskBoardDependencyTriageDisposition, TaskBoardDependencyTriageResult,
    TaskBoardDependencyTriageStep, TaskBoardDependencyUpdateClass,
};

const HEAD_1: &str = "0123456789abcdef0123456789abcdef01234567";
const HEAD_2: &str = "123456789abcdef0123456789abcdef012345678";

#[tokio::test]
async fn retry_audit_is_persisted_before_the_next_run_starts() {
    let request = request();
    let sink = Sink::default();
    let launcher = Launcher::default();

    let outcome = continue_task_board_dependency_fix_after_failed_checks(
        TaskBoardDependencyFixFailedAttempt {
            previous_request: &request,
            previous_run: &run(&request),
            previous_result: &result(&request),
            checks: &failed_checks(),
            completed_at: "2026-07-30T10:05:00Z",
        },
        &sink,
        &launcher,
    )
    .await
    .expect("retry outcome");
    let TaskBoardDependencyFixAttemptOutcome::RetryScheduled { request, run } = outcome else {
        panic!("first failure should retry");
    };

    assert_eq!(request.attempt, 2);
    assert_eq!(run.attempt, 2);
    assert_eq!(launcher.starts.lock().expect("starts").as_slice(), &[2]);
    let audits = sink.audits.lock().expect("audits");
    assert_eq!(audits.len(), 1);
    assert_eq!(audits[0], *request.audit.as_ref().expect("request audit"));
    assert_eq!(
        audits[0].status,
        super::super::TaskBoardDependencyFixAutomationStatus::RetryScheduled
    );
}

#[tokio::test]
async fn attempt_bound_persists_human_required_without_starting_codex() {
    let sink = Sink::default();
    let launcher = Launcher::default();
    let mut request = request();
    request.attempt_policy = TaskBoardDependencyFixAttemptPolicy {
        max_attempts: 1,
        max_elapsed_seconds: 3_600,
        max_equivalent_failures: 3,
    };

    let outcome = continue_task_board_dependency_fix_after_failed_checks(
        TaskBoardDependencyFixFailedAttempt {
            previous_request: &request,
            previous_run: &run(&request),
            previous_result: &result(&request),
            checks: &failed_checks(),
            completed_at: "2026-07-30T10:05:00Z",
        },
        &sink,
        &launcher,
    )
    .await
    .expect("bounded outcome");
    let TaskBoardDependencyFixAttemptOutcome::HumanRequired(audit) = outcome else {
        panic!("attempt bound should require a person");
    };

    assert!(launcher.starts.lock().expect("starts").is_empty());
    assert_eq!(sink.audits.lock().expect("audits").as_slice(), &[*audit]);
}

#[tokio::test]
async fn explicit_retry_persists_the_existing_history_before_starting() {
    let request = request();
    let run = run(&request);
    let result = result(&request);
    let checks = failed_checks();
    let stopped = match task_board_dependency_fix_retry_decision(
        &TaskBoardDependencyFixAttemptPolicy {
            max_attempts: 1,
            max_elapsed_seconds: 3_600,
            max_equivalent_failures: 3,
        },
        &request,
        &run,
        &result,
        &checks,
        "2026-07-30T10:05:00Z",
    )
    .expect("stopped audit")
    {
        TaskBoardDependencyFixRetryDecision::HumanRequired(audit) => audit,
        TaskBoardDependencyFixRetryDecision::Retry(_) => panic!("attempt bound should stop"),
    };
    let sink = Sink::default();
    let launcher = Launcher::default();

    let outcome = dispatch_explicit_task_board_dependency_fix_retry(
        TaskBoardDependencyFixExplicitRetry {
            previous_request: &request,
            previous_run: &run,
            previous_result: Some(&result),
            checks: Some(&checks),
            stopped_audit: &stopped,
            authorized_at: "2026-07-30T10:11:00Z",
        },
        &sink,
        &launcher,
    )
    .await
    .expect("explicit retry");
    let TaskBoardDependencyFixAttemptOutcome::RetryScheduled { request, .. } = outcome else {
        panic!("explicit retry should start");
    };
    let audit = request.audit.as_ref().expect("continued audit");

    assert_eq!(audit.attempt_count, stopped.attempt_count);
    assert_eq!(audit.current_attempt, 2);
    assert_eq!(
        sink.audits.lock().expect("audits").as_slice(),
        from_ref(audit)
    );
    assert_eq!(launcher.starts.lock().expect("starts").as_slice(), &[2]);
}

#[derive(Default)]
struct Sink {
    audits: Mutex<Vec<TaskBoardDependencyFixAuditTrail>>,
}

#[async_trait]
impl TaskBoardDependencyFixAuditSink for Sink {
    async fn record(&self, audit: &TaskBoardDependencyFixAuditTrail) -> Result<(), CliError> {
        self.audits.lock().expect("audits").push(audit.clone());
        Ok(())
    }
}

#[derive(Default)]
struct Launcher {
    starts: Mutex<Vec<u32>>,
}

#[async_trait]
impl TaskBoardDependencyFixLauncher for Launcher {
    async fn start(
        &self,
        request: &TaskBoardDependencyFixRequest,
    ) -> Result<TaskBoardDependencyFixRun, CliError> {
        let persisted_attempt = request
            .audit
            .as_ref()
            .map(|audit| audit.current_attempt)
            .ok_or_else(|| CliErrorKind::workflow_parse("launcher observed no persisted audit"))?;
        self.starts.lock().expect("starts").push(persisted_attempt);
        Ok(TaskBoardDependencyFixRun {
            run_id: request.dispatch_id.clone(),
            runtime: "codex".into(),
            requested_model: "gpt-5.3-codex-spark".into(),
            requested_effort: "low".into(),
            attempt: request.attempt,
            started_at: "2026-07-30T10:06:00Z".into(),
            failure_evidence_id: request
                .retry_evidence
                .as_ref()
                .map(|evidence| evidence.evidence_id.clone()),
        })
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

fn run(request: &TaskBoardDependencyFixRequest) -> TaskBoardDependencyFixRun {
    TaskBoardDependencyFixRun {
        run_id: request.dispatch_id.clone(),
        runtime: "codex".into(),
        requested_model: "gpt-5.3-codex-spark".into(),
        requested_effort: "low".into(),
        attempt: request.attempt,
        started_at: "2026-07-30T10:00:00Z".into(),
        failure_evidence_id: None,
    }
}

fn result(request: &TaskBoardDependencyFixRequest) -> TaskBoardDependencyFixResult {
    TaskBoardDependencyFixResult {
        schema_version: TASK_BOARD_DEPENDENCY_FIX_RESULT_SCHEMA_VERSION,
        dispatch_id: request.dispatch_id.clone(),
        route_id: request.route_id.clone(),
        base_head_revision: HEAD_1.into(),
        head_revision: HEAD_2.into(),
        summary: "Updated the lockfile".into(),
        changed_paths: vec!["Cargo.lock".into()],
        validation: vec!["mise run harness:check passed".into()],
        remaining_blockers: Vec::new(),
    }
}

fn failed_checks() -> TaskBoardDependencyCheckResumeRecord {
    TaskBoardDependencyCheckResumeRecord {
        resume_id: "route-1:checks".into(),
        route_id: "route-1".into(),
        identity: PullRequestIdentity::from_slug("acme/widgets", 17),
        exact_head_revision: HEAD_2.into(),
        status: TaskBoardDependencyCheckResumeStatus::ChecksFailed {
            checks: vec![TaskBoardDependencySettledCheck {
                name: "test".into(),
                conclusion: TaskBoardDependencyCheckConclusion::Failure,
                details_url: Some("https://ci.example.test/1".into()),
            }],
        },
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
