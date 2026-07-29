use std::sync::{Mutex, MutexGuard, PoisonError};

use super::*;
use crate::{
    TASK_BOARD_DEPENDENCY_TRIAGE_SCHEMA_VERSION, TaskBoardDependencyApprovalEvidence,
    TaskBoardDependencyCheck, TaskBoardDependencyConflictEvidence,
    TaskBoardDependencyConflictState, TaskBoardDependencyIdentity, TaskBoardDependencyTriageStep,
    TaskBoardDependencyUpdateClass,
};

const HEAD: &str = "0123456789abcdef0123456789abcdef01234567";

#[tokio::test]
async fn routes_every_disposition_without_a_github_mutation_surface() {
    let cases = [
        (
            TaskBoardDependencyTriageDisposition::ReportOnly,
            TaskBoardDependencyRouteStatus::ReportCompleted,
        ),
        (
            TaskBoardDependencyTriageDisposition::HumanRequired,
            TaskBoardDependencyRouteStatus::HumanRequired {
                unmet_requirement: "human decision required".into(),
            },
        ),
        (
            TaskBoardDependencyTriageDisposition::WaitForChecks,
            TaskBoardDependencyRouteStatus::WaitingForChecks {
                pending_checks: vec!["build".into()],
            },
        ),
        (
            TaskBoardDependencyTriageDisposition::FixRequired,
            TaskBoardDependencyRouteStatus::FixRequested,
        ),
        (
            TaskBoardDependencyTriageDisposition::ContinueSafe,
            TaskBoardDependencyRouteStatus::ReadyToContinue,
        ),
    ];

    for (disposition, expected) in cases {
        let store = Store::default();
        let result = result(disposition);
        let routed = route(&result, &store).await.expect("route result");

        assert!(routed.created);
        assert_eq!(routed.route.status, expected);
        assert_eq!(routed.route.repository, "acme/widgets");
        assert_eq!(routed.route.pull_request_number, 17);
        assert_eq!(routed.route.exact_head_revision, HEAD);
        assert_eq!(routed.route.source_result, result);
        assert_eq!(store.insertions(), 1);
    }
}

#[tokio::test]
async fn replaying_the_same_result_does_not_duplicate_work() {
    let store = Store::default();
    let result = result(TaskBoardDependencyTriageDisposition::FixRequired);

    let first = route(&result, &store).await.expect("first route");
    let replay = route(&result, &store).await.expect("replayed route");

    assert!(first.created);
    assert!(!replay.created);
    assert_eq!(replay.route, first.route);
    assert_eq!(store.insertions(), 1);
}

#[tokio::test]
async fn wait_is_bound_to_pending_checks_on_the_selected_head() {
    let store = Store::default();
    let mut result = result(TaskBoardDependencyTriageDisposition::WaitForChecks);
    result.checks.push(TaskBoardDependencyCheck {
        name: "lint".into(),
        state: TaskBoardDependencyCheckState::Passed,
        details_url: None,
    });

    let routed = route(&result, &store).await.expect("wait route");

    assert_eq!(
        routed.route.status,
        TaskBoardDependencyRouteStatus::WaitingForChecks {
            pending_checks: vec!["build".into()]
        }
    );
    assert_eq!(routed.route.exact_head_revision, HEAD);
}

#[tokio::test]
async fn unsafe_continuation_is_rejected_before_admission() {
    let store = Store::default();
    let mut result = result(TaskBoardDependencyTriageDisposition::ContinueSafe);
    result.checks[0].state = TaskBoardDependencyCheckState::Pending;

    let error = route(&result, &store)
        .await
        .expect_err("pending checks cannot continue");

    assert!(error.to_string().contains("contradicts its evidence"));
    assert_eq!(store.admissions(), 0);
}

#[tokio::test]
async fn stale_head_is_rejected_before_admission() {
    let store = Store::default();
    let result = result(TaskBoardDependencyTriageDisposition::ReportOnly);

    route_task_board_dependency_triage_result(
        &result,
        "acme/widgets",
        17,
        "abcdefabcdefabcdefabcdefabcdefabcdefabcd",
        &store,
    )
    .await
    .expect_err("stale head");

    assert_eq!(store.admissions(), 0);
}

