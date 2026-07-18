use tempfile::TempDir;

use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{
    AgentMode, TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION, TaskBoardItem,
    TaskBoardOrchestratorSettings, TaskBoardPullRequestIdentity, TaskBoardReadOnlyRunContext,
    TaskBoardResolvedReviewer, TaskBoardReviewerProfile, TaskBoardWorkflowExecutionCasOutcome,
    TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind, TaskBoardWorkflowSnapshot,
};

use super::task_board_workflow_execution::{
    TaskBoardWorkflowExecutionCreateRequest, create_or_load_workflow_execution,
};

pub(super) const CREATED_AT: &str = "2026-07-15T10:00:00Z";

pub(super) struct TestDatabase {
    pub db: AsyncDaemonDb,
    pub path: std::path::PathBuf,
    _temp: TempDir,
}

impl TestDatabase {
    pub async fn open() -> Self {
        let temp = tempfile::tempdir().expect("tempdir");
        let path = temp.path().join("harness.db");
        let db = AsyncDaemonDb::connect(&path).await.expect("open database");
        Self {
            db,
            path,
            _temp: temp,
        }
    }
}

pub(super) fn reviewers(reviewer_count: u32, required_approvals: u32) -> TaskBoardResolvedReviewer {
    let profiles = [
        ("reviewer-amber", "risk-reviewer"),
        ("reviewer-indigo", "maintainability-reviewer"),
    ]
    .into_iter()
    .take(usize::try_from(reviewer_count).expect("reviewer count"))
    .map(|(id, persona)| TaskBoardReviewerProfile {
        id: id.into(),
        runtime: "runtime-shared".into(),
        persona: persona.into(),
        agent_mode: AgentMode::Evaluate,
        model: Some(format!("model-{id}")),
        effort: Some("high".into()),
    })
    .collect();
    TaskBoardResolvedReviewer {
        reviewer_count,
        required_approvals,
        max_revision_cycles: 3,
        profiles,
    }
}

pub(super) async fn seed_snapshot(
    db: &AsyncDaemonDb,
    item_id: &str,
    workflow_kind: TaskBoardWorkflowKind,
    reviewers: TaskBoardResolvedReviewer,
) -> TaskBoardWorkflowSnapshot {
    if db
        .task_board_configuration_revision()
        .await
        .expect("configuration revision")
        == 0
    {
        db.replace_task_board_orchestrator_settings(&TaskBoardOrchestratorSettings::default())
            .await
            .expect("seed settings");
    }
    let mut item = TaskBoardItem::new(
        item_id.into(),
        "Lantern workflow".into(),
        "Durable workflow fixture".into(),
        CREATED_AT.into(),
    );
    item.workflow_kind = workflow_kind;
    item.execution_repository = Some("example/compass".into());
    let mutation = db
        .create_task_board_item(item)
        .await
        .expect("seed task board item");
    TaskBoardWorkflowSnapshot {
        workflow_kind,
        execution_repository: Some("example/compass".into()),
        item_revision: mutation.item_revision,
        configuration_revision: db
            .task_board_configuration_revision()
            .await
            .expect("configuration revision"),
        policy_version: "policy-v1".into(),
        reviewer: reviewers,
        read_only_run_context: Some(TaskBoardReadOnlyRunContext {
            schema_version: TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
            session_id: format!("session-{item_id}"),
            title: "Lantern workflow".into(),
            body: "Durable workflow fixture".into(),
            tags: Vec::new(),
            worktree: "/tmp/read-only-worktree".into(),
        }),
        provider_revision: Some("provider-amber".into()),
    }
}

pub(super) async fn create_execution(
    db: &AsyncDaemonDb,
    item_id: &str,
    workflow_kind: TaskBoardWorkflowKind,
    reviewers: TaskBoardResolvedReviewer,
    head: Option<&str>,
) -> TaskBoardWorkflowExecutionRecord {
    let snapshot = seed_snapshot(db, item_id, workflow_kind, reviewers).await;
    let pull_request =
        (workflow_kind == TaskBoardWorkflowKind::PrReview).then(|| TaskBoardPullRequestIdentity {
            repository: "example/compass".into(),
            number: 17,
        });
    let outcome = create_or_load_workflow_execution(
        db,
        &TaskBoardWorkflowExecutionCreateRequest {
            execution_id: format!("execution-{item_id}"),
            item_id: item_id.into(),
            snapshot,
            pull_request,
            exact_head_revision: Some(head.unwrap_or("head-amber").to_owned()),
            created_at: CREATED_AT.into(),
        },
    )
    .await
    .expect("create workflow execution");
    outcome.execution
}

pub(super) fn outcome_record(
    outcome: TaskBoardWorkflowExecutionCasOutcome,
) -> TaskBoardWorkflowExecutionRecord {
    match outcome {
        TaskBoardWorkflowExecutionCasOutcome::Updated(record)
        | TaskBoardWorkflowExecutionCasOutcome::Unchanged(record) => record,
        TaskBoardWorkflowExecutionCasOutcome::Stale { mismatch, .. } => {
            panic!("unexpected stale workflow CAS: {mismatch:?}")
        }
    }
}
