use std::{collections::BTreeSet, sync::Mutex};

use async_trait::async_trait;

use super::super::*;
use super::{CHANGED_HEAD, FAILED_HEAD, HEAD};
use crate::github::PullRequestIdentity;
use crate::{
    TaskBoardDependencyApprovalEvidence, TaskBoardDependencyCheck, TaskBoardDependencyCheckState,
    TaskBoardDependencyConflictEvidence, TaskBoardDependencyConflictState,
    TaskBoardDependencyIdentity, TaskBoardDependencyRouteAdmission,
    TaskBoardDependencySettledCheck, TaskBoardDependencyTriageStep, TaskBoardDependencyUpdateClass,
};

pub(super) fn assert_invalid(
    result: &TaskBoardDependencyFixResult,
    request: &TaskBoardDependencyFixRequest,
) {
    let report = serde_json::to_string(result).expect("serialize result");
    parse_task_board_dependency_fix_result(&report, request).expect_err("invalid result");
}

pub(super) fn changed_result(
    request: &TaskBoardDependencyFixRequest,
) -> TaskBoardDependencyFixResult {
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

pub(super) fn run_for(request: &TaskBoardDependencyFixRequest) -> TaskBoardDependencyFixRun {
    TaskBoardDependencyFixRun {
        run_id: request.dispatch_id.clone(),
        runtime: "codex".into(),
        requested_model: TASK_BOARD_DEPENDENCY_FIXER_MODEL.into(),
        requested_effort: TASK_BOARD_DEPENDENCY_FIXER_EFFORT.into(),
        attempt: request.attempt,
        started_at: "2026-07-30T10:00:00Z".into(),
        failure_evidence_id: request
            .retry_evidence
            .as_ref()
            .map(|evidence| evidence.evidence_id.clone()),
    }
}

pub(super) fn failed_checks(route_id: &str) -> TaskBoardDependencyCheckResumeRecord {
    TaskBoardDependencyCheckResumeRecord {
        resume_id: format!("{route_id}:checks"),
        route_id: route_id.into(),
        identity: PullRequestIdentity::from_slug("acme/widgets", 17),
        exact_head_revision: FAILED_HEAD.into(),
        status: TaskBoardDependencyCheckResumeStatus::ChecksFailed {
            checks: settled_checks(),
        },
    }
}

pub(super) fn settled_checks() -> Vec<TaskBoardDependencySettledCheck> {
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
pub(super) struct Launcher {
    requests: Mutex<Vec<TaskBoardDependencyFixRequest>>,
}

impl Launcher {
    pub(super) fn request(&self) -> Option<TaskBoardDependencyFixRequest> {
        self.requests.lock().expect("requests lock").last().cloned()
    }

    pub(super) fn start_count(&self) -> usize {
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
            started_at: "2026-07-30T10:00:00Z".into(),
            failure_evidence_id: request
                .retry_evidence
                .as_ref()
                .map(|evidence| evidence.evidence_id.clone()),
        })
    }
}

#[derive(Default)]
pub(super) struct RouteStore {
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

pub(super) fn binding() -> TaskBoardDependencyFixBinding {
    TaskBoardDependencyFixBinding {
        session_id: "session-1".into(),
        board_item_id: "item-1".into(),
        workflow_execution_id: "execution-1".into(),
    }
}

pub(super) fn route(
    disposition: TaskBoardDependencyTriageDisposition,
) -> TaskBoardDependencyRouteRecord {
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
