use std::sync::Mutex;

use async_trait::async_trait;
use harness_kernel::errors::CliError;
use harness_task_board::{
    TASK_BOARD_DEPENDENCY_FIXER_EFFORT, TASK_BOARD_DEPENDENCY_FIXER_MODEL,
    TaskBoardDependencyApprovalEvidence, TaskBoardDependencyCheck, TaskBoardDependencyCheckState,
    TaskBoardDependencyConflictEvidence, TaskBoardDependencyConflictState,
    TaskBoardDependencyFixBinding, TaskBoardDependencyIdentity, TaskBoardDependencyRouteAdmission,
    TaskBoardDependencyRouteRecord, TaskBoardDependencyRouteStore,
    TaskBoardDependencyTriageDisposition, TaskBoardDependencyTriageResult,
    TaskBoardDependencyTriageStep, TaskBoardDependencyUpdateClass,
};

use crate::daemon::protocol::CodexRunMode;

use super::test_support::{controller_with_db, with_isolated_async_harness_env};

const HEAD: &str = "0123456789abcdef0123456789abcdef01234567";

#[tokio::test]
async fn launcher_starts_one_bound_codex_app_server_run() {
    with_isolated_async_harness_env(|_| async move {
        let (controller, _db, _tempdir) = controller_with_db();
        let store = RouteStore::default();
        let binding = dependency_fix_binding();
        let result = dependency_triage_result();

        let outcome = controller
            .route_dependency_triage_and_start_fixer(
                &result,
                "acme/widgets",
                17,
                HEAD,
                &store,
                &binding,
            )
            .await
            .expect("route and start fixer");
        let run = outcome.run.expect("started fixer");

        assert_eq!(run.runtime, "codex");
        assert_eq!(run.requested_model, TASK_BOARD_DEPENDENCY_FIXER_MODEL);
        assert_eq!(run.requested_effort, TASK_BOARD_DEPENDENCY_FIXER_EFFORT);
        let snapshot = controller.run(&run.run_id).expect("load fixer run");
        assert_eq!(snapshot.mode, CodexRunMode::WorkspaceWrite);
        assert_eq!(
            snapshot.model.as_deref(),
            Some(TASK_BOARD_DEPENDENCY_FIXER_MODEL)
        );
        assert_eq!(
            snapshot.effort.as_deref(),
            Some(TASK_BOARD_DEPENDENCY_FIXER_EFFORT)
        );
        assert_eq!(snapshot.board_item_id.as_deref(), Some("item-1"));
        assert_eq!(
            snapshot.workflow_execution_id.as_deref(),
            Some("execution-1")
        );
    })
    .await;
}

fn dependency_fix_binding() -> TaskBoardDependencyFixBinding {
    TaskBoardDependencyFixBinding {
        session_id: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        board_item_id: "item-1".into(),
        workflow_execution_id: "execution-1".into(),
    }
}

fn dependency_triage_result() -> TaskBoardDependencyTriageResult {
    TaskBoardDependencyTriageResult {
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
            state: TaskBoardDependencyCheckState::Failed,
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
        safety_assumption: "the exact-head evidence is current".into(),
        disposition: TaskBoardDependencyTriageDisposition::FixRequired,
        required_tools: vec!["task_board.audit".into(), "codex.dispatch".into()],
        next_steps: vec![
            TaskBoardDependencyTriageStep {
                order: 1,
                action: "record_result".into(),
                reason: "retain the triage decision".into(),
            },
            TaskBoardDependencyTriageStep {
                order: 2,
                action: "dispatch_fixer".into(),
                reason: "repair the failing build".into(),
            },
        ],
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
