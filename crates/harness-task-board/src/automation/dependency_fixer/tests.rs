use std::sync::Mutex;

use super::*;
use crate::{
    TaskBoardDependencyApprovalEvidence, TaskBoardDependencyCheck, TaskBoardDependencyCheckState,
    TaskBoardDependencyConflictEvidence, TaskBoardDependencyConflictState,
    TaskBoardDependencyIdentity, TaskBoardDependencyRouteAdmission,
    TaskBoardDependencySettledCheck, TaskBoardDependencyTriageStep, TaskBoardDependencyUpdateClass,
};

const HEAD: &str = "0123456789abcdef0123456789abcdef01234567";
const CHANGED_HEAD: &str = "abcdefabcdefabcdefabcdefabcdefabcdefabcd";
const FAILED_HEAD: &str = "123456789abcdef0123456789abcdef012345678";

#[tokio::test]
async fn dispatches_only_an_explicit_fix_route_with_all_evidence() {
    let launcher = Launcher::default();
    let fix = route(TaskBoardDependencyTriageDisposition::FixRequired);

    let run = dispatch_task_board_dependency_fix(&fix, &binding(), &launcher)
        .await
        .expect("fix route dispatches");

    assert_eq!(run.run_id, format!("{}:fix", fix.route_id));
    assert_eq!(run.requested_model, TASK_BOARD_DEPENDENCY_FIXER_MODEL);
    assert_eq!(run.requested_effort, TASK_BOARD_DEPENDENCY_FIXER_EFFORT);
    assert_eq!(run.attempt, 1);
    assert_eq!(run.failure_evidence_id, None);
    let request = launcher.request().expect("captured request");
    assert_eq!(request.exact_head_revision, HEAD);
    assert_eq!(request.requested_repair, "build requires a code fix");
    assert_eq!(request.triage_result.checks[0].name, "test");

    for disposition in [
        TaskBoardDependencyTriageDisposition::ReportOnly,
        TaskBoardDependencyTriageDisposition::HumanRequired,
        TaskBoardDependencyTriageDisposition::WaitForChecks,
        TaskBoardDependencyTriageDisposition::ContinueSafe,
    ] {
        let before = launcher.start_count();
        let error = dispatch_task_board_dependency_fix(&route(disposition), &binding(), &launcher)
            .await
            .expect_err("non-fix route must not dispatch");
        assert!(
            error
                .to_string()
                .contains("does not explicitly require a code fix")
        );
        assert_eq!(launcher.start_count(), before);
    }
}

#[tokio::test]
async fn duplicate_fix_route_retries_the_deterministic_launcher() {
    let store = RouteStore::default();
    let launcher = Launcher::default();
    let result = route(TaskBoardDependencyTriageDisposition::FixRequired).source_result;

    let first = route_and_dispatch_task_board_dependency_fix(
        &result,
        "acme/widgets",
        17,
        HEAD,
        &store,
        &binding(),
        &launcher,
    )
    .await
    .expect("admitted fix dispatch");
    assert!(first.created);
    let first_run = first.run.expect("first run");

    let duplicate = route_and_dispatch_task_board_dependency_fix(
        &result,
        "acme/widgets",
        17,
        HEAD,
        &store,
        &binding(),
        &launcher,
    )
    .await
    .expect("duplicate fix route");
    assert!(!duplicate.created);
    let duplicate_run = duplicate.run.expect("recovered run");
    assert_eq!(duplicate_run.run_id, first_run.run_id);
    assert_eq!(launcher.start_count(), 2);
}

