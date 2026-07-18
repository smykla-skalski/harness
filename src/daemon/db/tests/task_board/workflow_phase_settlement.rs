use super::workflow_executions::{create_execution, workflow_database};
use super::*;
use crate::task_board::{
    TaskBoardExecutionState, TaskBoardOrchestratorSettings, TaskBoardTerminalOutcome,
    TaskBoardTerminalOutcomeKind, TaskBoardWorkflowCasMismatch, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionCasOutcome, TaskBoardWorkflowExecutionRecord,
    advance_task_board_workflow,
};

#[tokio::test]
async fn terminal_phase_cas_rejects_live_item_revision_drift() {
    let (db, _temp) = workflow_database().await;
    let cleanup = cleanup_execution(&db, "terminal-item-drift").await;
    db.update_task_board_item(&cleanup.item_id, |item| {
        item.title = "Changed before terminal settlement".into();
        Ok(true)
    })
    .await
    .expect("mutate cleanup item")
    .expect("item mutation");

    let outcome = settle_terminal(&db, &cleanup).await;

    assert_stale(outcome, TaskBoardWorkflowCasMismatch::ItemRevision);
}

#[tokio::test]
async fn terminal_phase_cas_rejects_live_settings_revision_drift() {
    let (db, _temp) = workflow_database().await;
    let cleanup = cleanup_execution(&db, "terminal-settings-drift").await;
    db.replace_task_board_orchestrator_settings(&TaskBoardOrchestratorSettings::default())
        .await
        .expect("advance settings revision");

    let outcome = settle_terminal(&db, &cleanup).await;

    assert_stale(outcome, TaskBoardWorkflowCasMismatch::ConfigurationRevision);
}

#[tokio::test]
async fn terminal_phase_cas_commits_when_live_revisions_match() {
    let (db, _temp) = workflow_database().await;
    let cleanup = cleanup_execution(&db, "terminal-current").await;

    let outcome = settle_terminal(&db, &cleanup).await;

    let TaskBoardWorkflowExecutionCasOutcome::Updated(terminal) = outcome else {
        panic!("expected terminal update, got {outcome:?}");
    };
    assert_eq!(
        terminal.transition.execution_state,
        TaskBoardExecutionState::Completed
    );
    assert!(terminal.completed_at.is_some());
}

async fn cleanup_execution(db: &AsyncDaemonDb, label: &str) -> TaskBoardWorkflowExecutionRecord {
    let mut current = create_execution(db, label, "2026-07-17T09:00:00Z").await;
    for updated_at in ["2026-07-17T09:01:00Z", "2026-07-17T09:02:00Z"] {
        let mut updated = current.clone();
        updated.transition = advance_task_board_workflow(
            &current.transition,
            current.transition.pull_request.as_ref(),
            current.transition.exact_head_revision.as_deref(),
        )
        .expect("advance workflow phase");
        updated.updated_at = updated_at.into();
        let outcome = db
            .compare_and_set_task_board_workflow_execution(
                &TaskBoardWorkflowExecutionCas::from(&current),
                &updated,
            )
            .await
            .expect("advance workflow execution");
        let TaskBoardWorkflowExecutionCasOutcome::Updated(next) = outcome else {
            panic!("expected phase update, got {outcome:?}");
        };
        current = next;
    }
    current
}

async fn settle_terminal(
    db: &AsyncDaemonDb,
    cleanup: &TaskBoardWorkflowExecutionRecord,
) -> TaskBoardWorkflowExecutionCasOutcome {
    let mut terminal = cleanup.clone();
    terminal.transition = advance_task_board_workflow(
        &cleanup.transition,
        cleanup.transition.pull_request.as_ref(),
        cleanup.transition.exact_head_revision.as_deref(),
    )
    .expect("advance cleanup to terminal");
    terminal.updated_at = "2026-07-17T09:03:00Z".into();
    terminal.completed_at = Some(terminal.updated_at.clone());
    terminal.artifacts.terminal_outcome = Some(TaskBoardTerminalOutcome {
        kind: TaskBoardTerminalOutcomeKind::Succeeded,
        summary: "workflow completed with durable evidence".into(),
        recorded_at: terminal.updated_at.clone(),
    });
    db.compare_and_set_task_board_workflow_execution(
        &TaskBoardWorkflowExecutionCas::from(cleanup),
        &terminal,
    )
    .await
    .expect("settle terminal workflow execution")
}

fn assert_stale(
    outcome: TaskBoardWorkflowExecutionCasOutcome,
    expected: TaskBoardWorkflowCasMismatch,
) {
    let TaskBoardWorkflowExecutionCasOutcome::Stale { mismatch, current } = outcome else {
        panic!("expected stale phase settlement, got {outcome:?}");
    };
    assert_eq!(mismatch, expected);
    assert!(current.is_some());
}
