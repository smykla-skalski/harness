use std::sync::Arc;

use crate::agents::turn::{AgentTurnRuntime, AgentTurnStatus};
use crate::daemon::db::AgentTurnRunStatus;

use super::tests::{FakeManager, open_store, request};
use super::{OpenRouterAgentTurnRuntime, OpenRouterRunCorrelation};

#[tokio::test]
async fn correlated_probe_rebinds_and_persists_provider_completion() {
    let (_dir, store) = open_store().await;
    let manager = Arc::new(FakeManager::default());
    let correlation = OpenRouterRunCorrelation {
        run_id: "remote-run-1".into(),
        board_item_id: Some("item-1".into()),
        workflow_execution_id: Some("execution-1".into()),
        task_id: None,
    };
    let starter = OpenRouterAgentTurnRuntime::with_manager_store_and_correlation(
        manager.clone(),
        "session-a".into(),
        Some("/tmp/project".into()),
        store.clone(),
        correlation.clone(),
    );
    starter
        .start(request())
        .await
        .expect("start correlated turn");
    let running = store
        .agent_turn_run(&correlation.run_id)
        .await
        .expect("load running turn")
        .expect("running turn");
    assert_eq!(running.status, AgentTurnRunStatus::Running);

    manager.complete(r#"{"summary":"Reviewed.","findings":[]}"#);
    drop(starter);
    let probe = OpenRouterAgentTurnRuntime::with_manager_store_and_correlation(
        manager,
        "session-a".into(),
        Some("/tmp/project".into()),
        store.clone(),
        correlation.clone(),
    );
    probe
        .reconcile_correlated_turn(&running)
        .await
        .expect("probe correlated turn");

    let completed = store
        .agent_turn_run(&correlation.run_id)
        .await
        .expect("load completed turn")
        .expect("completed turn");
    assert_eq!(completed.status, AgentTurnRunStatus::Completed);
    assert_eq!(
        completed.report.as_deref(),
        Some(r#"{"summary":"Reviewed.","findings":[]}"#)
    );
    assert_eq!(
        probe
            .status(
                &crate::agents::turn::AgentTurnId::new("openrouter-turn-1")
                    .expect("provider turn id")
            )
            .await
            .expect("completed provider status"),
        AgentTurnStatus::Completed
    );
}