#[tokio::test]
async fn retry_binds_failed_head_diagnostics_and_prior_attempt() {
    let previous_request = task_board_dependency_fix_request(
        &route(TaskBoardDependencyTriageDisposition::FixRequired),
        &binding(),
    )
    .expect("initial request");
    let previous_result = changed_result(&previous_request);
    let previous_run = run_for(&previous_request);
    let checks = failed_checks(&previous_request.route_id);

    let retry = task_board_dependency_fix_retry_request(
        &previous_request,
        &previous_run,
        &previous_result,
        &checks,
    )
    .expect("retry request");

    assert_eq!(retry.attempt, 2);
    assert_eq!(retry.dispatch_id, format!("{}:fix:2", retry.route_id));
    assert_eq!(retry.exact_head_revision, FAILED_HEAD);
    let evidence = retry.retry_evidence.as_ref().expect("retry evidence");
    assert_eq!(evidence.exact_head_revision, FAILED_HEAD);
    assert_eq!(evidence.prior_attempt.attempt, 1);
    assert_eq!(evidence.prior_attempt.run_id, previous_run.run_id);
    assert_eq!(evidence.prior_attempt.summary, previous_result.summary);
    assert_eq!(
        evidence.prior_attempt.validation,
        previous_result.validation
    );
    assert_eq!(
        evidence.checks[0].diagnostics,
        TaskBoardDependencyFixDiagnosticEvidence::Available {
            url: "https://ci.example.test/build/17".into()
        }
    );
    assert_eq!(
        evidence.checks[1].diagnostics,
        TaskBoardDependencyFixDiagnosticEvidence::Unavailable
    );

    let prompt = render_task_board_dependency_fix_prompt(&retry).expect("retry prompt");
    for expected in [
        "Fixer attempt: 2",
        "Retry failure evidence received by this run",
        "Original triage report for historical head",
        FAILED_HEAD,
        "https://ci.example.test/build/17",
        "\"availability\": \"unavailable\"",
        "Updated the lockfile",
        "mise run harness:check passed",
    ] {
        assert!(prompt.contains(expected), "missing {expected}");
    }

    let launcher = Launcher::default();
    let run = launcher.start(&retry).await.expect("retry launch");
    assert_eq!(run.attempt, 2);
    assert_eq!(
        run.failure_evidence_id.as_deref(),
        Some(evidence.evidence_id.as_str())
    );
}

#[test]
fn retry_rejects_non_failure_and_mismatched_prior_run_evidence() {
    let previous_request = task_board_dependency_fix_request(
        &route(TaskBoardDependencyTriageDisposition::FixRequired),
        &binding(),
    )
    .expect("initial request");
    let previous_result = changed_result(&previous_request);
    let mut previous_run = run_for(&previous_request);
    let mut checks = failed_checks(&previous_request.route_id);
    checks.status = TaskBoardDependencyCheckResumeStatus::ChecksPassed {
        checks: settled_checks(),
    };
    assert!(
        task_board_dependency_fix_retry_request(
            &previous_request,
            &previous_run,
            &previous_result,
            &checks,
        )
        .is_err()
    );

    checks = failed_checks(&previous_request.route_id);
    checks.identity =
        crate::github::PullRequestIdentity::from_slug("acme/other-widgets", 17);
    assert!(
        task_board_dependency_fix_retry_request(
            &previous_request,
            &previous_run,
            &previous_result,
            &checks,
        )
        .is_err()
    );

    previous_run.run_id = "different-run".into();
    assert!(
        task_board_dependency_fix_retry_request(
            &previous_request,
            &previous_run,
            &previous_result,
            &failed_checks(&previous_request.route_id),
        )
        .is_err()
    );

    previous_run = run_for(&previous_request);
    previous_run.failure_evidence_id = Some("unexpected-evidence".into());
    assert!(
        task_board_dependency_fix_retry_request(
            &previous_request,
            &previous_run,
            &previous_result,
            &failed_checks(&previous_request.route_id),
        )
        .is_err()
    );
}

#[test]
fn dispatch_binding_rejects_surrounding_whitespace() {
    let mut invalid = binding();
    invalid.session_id.insert(0, ' ');

    let error = task_board_dependency_fix_request(
        &route(TaskBoardDependencyTriageDisposition::FixRequired),
        &invalid,
    )
    .expect_err("non-canonical binding");

    assert!(error.to_string().contains("incomplete exact-head context"));
}

#[test]
fn prompt_binds_the_head_repair_triage_and_result_contract() {
    let request = task_board_dependency_fix_request(
        &route(TaskBoardDependencyTriageDisposition::FixRequired),
        &binding(),
    )
    .expect("fix request");

    let prompt = render_task_board_dependency_fix_prompt(&request).expect("prompt");

    for expected in [
        "acme/widgets#17",
        HEAD,
        "build requires a code fix",
        "\"checks\"",
        "\"changed_paths\"",
        "\"validation\"",
        "\"remaining_blockers\"",
    ] {
        assert!(prompt.contains(expected), "missing {expected}");
    }
}

