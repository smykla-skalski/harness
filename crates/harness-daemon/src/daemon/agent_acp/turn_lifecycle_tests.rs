use std::future::Future;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};

use crate::agents::turn::{
    AgentTurnFailure, AgentTurnFailureCategory, AgentTurnFailureStage, AgentTurnPullRequest,
    AgentTurnPullRequestContext, AgentTurnReadOnlyContent, AgentTurnRequest, AgentTurnRuntime,
    AgentTurnStatus,
};
use crate::daemon::agent_acp::{
    AcpAgentInspectResponse, AcpAgentInspectSnapshot, AcpAgentSessionState, AcpAgentSnapshot,
    AcpAgentStartRequest, AcpAgentTurnResult, AcpSessionConfigOptionState,
};
use crate::daemon::db::{AgentTurnRunStatus, AsyncDaemonDb};
use crate::session::types::AgentStatus;
use harness_kernel::errors::CliError;

use super::{OpenRouterAgentTurnRuntime, OpenRouterTurnManager};

const HEAD: &str = "0123456789abcdef0123456789abcdef01234567";
const MODEL: &str = "deepseek/deepseek-v4-flash";

#[derive(Default)]
struct FakeManager {
    request: Mutex<Option<AcpAgentStartRequest>>,
    state: Mutex<AcpAgentSessionState>,
    stopped: Mutex<bool>,
    stop_probe: Mutex<Option<Box<dyn FnOnce() + Send>>>,
    stop_fails: Mutex<bool>,
}

impl FakeManager {
    fn complete(&self, report: &str) {
        let mut state = self.state.lock().expect("state lock");
        state.config_options = vec![AcpSessionConfigOptionState {
            id: "model".into(),
            name: "Model".into(),
            category: Some("model".into()),
            current_value: MODEL.into(),
        }];
        state.last_turn_result = Some(AcpAgentTurnResult {
            report: report.into(),
            stop_reason: "end_turn".into(),
        });
    }

    fn fail(&self, detail: &str) {
        let mut state = self.state.lock().expect("state lock");
        state.last_turn_failure = Some(AgentTurnFailure::new(
            AgentTurnFailureCategory::ProviderRejected,
            AgentTurnFailureStage::Execution,
            detail,
        ));
    }
}

impl OpenRouterTurnManager for FakeManager {
    fn start(
        &self,
        _session_id: &str,
        request: &AcpAgentStartRequest,
    ) -> Result<AcpAgentSnapshot, CliError> {
        self.request
            .lock()
            .expect("request lock")
            .replace(request.clone());
        Ok(snapshot())
    }

    fn inspect(&self, _session_id: &str) -> Result<AcpAgentInspectResponse, CliError> {
        Ok(AcpAgentInspectResponse {
            agents: vec![inspect_snapshot(
                self.state.lock().expect("state lock").clone(),
            )],
            daemon_perceived_now: None,
            available: true,
            issue_message: None,
        })
    }

    fn stop(&self, _acp_id: &str) -> Result<AcpAgentSnapshot, CliError> {
        if let Some(probe) = self.stop_probe.lock().expect("stop probe lock").take() {
            probe();
        }
        if *self.stop_fails.lock().expect("stop failure lock") {
            return Err(harness_kernel::errors::CliErrorKind::workflow_io(
                "simulated stop failure",
            )
            .into());
        }
        *self.stopped.lock().expect("stopped lock") = true;
        Ok(snapshot())
    }
}

