use harness_task_board::{
    TASK_BOARD_DEPENDENCY_FIXER_EFFORT, TASK_BOARD_DEPENDENCY_FIXER_MODEL,
    TaskBoardDependencyApprovalEvidence, TaskBoardDependencyCheck, TaskBoardDependencyCheckState,
    TaskBoardDependencyConflictEvidence, TaskBoardDependencyConflictState,
    TaskBoardDependencyFixLauncher, TaskBoardDependencyFixRequest, TaskBoardDependencyIdentity,
    TaskBoardDependencyTriageDisposition, TaskBoardDependencyTriageResult,
    TaskBoardDependencyTriageStep, TaskBoardDependencyUpdateClass,
};

use crate::daemon::codex_controller::CodexDependencyFixLauncher;
use crate::daemon::protocol::CodexRunMode;

use super::test_support::{controller_with_db, with_isolated_async_harness_env};

const HEAD: &str = "0123456789abcdef0123456789abcdef01234567";

#[tokio::test]
async fn launcher_starts_one_bound_codex_app_server_run() {
    with_isolated_async_harness_env(|_| async move {
        let (controller, _db, _tempdir) = controller_with_db();
        let launcher = CodexDependencyFixLauncher::new(controller.clone());
        let request = dependency_fix_request();

        let run = launcher.start(&request).await.expect("start fixer");

        assert_eq!(run.run_id, request.dispatch_id);
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

fn dependency_fix_request() -> TaskBoardDependencyFixRequest {
    TaskBoardDependencyFixRequest {
        dispatch_id: "route-1:fix".into(),
        route_id: "route-1".into(),
        session_id: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        board_item_id: "item-1".into(),
        workflow_execution_id: "execution-1".into(),
        repository: "acme/widgets".into(),
        pull_request_number: 17,
        exact_head_revision: HEAD.into(),
        requested_repair: "repair the failing build".into(),
        triage_result: TaskBoardDependencyTriageResult {
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
        },
    }
}