#[test]
fn result_requires_changed_paths_validation_and_a_new_head_or_a_blocker() {
    let request = task_board_dependency_fix_request(
        &route(TaskBoardDependencyTriageDisposition::FixRequired),
        &binding(),
    )
    .expect("fix request");
    let changed = TaskBoardDependencyFixResult {
        schema_version: TASK_BOARD_DEPENDENCY_FIX_RESULT_SCHEMA_VERSION,
        dispatch_id: request.dispatch_id.clone(),
        route_id: request.route_id.clone(),
        base_head_revision: HEAD.into(),
        head_revision: CHANGED_HEAD.into(),
        summary: "Updated the lockfile".into(),
        changed_paths: vec!["Cargo.lock".into()],
        validation: vec!["mise run harness:check passed".into()],
        remaining_blockers: Vec::new(),
    };
    let report = serde_json::to_string(&changed).expect("serialize result");
    assert_eq!(
        parse_task_board_dependency_fix_result(&report, &request).expect("valid result"),
        changed
    );

    let mut missing_validation = changed.clone();
    missing_validation.validation.clear();
    assert_invalid(&missing_validation, &request);

    let blocked = TaskBoardDependencyFixResult {
        head_revision: HEAD.into(),
        changed_paths: Vec::new(),
        validation: Vec::new(),
        remaining_blockers: vec!["repository checkout is read-only".into()],
        ..changed
    };
    let report = serde_json::to_string(&blocked).expect("serialize blocked result");
    parse_task_board_dependency_fix_result(&report, &request).expect("explained no-change result");

    let unexplained = TaskBoardDependencyFixResult {
        remaining_blockers: Vec::new(),
        ..blocked
    };
    assert_invalid(&unexplained, &request);
}

fn assert_invalid(result: &TaskBoardDependencyFixResult, request: &TaskBoardDependencyFixRequest) {
    let report = serde_json::to_string(result).expect("serialize result");
    parse_task_board_dependency_fix_result(&report, request).expect_err("invalid result");
}

fn changed_result(request: &TaskBoardDependencyFixRequest) -> TaskBoardDependencyFixResult {
    TaskBoardDependencyFixResult {
        schema_version: TASK_BOARD_DEPENDENCY_FIX_RESULT_SCHEMA_VERSION,
        dispatch_id: request.dispatch_id.clone(),
        route_id: request.route_id.clone(),
        base_head_revision: HEAD.into(),
        head_revision: CHANGED_HEAD.into(),
        summary: "Updated the lockfile".into(),
        changed_paths: vec!["Cargo.lock".into()],
        validation: vec!["mise run harness:check passed".into()],
        remaining_blockers: Vec::new(),
    }
}

fn run_for(request: &TaskBoardDependencyFixRequest) -> TaskBoardDependencyFixRun {
    TaskBoardDependencyFixRun {
        run_id: request.dispatch_id.clone(),
        runtime: "codex".into(),
        requested_model: TASK_BOARD_DEPENDENCY_FIXER_MODEL.into(),
        requested_effort: TASK_BOARD_DEPENDENCY_FIXER_EFFORT.into(),
        attempt: request.attempt,
        failure_evidence_id: request
            .retry_evidence
            .as_ref()
            .map(|evidence| evidence.evidence_id.clone()),
    }
}

fn failed_checks(route_id: &str) -> TaskBoardDependencyCheckResumeRecord {
    TaskBoardDependencyCheckResumeRecord {
        resume_id: format!("{route_id}:checks"),
        route_id: route_id.into(),
        identity: crate::github::PullRequestIdentity::from_slug("acme/widgets", 17),
        exact_head_revision: FAILED_HEAD.into(),
        status: TaskBoardDependencyCheckResumeStatus::ChecksFailed {
            checks: settled_checks(),
        },
    }
}

fn settled_checks() -> Vec<TaskBoardDependencySettledCheck> {
    vec![
        TaskBoardDependencySettledCheck {
            name: "build".into(),
            conclusion: TaskBoardDependencyCheckConclusion::Failure,
            details_url: Some("https://ci.example.test/build/17".into()),
        },
        TaskBoardDependencySettledCheck {
            name: "lint".into(),
            conclusion: TaskBoardDependencyCheckConclusion::Skipped,
            details_url: None,
        },
    ]
}

#[derive(Default)]
struct Launcher {
    requests: Mutex<Vec<TaskBoardDependencyFixRequest>>,
}

impl Launcher {
    fn request(&self) -> Option<TaskBoardDependencyFixRequest> {
        self.requests.lock().expect("requests lock").last().cloned()
    }

    fn start_count(&self) -> usize {
        self.requests.lock().expect("requests lock").len()
    }
}

#[async_trait]
impl TaskBoardDependencyFixLauncher for Launcher {
    async fn start(
        &self,
        request: &TaskBoardDependencyFixRequest,
    ) -> Result<TaskBoardDependencyFixRun, CliError> {
        self.requests
            .lock()
            .expect("requests lock")
            .push(request.clone());
        Ok(TaskBoardDependencyFixRun {
            run_id: request.dispatch_id.clone(),
            runtime: "codex".into(),
            requested_model: TASK_BOARD_DEPENDENCY_FIXER_MODEL.into(),
            requested_effort: TASK_BOARD_DEPENDENCY_FIXER_EFFORT.into(),
            attempt: request.attempt,
            failure_evidence_id: request
                .retry_evidence
                .as_ref()
                .map(|evidence| evidence.evidence_id.clone()),
        })
    }
}

