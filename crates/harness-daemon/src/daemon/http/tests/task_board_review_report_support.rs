use crate::daemon::db::task_board::prelude::*;
use crate::daemon::db_handle::AsyncDaemonDbHandle;
use crate::task_board::{
    AgentMode, TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION, TaskBoardAttemptState,
    TaskBoardExecutionAttemptCas, TaskBoardExecutionAttemptRecord, TaskBoardExecutionState,
    TaskBoardReadOnlyRunContext, TaskBoardResolvedReviewer, TaskBoardReviewerProfile,
    TaskBoardWorkflowExecutionArtifacts, TaskBoardWorkflowExecutionRecord, TaskBoardWorkflowKind,
    TaskBoardWorkflowSnapshot, TaskBoardWorkflowStatus, start_task_board_workflow,
};

pub(super) async fn seed_running_execution(
    db: &AsyncDaemonDbHandle,
    item_id: &str,
) -> TaskBoardWorkflowExecutionRecord {
    let execution_id = format!("execution-{item_id}");
    let mutation = db
        .update_task_board_item_with_triage(item_id, |item| {
            item.workflow.execution_id = Some(execution_id.clone());
            item.workflow.status = TaskBoardWorkflowStatus::Running;
            Ok(true)
        })
        .await
        .expect("bind workflow execution")
        .expect("item mutation");
    let reviewers = resolved_reviewers();
    let mut transition = start_task_board_workflow(
        TaskBoardWorkflowKind::Review,
        None,
        Some("0123456789abcdef0123456789abcdef01234567"),
    )
    .expect("start review workflow");
    transition.execution_state = TaskBoardExecutionState::Running;
    let execution = TaskBoardWorkflowExecutionRecord {
        execution_id,
        item_id: item_id.into(),
        snapshot: TaskBoardWorkflowSnapshot {
            workflow_kind: TaskBoardWorkflowKind::Review,
            execution_repository: Some("smykla-skalski/harness".into()),
            item_revision: mutation.item_revision,
            configuration_revision: db
                .task_board_configuration_revision()
                .await
                .expect("configuration revision"),
            policy_version: "policy-v1".into(),
            reviewer: reviewers.clone(),
            read_only_run_context: Some(TaskBoardReadOnlyRunContext {
                schema_version: TASK_BOARD_READ_ONLY_RUN_CONTEXT_VERSION,
                session_id: format!("session-{item_id}"),
                title: "Transport parity item".into(),
                body: "Shared task-board body".into(),
                tags: vec!["parity".into()],
                worktree: "/tmp/transport-parity-worktree".into(),
            }),
            provider_revision: None,
        },
        resolved_reviewers: reviewers,
        transition,
        artifacts: TaskBoardWorkflowExecutionArtifacts::default(),
        ownership: Default::default(),
        available_at: None,
        blocked_reason: None,
        created_at: "2026-07-29T18:00:00Z".into(),
        updated_at: "2026-07-29T18:00:00Z".into(),
        completed_at: None,
        attempts: Vec::new(),
    };
    let execution = db
        .create_or_load_task_board_workflow_execution(&execution)
        .await
        .expect("create workflow execution")
        .execution;
    let reviewer = &execution.resolved_reviewers.profiles[1];
    db.create_task_board_execution_attempt(&TaskBoardExecutionAttemptRecord {
        execution_id: execution.execution_id.clone(),
        action_key: format!("review:{}", reviewer.id),
        attempt: 1,
        idempotency_key: format!("{}-review-1", execution.execution_id),
        state: TaskBoardAttemptState::Running,
        failure_class: None,
        available_at: None,
        error: None,
        artifact: None,
        started_at: "2026-07-29T18:00:05Z".into(),
        updated_at: "2026-07-29T18:00:05Z".into(),
        completed_at: None,
    })
    .await
    .expect("create active review attempt");
    db.task_board_workflow_execution(&execution.execution_id)
        .await
        .expect("reload workflow execution")
        .expect("workflow execution")
}

pub(super) async fn settle_active_review_attempt(
    db: &AsyncDaemonDbHandle,
    execution: &TaskBoardWorkflowExecutionRecord,
) {
    let attempt = execution.attempts.first().expect("active review attempt");
    let mut settled = attempt.clone();
    settled.state = TaskBoardAttemptState::Cancelled;
    settled.updated_at = "2026-07-29T18:00:06Z".into();
    settled.completed_at = Some("2026-07-29T18:00:06Z".into());
    db.compare_and_set_task_board_execution_attempt(
        &TaskBoardExecutionAttemptCas::from(attempt),
        &settled,
    )
    .await
    .expect("settle active review attempt");
}

fn resolved_reviewers() -> TaskBoardResolvedReviewer {
    TaskBoardResolvedReviewer {
        reviewer_count: 2,
        required_approvals: 1,
        max_revision_cycles: 1,
        profiles: vec![
            TaskBoardReviewerProfile {
                id: "reviewer-configured-first".into(),
                runtime: "codex".into(),
                persona: "code-reviewer".into(),
                agent_mode: AgentMode::Evaluate,
                model: Some("gpt-5.3-codex-spark".into()),
                effort: None,
            },
            TaskBoardReviewerProfile {
                id: "reviewer-active".into(),
                runtime: "openrouter".into(),
                persona: "risk-reviewer".into(),
                agent_mode: AgentMode::Evaluate,
                model: Some("deepseek/deepseek-v4-flash".into()),
                effort: None,
            },
        ],
    }
}
