use std::sync::Arc;

use crate::agents::turn::{AgentTurnRuntime, AgentTurnStatus};
use crate::daemon::db::AgentTurnRunStatus;

use super::tests::{FakeManager, HEAD, MODEL, open_store, request};
use super::{OpenRouterAgentTurnRuntime, OpenRouterRunCorrelation};

#[tokio::test]
async fn start_records_a_durable_running_run() {
    let (_dir, store) = open_store().await;
    let manager = Arc::new(FakeManager::default());
    let runtime = OpenRouterAgentTurnRuntime::with_manager_and_store(
        manager.clone(),
        "session-a".into(),
        None,
        store.clone(),
    );
    let id = runtime.start(request()).await.expect("start");

    let stored = store
        .agent_turn_run(id.as_str())
        .await
        .expect("load")
        .expect("run recorded at start");
    assert_eq!(stored.status, AgentTurnRunStatus::Running);
    assert_eq!(stored.requested_runtime, "openrouter");
    assert_eq!(stored.actual_runtime.as_deref(), Some("openrouter"));
    assert_eq!(stored.requested_model.as_deref(), Some(MODEL));
    assert_eq!(stored.source_revision.as_deref(), Some(HEAD));
}

#[tokio::test]
async fn completion_records_terminal_outcome_and_actual_model() {
    let (_dir, store) = open_store().await;
    let manager = Arc::new(FakeManager::default());
    let runtime = OpenRouterAgentTurnRuntime::with_manager_and_store(
        manager.clone(),
        "session-a".into(),
        None,
        store.clone(),
    );
    let id = runtime.start(request()).await.expect("start");
    manager.complete(r#"{"summary":"Reviewed.","findings":[]}"#);
    runtime
        .result(&id)
        .await
        .expect("result")
        .expect("completed result");

    let stored = store
        .agent_turn_run(id.as_str())
        .await
        .expect("load")
        .expect("run exists");
    assert_eq!(stored.status, AgentTurnRunStatus::Completed);
    assert_eq!(stored.requested_model.as_deref(), Some(MODEL));
    assert_eq!(stored.actual_model.as_deref(), Some(MODEL));
    assert_eq!(
        stored.report.as_deref(),
        Some(r#"{"summary":"Reviewed.","findings":[]}"#)
    );
}

#[tokio::test]
async fn status_polling_leaves_terminal_persistence_to_result() {
    let (_dir, store) = open_store().await;
    let manager = Arc::new(FakeManager::default());
    let runtime = OpenRouterAgentTurnRuntime::with_manager_and_store(
        manager.clone(),
        "session-a".into(),
        None,
        store.clone(),
    );
    let id = runtime.start(request()).await.expect("start");
    manager.complete(r#"{"summary":"Reviewed."}"#);

    for _ in 0..3 {
        assert_eq!(
            runtime.status(&id).await.expect("status"),
            AgentTurnStatus::Completed
        );
    }
    let mid = store
        .agent_turn_run(id.as_str())
        .await
        .expect("load")
        .expect("run exists");
    assert_eq!(mid.status, AgentTurnRunStatus::Running);

    runtime.result(&id).await.expect("result").expect("result");
    let after = store
        .agent_turn_run(id.as_str())
        .await
        .expect("load")
        .expect("run exists");
    assert_eq!(after.status, AgentTurnRunStatus::Completed);
}

#[tokio::test]
async fn failure_records_a_terminal_failure() {
    let (_dir, store) = open_store().await;
    let manager = Arc::new(FakeManager::default());
    let runtime = OpenRouterAgentTurnRuntime::with_manager_and_store(
        manager.clone(),
        "session-a".into(),
        None,
        store.clone(),
    );
    let id = runtime.start(request()).await.expect("start");
    manager.fail("provider rejected the request");

    assert_eq!(
        runtime.status(&id).await.expect("status"),
        AgentTurnStatus::Failed
    );
    runtime
        .failure(&id)
        .await
        .expect("failure")
        .expect("failure present");

    let stored = store
        .agent_turn_run(id.as_str())
        .await
        .expect("load")
        .expect("run exists");
    assert_eq!(stored.status, AgentTurnRunStatus::Failed);
    assert_eq!(
        stored.error.as_deref(),
        Some("provider rejected the request")
    );
    assert!(stored.stop_reason.is_none());
    assert_eq!(stored.actual_model.as_deref(), Some(MODEL));
}

#[tokio::test]
async fn cancellation_records_a_terminal_run() {
    let (_dir, store) = open_store().await;
    let manager = Arc::new(FakeManager::default());
    let runtime = OpenRouterAgentTurnRuntime::with_manager_and_store(
        manager.clone(),
        "session-a".into(),
        None,
        store.clone(),
    );
    let id = runtime.start(request()).await.expect("start");
    runtime.cancel(&id).await.expect("cancel");

    let stored = store
        .agent_turn_run(id.as_str())
        .await
        .expect("load")
        .expect("run exists");
    assert_eq!(stored.status, AgentTurnRunStatus::Cancelled);
    assert!(stored.error.is_none());
    assert_eq!(stored.stop_reason.as_deref(), Some("cancelled"));
}

#[tokio::test]
async fn correlation_keys_the_durable_run_to_the_caller_id() {
    let (_dir, store) = open_store().await;
    let manager = Arc::new(FakeManager::default());
    let runtime = OpenRouterAgentTurnRuntime::with_manager_store_and_correlation(
        manager.clone(),
        "session-a".into(),
        None,
        store.clone(),
        OpenRouterRunCorrelation {
            run_id: "codex-workflow-attempt-9".into(),
            board_item_id: Some("item-9".into()),
            workflow_execution_id: Some("execution-9".into()),
            task_id: None,
        },
    );
    let id = runtime.start(request()).await.expect("start");
    assert_ne!(id.as_str(), "codex-workflow-attempt-9");
    assert!(
        store
            .agent_turn_run(id.as_str())
            .await
            .expect("load by acp id")
            .is_none()
    );

    let stored = store
        .agent_turn_run("codex-workflow-attempt-9")
        .await
        .expect("load by correlation id")
        .expect("run recorded under the correlation id");
    assert_eq!(stored.status, AgentTurnRunStatus::Running);
    assert_eq!(stored.board_item_id.as_deref(), Some("item-9"));
    assert_eq!(stored.workflow_execution_id.as_deref(), Some("execution-9"));

    manager.complete(r#"{"summary":"Reviewed.","findings":[]}"#);
    runtime.result(&id).await.expect("result").expect("result");
    let settled = store
        .agent_turn_run("codex-workflow-attempt-9")
        .await
        .expect("load settled")
        .expect("settled run");
    assert_eq!(settled.status, AgentTurnRunStatus::Completed);
}