#[derive(Default)]
struct RouteStore {
    route: Mutex<Option<TaskBoardDependencyRouteRecord>>,
}

#[async_trait]
impl TaskBoardDependencyRouteStore for RouteStore {
    async fn admit(
        &self,
        route: TaskBoardDependencyRouteRecord,
    ) -> Result<TaskBoardDependencyRouteAdmission, CliError> {
        let mut stored = self.route.lock().expect("route lock");
        if let Some(existing) = stored.as_ref() {
            return Ok(TaskBoardDependencyRouteAdmission::Duplicate(Box::new(
                existing.clone(),
            )));
        }
        *stored = Some(route);
        Ok(TaskBoardDependencyRouteAdmission::Claimed)
    }
}

fn binding() -> TaskBoardDependencyFixBinding {
    TaskBoardDependencyFixBinding {
        session_id: "session-1".into(),
        board_item_id: "item-1".into(),
        workflow_execution_id: "execution-1".into(),
    }
}

fn route(disposition: TaskBoardDependencyTriageDisposition) -> TaskBoardDependencyRouteRecord {
    let (status, action, tool, check_state) = match disposition {
        TaskBoardDependencyTriageDisposition::FixRequired => (
            TaskBoardDependencyRouteStatus::FixRequested,
            "dispatch_fixer",
            "codex.dispatch",
            TaskBoardDependencyCheckState::Failed,
        ),
        TaskBoardDependencyTriageDisposition::ReportOnly => (
            TaskBoardDependencyRouteStatus::ReportCompleted,
            "complete_report",
            "task_board.audit",
            TaskBoardDependencyCheckState::Passed,
        ),
        TaskBoardDependencyTriageDisposition::HumanRequired => (
            TaskBoardDependencyRouteStatus::HumanRequired {
                unmet_requirement: "approval needed".into(),
            },
            "require_human",
            "task_board.audit",
            TaskBoardDependencyCheckState::Passed,
        ),
        TaskBoardDependencyTriageDisposition::WaitForChecks => (
            TaskBoardDependencyRouteStatus::WaitingForChecks {
                pending_checks: vec!["test".into()],
            },
            "wait_for_checks",
            "github.read",
            TaskBoardDependencyCheckState::Pending,
        ),
        TaskBoardDependencyTriageDisposition::ContinueSafe => (
            TaskBoardDependencyRouteStatus::ReadyToContinue,
            "continue_workflow",
            "task_board.advance",
            TaskBoardDependencyCheckState::Passed,
        ),
    };
    let result = TaskBoardDependencyTriageResult {
        schema_version: 1,
        repository: "acme/widgets".into(),
        pull_request_number: 17,
        exact_head_revision: HEAD.into(),
        dependency: TaskBoardDependencyIdentity {
            name: "serde".into(),
            ecosystem: "cargo".into(),
            current_version: "1.0.0".into(),
            target_version: "1.0.1".into(),
            update_class: TaskBoardDependencyUpdateClass::Patch,
        },
        checks: vec![TaskBoardDependencyCheck {
            name: "test".into(),
            state: check_state,
            details_url: Some("https://example.test/check/1".into()),
        }],
        conflicts: TaskBoardDependencyConflictEvidence {
            state: TaskBoardDependencyConflictState::Clean,
            summary: "clean".into(),
        },
        approvals: TaskBoardDependencyApprovalEvidence {
            current: 1,
            required: 1,
        },
        safety_assumption: "exact-head evidence is current".into(),
        disposition,
        required_tools: vec!["task_board.audit".into(), tool.into()]
            .into_iter()
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect(),
        next_steps: vec![
            TaskBoardDependencyTriageStep {
                order: 1,
                action: "record_result".into(),
                reason: "retain the decision".into(),
            },
            TaskBoardDependencyTriageStep {
                order: 2,
                action: action.into(),
                reason: "apply the route".into(),
            },
        ],
    };
    TaskBoardDependencyRouteRecord {
        route_id: format!("route-{disposition:?}"),
        repository: "acme/widgets".into(),
        pull_request_number: 17,
        exact_head_revision: HEAD.into(),
        status,
        reason: "build requires a code fix".into(),
        source_result: result,
    }
}
