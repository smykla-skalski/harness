use super::workflow_executions::{NOW, create_execution, workflow_database};
use super::*;
use crate::task_board::{
    TaskBoardAttemptState, TaskBoardExecutionAttemptCas, TaskBoardExecutionAttemptRecord,
    TaskBoardExecutionState, TaskBoardOrchestratorSettings, TaskBoardWorkflowExecutionCas,
};

#[tokio::test]
async fn report_claim_rejects_live_item_revision_drift() {
    let (db, _temp) = workflow_database().await;
    let execution = seed_starting_report(&db, "claim-item-drift").await;
    db.update_task_board_item(&execution.item_id, |item| {
        item.title = "Changed before report claim".into();
        Ok(true)
    })
    .await
    .expect("mutate report item")
    .expect("item mutation");

    let error = claim_report(&db, &execution)
        .await
        .expect_err("fence item drift");

    assert!(error.to_string().contains("item revision changed"));
    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
    assert_claim_not_recorded(&db, &execution.execution_id).await;
}

#[tokio::test]
async fn report_claim_rejects_live_settings_revision_drift() {
    let (db, _temp) = workflow_database().await;
    let execution = seed_starting_report(&db, "claim-settings-drift").await;
    db.replace_task_board_orchestrator_settings(&TaskBoardOrchestratorSettings::default())
        .await
        .expect("advance settings revision");

    let error = claim_report(&db, &execution)
        .await
        .expect_err("fence settings drift");

    assert!(error.to_string().contains("configuration revision changed"));
    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
    assert_claim_not_recorded(&db, &execution.execution_id).await;
}

#[tokio::test]
async fn side_effect_claim_updates_parent_and_child_and_fences_terminal_writer() {
    let (db, _temp) = workflow_database().await;
    let execution = seed_starting_report(&db, "claim-terminal-fence").await;
    let claimed = claim_report(&db, &execution)
        .await
        .expect("claim report")
        .expect("claim winner");
    assert_eq!(claimed.state, TaskBoardAttemptState::Running);
    let durable = db
        .task_board_workflow_execution(&execution.execution_id)
        .await
        .expect("load claimed execution")
        .expect("claimed execution");
    assert_eq!(
        durable.transition.execution_state,
        TaskBoardExecutionState::Starting
    );
    assert_eq!(durable.attempts[0].state, TaskBoardAttemptState::Running);
    assert_eq!(
        durable
            .ownership
            .resources
            .get("execution_target")
            .map(String::as_str),
        Some("local")
    );
    assert_eq!(
        durable
            .ownership
            .resources
            .get("execution_target_action_key")
            .map(String::as_str),
        Some("review:reviewer")
    );
    assert_eq!(
        durable
            .ownership
            .resources
            .get("execution_target_attempt")
            .map(String::as_str),
        Some("1")
    );

    let mut stopped = execution.clone();
    stopped.transition.execution_state = TaskBoardExecutionState::HumanRequired;
    stopped.blocked_reason = Some("concurrent stop".into());
    stopped.updated_at = "2026-07-17T10:00:02Z".into();
    let error = db
        .compare_and_set_task_board_workflow_execution(
            &TaskBoardWorkflowExecutionCas::from(&execution),
            &stopped,
        )
        .await
        .expect_err("claimed side effect must fence terminal writer");
    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
}

async fn seed_starting_report(
    db: &AsyncDaemonDb,
    label: &str,
) -> crate::task_board::TaskBoardWorkflowExecutionRecord {
    let execution = create_execution(db, label, "2026-07-17T09:00:00Z").await;
    db.create_task_board_execution_attempt(&TaskBoardExecutionAttemptRecord {
        execution_id: execution.execution_id.clone(),
        action_key: "review:reviewer".into(),
        attempt: 1,
        idempotency_key: format!("codex-{}-review-1", execution.execution_id),
        state: TaskBoardAttemptState::Preparing,
        failure_class: None,
        available_at: None,
        error: None,
        artifact: None,
        started_at: NOW.into(),
        updated_at: NOW.into(),
        completed_at: None,
    })
    .await
    .expect("seed preparing report attempt");
    // A report side effect is only claimable once the local target is selected,
    // so drive the real Preparing -> Starting selection instead of faking the state.
    let prepared = db
        .task_board_workflow_execution(&execution.execution_id)
        .await
        .expect("load preparing report execution")
        .expect("preparing report execution");
    assert!(
        db.select_task_board_local_execution_target(
            &TaskBoardWorkflowExecutionCas::from(&prepared),
            &TaskBoardExecutionAttemptCas::from(&prepared.attempts[0]),
            NOW,
        )
        .await
        .expect("select local report target"),
        "fixture must select the local target",
    );
    db.task_board_workflow_execution(&execution.execution_id)
        .await
        .expect("load Starting report execution")
        .expect("Starting report execution")
}

async fn claim_report(
    db: &AsyncDaemonDb,
    execution: &crate::task_board::TaskBoardWorkflowExecutionRecord,
) -> Result<Option<TaskBoardExecutionAttemptRecord>, crate::errors::CliError> {
    let current = &execution.attempts[0];
    let mut claimed = current.clone();
    claimed.state = TaskBoardAttemptState::Running;
    claimed.updated_at = "2026-07-17T10:00:01Z".into();
    db.claim_task_board_workflow_side_effect(
        &TaskBoardWorkflowExecutionCas::from(execution),
        &TaskBoardExecutionAttemptCas::from(current),
        &claimed,
        "2026-07-17T10:00:01Z",
    )
    .await
}

async fn assert_claim_not_recorded(db: &AsyncDaemonDb, execution_id: &str) {
    let durable = db
        .task_board_workflow_execution(execution_id)
        .await
        .expect("load unclaimed execution")
        .expect("unclaimed execution");
    assert_eq!(
        durable.transition.execution_state,
        TaskBoardExecutionState::Starting
    );
    assert_eq!(durable.attempts[0].state, TaskBoardAttemptState::Starting);
}
