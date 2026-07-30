use std::sync::Mutex;

use async_trait::async_trait;
use harness_kernel::errors::CliError;
use harness_task_board::{
    TASK_BOARD_DEPENDENCY_FIXER_EFFORT, TASK_BOARD_DEPENDENCY_FIXER_MODEL,
    TaskBoardDependencyApprovalEvidence, TaskBoardDependencyCheck, TaskBoardDependencyCheckState,
    TaskBoardDependencyConflictEvidence, TaskBoardDependencyConflictState,
    TaskBoardDependencyFixAttemptEvidence, TaskBoardDependencyFixAuditSink,
    TaskBoardDependencyFixAuditTrail, TaskBoardDependencyFixAutomationStatus,
    TaskBoardDependencyFixBinding, TaskBoardDependencyFixStopReason, TaskBoardDependencyIdentity,
    TaskBoardDependencyRouteAdmission, TaskBoardDependencyRouteRecord,
    TaskBoardDependencyRouteStore, TaskBoardDependencyTriageDisposition,
    TaskBoardDependencyTriageResult, TaskBoardDependencyTriageStep, TaskBoardDependencyUpdateClass,
    TaskBoardItem, TaskBoardStatus, TaskBoardWorkflowStatus,
};

use crate::daemon::db::AsyncDaemonDb;
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
        assert_eq!(run.started_at, snapshot.created_at);
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

        let recovered = controller
            .route_dependency_triage_and_start_fixer(
                &result,
                "acme/widgets",
                17,
                HEAD,
                &store,
                &binding,
            )
            .await
            .expect("recover fixer");
        assert!(!recovered.created);
        assert_eq!(recovered.run.expect("recovered run").run_id, run.run_id);
    })
    .await;
}

#[tokio::test]
async fn daemon_sink_persists_human_required_audit_on_the_bound_ticket() {
    let directory = tempfile::tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&directory.path().join("harness.db"))
        .await
        .expect("open db");
    let mut item = TaskBoardItem::new(
        "item-1".into(),
        "Dependency update".into(),
        "Original ticket context".into(),
        "2026-07-30T10:00:00Z".into(),
    );
    item.status = TaskBoardStatus::InProgress;
    item.workflow.execution_id = Some("execution-1".into());
    item.workflow.status = TaskBoardWorkflowStatus::Running;
    db.create_task_board_item(item)
        .await
        .expect("create ticket");
    let audit = human_required_audit();

    TaskBoardDependencyFixAuditSink::record(&db, &audit)
        .await
        .expect("persist audit");
    TaskBoardDependencyFixAuditSink::record(&db, &audit)
        .await
        .expect("idempotent replay");
    let item = db.task_board_item("item-1").await.expect("load ticket");

    assert_eq!(item.status, TaskBoardStatus::HumanRequired);
    assert_eq!(item.workflow.status, TaskBoardWorkflowStatus::Paused);
    assert_eq!(item.workflow.attempts, 1);
    assert_eq!(
        item.workflow.last_error.as_deref(),
        Some("failed checks: test")
    );
    assert!(item.body.contains("Status: human required"));
    assert!(
        item.body
            .contains("\"stop_reason\": \"attempt_limit_reached\"")
    );
    assert_eq!(
        item.body
            .matches("harness:dependency-fix-audit:start")
            .count(),
        1
    );
}

fn human_required_audit() -> TaskBoardDependencyFixAuditTrail {
    TaskBoardDependencyFixAuditTrail {
        schema_version: 1,
        route_id: "route-1".into(),
        board_item_id: "item-1".into(),
        workflow_execution_id: "execution-1".into(),
        attempt_count: 1,
        current_attempt: 1,
        status: TaskBoardDependencyFixAutomationStatus::HumanRequired,
        failure_reason: "failed checks: test".into(),
        first_started_at: "2026-07-30T10:00:00Z".into(),
        deadline_at: "2026-07-30T11:00:00Z".into(),
        updated_at: "2026-07-30T10:05:00Z".into(),
        attempts: vec![TaskBoardDependencyFixAttemptEvidence {
            attempt: 1,
            run_id: "route-1:fix".into(),
            exact_head_revision: HEAD.into(),
            started_at: "2026-07-30T10:00:00Z".into(),
            completed_at: "2026-07-30T10:05:00Z".into(),
            failure_reason: "failed checks: test".into(),
            failure_fingerprint: "c5cf8d8cdf3eb227db300810ae77914082f79798bd8e681e59f0c8cd881a1d8b"
                .into(),
        }],
        stop_reason: Some(TaskBoardDependencyFixStopReason::AttemptLimitReached),
    }
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