#[tokio::test]
async fn route_id_collision_fails_closed() {
    let result = result(TaskBoardDependencyTriageDisposition::ReportOnly);
    let seeded = Store::default();
    let first = route(&result, &seeded).await.expect("seed route").route;
    let mut conflicting = first.clone();
    conflicting.reason = "different content".into();
    let store = Store::with_existing(conflicting);

    let error = route(&result, &store)
        .await
        .expect_err("route id collision");

    assert!(error.to_string().contains("reused for different content"));
}

async fn route(
    result: &TaskBoardDependencyTriageResult,
    store: &Store,
) -> Result<TaskBoardDependencyRouteOutcome, CliError> {
    route_task_board_dependency_triage_result(result, "acme/widgets", 17, HEAD, store).await
}

#[derive(Default)]
struct Store {
    state: Mutex<StoreState>,
}

#[derive(Default)]
struct StoreState {
    route: Option<TaskBoardDependencyRouteRecord>,
    admissions: usize,
    insertions: usize,
}

impl Store {
    fn with_existing(route: TaskBoardDependencyRouteRecord) -> Self {
        Self {
            state: Mutex::new(StoreState {
                route: Some(route),
                ..StoreState::default()
            }),
        }
    }

    fn admissions(&self) -> usize {
        self.lock().admissions
    }

    fn insertions(&self) -> usize {
        self.lock().insertions
    }

    fn lock(&self) -> MutexGuard<'_, StoreState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[async_trait]
impl TaskBoardDependencyRouteStore for Store {
    async fn admit(
        &self,
        route: TaskBoardDependencyRouteRecord,
    ) -> Result<TaskBoardDependencyRouteAdmission, CliError> {
        let mut state = self.lock();
        state.admissions += 1;
        if let Some(existing) = &state.route {
            return Ok(TaskBoardDependencyRouteAdmission::Duplicate(Box::new(
                existing.clone(),
            )));
        }
        state.route = Some(route);
        state.insertions += 1;
        Ok(TaskBoardDependencyRouteAdmission::Claimed)
    }
}

fn result(disposition: TaskBoardDependencyTriageDisposition) -> TaskBoardDependencyTriageResult {
    let (check_state, required_tools, terminal_action, terminal_reason) = match disposition {
        TaskBoardDependencyTriageDisposition::ReportOnly => (
            TaskBoardDependencyCheckState::Passed,
            vec!["task_board.audit"],
            "complete_report",
            "report completed",
        ),
        TaskBoardDependencyTriageDisposition::HumanRequired => (
            TaskBoardDependencyCheckState::Passed,
            vec!["task_board.audit"],
            "require_human",
            "human decision required",
        ),
        TaskBoardDependencyTriageDisposition::WaitForChecks => (
            TaskBoardDependencyCheckState::Pending,
            vec!["task_board.audit", "github.read"],
            "wait_for_checks",
            "build is pending",
        ),
        TaskBoardDependencyTriageDisposition::FixRequired => (
            TaskBoardDependencyCheckState::Failed,
            vec!["task_board.audit", "codex.dispatch"],
            "dispatch_fixer",
            "build requires a code fix",
        ),
        TaskBoardDependencyTriageDisposition::ContinueSafe => (
            TaskBoardDependencyCheckState::Passed,
            vec!["task_board.audit", "task_board.advance"],
            "continue_workflow",
            "all current evidence passes",
        ),
    };
    TaskBoardDependencyTriageResult {
        schema_version: TASK_BOARD_DEPENDENCY_TRIAGE_SCHEMA_VERSION,
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
            name: "build".into(),
            state: check_state,
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
        safety_assumption: "current evidence is complete".into(),
        disposition,
        required_tools: required_tools.into_iter().map(str::to_owned).collect(),
        next_steps: vec![
            TaskBoardDependencyTriageStep {
                order: 1,
                action: "record_result".into(),
                reason: "retain source result".into(),
            },
            TaskBoardDependencyTriageStep {
                order: 2,
                action: terminal_action.into(),
                reason: terminal_reason.into(),
            },
        ],
    }
}