#[tokio::test]
async fn openrouter_turn_keeps_model_report_and_frozen_source_revision() {
    let manager = Arc::new(FakeManager::default());
    let runtime =
        OpenRouterAgentTurnRuntime::with_manager(manager.clone(), "session-a".into(), None);
    let id = runtime
        .start(request())
        .await
        .expect("start OpenRouter turn");

    assert_eq!(
        runtime.status(&id).await.expect("running status"),
        AgentTurnStatus::Running
    );
    let started = manager
        .request
        .lock()
        .expect("request lock")
        .clone()
        .expect("captured start");
    assert_eq!(started.agent, "openrouter");
    assert_eq!(started.model.as_deref(), Some(MODEL));
    assert!(started.resume_disabled);
    assert!(started.prompt.as_deref().is_some_and(|prompt| {
        prompt.contains(HEAD)
            && prompt.contains("immutable, read-only snapshot")
            && prompt.contains("immutable review")
            && prompt.contains("diff --git a/src/lib.rs b/src/lib.rs")
    }));

    manager.complete(r#"{"summary":"Reviewed.","findings":[]}"#);
    assert_eq!(
        runtime.status(&id).await.expect("completed status"),
        AgentTurnStatus::Completed
    );
    let result = runtime
        .result(&id)
        .await
        .expect("result")
        .expect("completed result");
    assert_eq!(result.requested_model.as_deref(), Some(MODEL));
    assert_eq!(result.effective_model.as_deref(), Some(MODEL));
    assert_eq!(result.source_revision.as_deref(), Some(HEAD));
    assert_eq!(result.stop_reason, "end_turn");
}

#[tokio::test]
async fn cancellation_is_idempotent_and_terminal() {
    let manager = Arc::new(FakeManager::default());
    let runtime =
        OpenRouterAgentTurnRuntime::with_manager(manager.clone(), "session-a".into(), None);
    let id = runtime.start(request()).await.expect("start");

    assert_eq!(
        runtime.cancel(&id).await.expect("cancel"),
        AgentTurnStatus::Cancelled
    );
    assert_eq!(
        runtime.cancel(&id).await.expect("cancel again"),
        AgentTurnStatus::Cancelled
    );
    assert!(*manager.stopped.lock().expect("stopped lock"));
    assert!(runtime.result(&id).await.expect("result").is_none());
    assert!(runtime.failure(&id).await.expect("failure").is_some());
}

#[tokio::test]
async fn cancellation_is_terminal_before_the_agent_stops() {
    let manager = Arc::new(FakeManager::default());
    let runtime =
        OpenRouterAgentTurnRuntime::with_manager(manager.clone(), "session-a".into(), None);
    let id = runtime.start(request()).await.expect("start");
    let runtime_during_stop = runtime.clone();
    let id_during_stop = id.clone();
    manager
        .stop_probe
        .lock()
        .expect("stop probe lock")
        .replace(Box::new(move || {
            assert_eq!(
                ready(runtime_during_stop.status(&id_during_stop)).expect("status during stop"),
                AgentTurnStatus::Cancelled
            );
        }));

    assert_eq!(
        runtime.cancel(&id).await.expect("cancel"),
        AgentTurnStatus::Cancelled
    );
}

#[tokio::test]
async fn failed_stop_rolls_back_the_terminal_marker() {
    let manager = Arc::new(FakeManager::default());
    let runtime =
        OpenRouterAgentTurnRuntime::with_manager(manager.clone(), "session-a".into(), None);
    let id = runtime.start(request()).await.expect("start");
    *manager.stop_fails.lock().expect("stop failure lock") = true;

    runtime.cancel(&id).await.expect_err("stop must fail");
    assert_eq!(
        runtime.status(&id).await.expect("running after rollback"),
        AgentTurnStatus::Running
    );
}

#[tokio::test]
async fn unknown_turn_fails_without_reaching_the_manager() {
    let runtime = OpenRouterAgentTurnRuntime::with_manager(
        Arc::new(FakeManager::default()),
        "session-a".into(),
        None,
    );
    let id = crate::agents::turn::AgentTurnId::new("missing").expect("id");
    let error = runtime.status(&id).await.expect_err("unknown turn");
    assert_eq!(error.code(), "KSRCLI090");
}

async fn open_store() -> (tempfile::TempDir, Arc<AsyncDaemonDb>) {
    let dir = tempfile::tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open async db");
    (dir, Arc::new(db))
}

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

    // Polling status must not touch the durable row: it stays Running until the
    // caller retrieves the result.
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
    runtime.failure(&id).await.expect("failure").expect("failure present");

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
    // A cancellation is not a failure: `error` stays NULL and the reason lives
    // in `stop_reason`, matching the Codex path.
    assert!(stored.error.is_none());
    assert_eq!(stored.stop_reason.as_deref(), Some("cancelled"));
}

fn request() -> AgentTurnRequest {
    let pull_request = AgentTurnPullRequest {
        repository: "smykla-skalski/harness".into(),
        number: 898,
        head_revision: HEAD.into(),
    };
    AgentTurnRequest {
        prompt: "Return the report-only review JSON.".into(),
        requested_model: Some(MODEL.into()),
        pull_request: Some(AgentTurnPullRequestContext {
            pull_request: pull_request.clone(),
            content: AgentTurnReadOnlyContent {
                pull_request,
                body: "title: immutable review\ndiff --git a/src/lib.rs b/src/lib.rs".into(),
            },
        }),
    }
}

fn snapshot() -> AcpAgentSnapshot {
    AcpAgentSnapshot {
        acp_id: "openrouter-turn-1".into(),
        session_id: "session-a".into(),
        agent_id: "agent-a".into(),
        display_name: "OpenRouter".into(),
        status: AgentStatus::Active,
        pid: 1,
        pgid: 1,
        project_dir: "/tmp/project".into(),
        process_key: "openrouter".into(),
        pending_permissions: 0,
        permission_queue_depth: 0,
        pending_permission_batches: Vec::new(),
        permission_mode: "deny".into(),
        permission_log_path: None,
        terminal_count: 0,
        created_at: "2026-07-29T00:00:00Z".into(),
        updated_at: "2026-07-29T00:00:00Z".into(),
    }
}

fn inspect_snapshot(state: AcpAgentSessionState) -> AcpAgentInspectSnapshot {
    AcpAgentInspectSnapshot {
        acp_id: "openrouter-turn-1".into(),
        session_id: "session-a".into(),
        agent_id: "agent-a".into(),
        display_name: "OpenRouter".into(),
        pid: 1,
        pgid: 1,
        process_key: "openrouter".into(),
        uptime_ms: 1,
        last_update_at: "2026-07-29T00:00:00Z".into(),
        last_client_call_at: None,
        watchdog_state: "healthy".into(),
        permission_mode: "deny".into(),
        permission_log_path: None,
        pending_permissions: 0,
        permission_queue_depth: 0,
        terminal_count: usize::from(state.last_turn_result.is_some()),
        prompt_deadline_remaining_ms: 0,
        handshake: None,
        session_state: Some(state),
    }
}

fn ready<T>(future: impl Future<Output = T>) -> T {
    let waker = Waker::noop();
    let mut context = Context::from_waker(waker);
    let mut future = Box::pin(future);
    match future.as_mut().poll(&mut context) {
        Poll::Ready(value) => value,
        Poll::Pending => panic!("OpenRouter lifecycle future unexpectedly pending"),
    }
}
