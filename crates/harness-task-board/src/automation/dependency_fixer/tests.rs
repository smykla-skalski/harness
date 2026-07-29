use std::sync::Mutex;

use super::*;
use crate::{
    TaskBoardDependencyApprovalEvidence, TaskBoardDependencyCheck, TaskBoardDependencyCheckState,
    TaskBoardDependencyConflictEvidence, TaskBoardDependencyConflictState,
    TaskBoardDependencyIdentity, TaskBoardDependencyTriageStep, TaskBoardDependencyUpdateClass,
};

const HEAD: &str = "0123456789abcdef0123456789abcdef01234567";
const CHANGED_HEAD: &str = "abcdefabcdefabcdefabcdefabcdefabcdefabcd";

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
        })
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
