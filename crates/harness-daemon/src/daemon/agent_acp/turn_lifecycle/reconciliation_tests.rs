use std::sync::Arc;

use crate::agents::turn::{AgentTurnRuntime, AgentTurnStatus};
use crate::daemon::db::AgentTurnRunStatus;

use super::tests::{FakeManager, open_store, request};
use super::{OpenRouterAgentTurnRuntime, OpenRouterRunCorrelation};

const AUTHENTICATION_DETAIL: &str = "OpenRouter rejected its credential: HTTP 401 unauthorized";

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

#[tokio::test]
async fn correlated_probe_settles_turn_evicted_by_daemon_restart() {
    let (_dir, store) = open_store().await;
    let correlation = OpenRouterRunCorrelation {
        run_id: "remote-run-restart".into(),
        board_item_id: Some("item-restart".into()),
        workflow_execution_id: Some("execution-restart".into()),
        task_id: None,
    };
    let manager = Arc::new(FakeManager::default());
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

    manager.forget();
    let restarted = OpenRouterAgentTurnRuntime::with_manager_store_and_correlation(
        manager,
        "session-a".into(),
        Some("/tmp/project".into()),
        store.clone(),
        correlation.clone(),
    );
    restarted
        .reconcile_correlated_turn(&running)
        .await
        .expect("settle evicted turn");

    let failed = store
        .agent_turn_run(&correlation.run_id)
        .await
        .expect("load failed turn")
        .expect("failed turn");
    assert_eq!(failed.status, AgentTurnRunStatus::Failed);
    assert_eq!(
        failed.error.as_deref(),
        Some("provider turn is no longer attached to this daemon")
    );
}

#[tokio::test]
async fn correlated_probe_keeps_the_provider_failure_observed_before_the_turn_detached() {
    let (_dir, store) = open_store().await;
    let correlation = OpenRouterRunCorrelation {
        run_id: "remote-run-rejected".into(),
        board_item_id: Some("item-rejected".into()),
        workflow_execution_id: Some("execution-rejected".into()),
        task_id: None,
    };
    let manager = Arc::new(FakeManager::default());
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

    manager.fail_with_partial_output(AUTHENTICATION_DETAIL, "partial review output");
    manager.evict();
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
        .expect("settle detached turn");

    let failed = store
        .agent_turn_run(&correlation.run_id)
        .await
        .expect("load failed turn")
        .expect("failed turn");
    assert_eq!(failed.status, AgentTurnRunStatus::Failed);
    assert_eq!(failed.error.as_deref(), Some(AUTHENTICATION_DETAIL));
    assert_eq!(failed.report.as_deref(), Some("partial review output"));
}

#[tokio::test]
async fn correlated_probe_keeps_a_completed_report_observed_before_the_turn_detached() {
    let (_dir, store) = open_store().await;
    let correlation = OpenRouterRunCorrelation {
        run_id: "remote-run-completed-detached".into(),
        board_item_id: Some("item-completed-detached".into()),
        workflow_execution_id: Some("execution-completed-detached".into()),
        task_id: None,
    };
    let manager = Arc::new(FakeManager::default());
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

    manager.complete(r#"{"summary":"Reviewed.","findings":[]}"#);
    manager.evict();
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
        .expect("settle detached turn");

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
    assert_eq!(completed.actual_model.as_deref(), Some(super::tests::MODEL));
}

#[tokio::test]
async fn correlated_probe_preserves_turn_while_manager_is_unavailable() {
    let (_dir, store) = open_store().await;
    let correlation = OpenRouterRunCorrelation {
        run_id: "remote-run-unavailable".into(),
        board_item_id: Some("item-unavailable".into()),
        workflow_execution_id: Some("execution-unavailable".into()),
        task_id: None,
    };
    let manager = Arc::new(FakeManager::default());
    let runtime = OpenRouterAgentTurnRuntime::with_manager_store_and_correlation(
        manager.clone(),
        "session-a".into(),
        Some("/tmp/project".into()),
        store.clone(),
        correlation.clone(),
    );
    runtime
        .start(request())
        .await
        .expect("start correlated turn");
    let running = store
        .agent_turn_run(&correlation.run_id)
        .await
        .expect("load running turn")
        .expect("running turn");

    manager.make_unavailable();
    runtime
        .reconcile_correlated_turn(&running)
        .await
        .expect("defer unavailable inspection");

    assert_eq!(
        store
            .agent_turn_run(&correlation.run_id)
            .await
            .expect("reload running turn")
            .expect("running turn")
            .status,
        AgentTurnRunStatus::Running
    );
}
