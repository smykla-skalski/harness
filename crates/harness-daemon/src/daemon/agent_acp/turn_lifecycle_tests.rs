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
use crate::daemon::db::AsyncDaemonDb;
use crate::session::types::AgentStatus;
use harness_kernel::errors::CliError;

use super::{OpenRouterAgentTurnRuntime, OpenRouterTurnManager};

pub(super) const HEAD: &str = "0123456789abcdef0123456789abcdef01234567";
pub(super) const MODEL: &str = "deepseek/deepseek-v4-flash";

pub(super) struct FakeManager {
    request: Mutex<Option<AcpAgentStartRequest>>,
    state: Mutex<AcpAgentSessionState>,
    runtime_session_id: Mutex<Option<String>>,
    attached: Mutex<bool>,
    /// Whether the detached session is still in the registry. A live daemon
    /// keeps it, so its last state stays readable; a restart does not.
    session_retained: Mutex<bool>,
    available: Mutex<bool>,
    stopped: Mutex<bool>,
    stop_probe: Mutex<Option<Box<dyn FnOnce() + Send>>>,
    stop_fails: Mutex<bool>,
}

impl Default for FakeManager {
    fn default() -> Self {
        Self {
            request: Mutex::default(),
            state: Mutex::default(),
            runtime_session_id: Mutex::new(Some("openrouter-session-1".into())),
            attached: Mutex::new(true),
            session_retained: Mutex::new(true),
            available: Mutex::new(true),
            stopped: Mutex::default(),
            stop_probe: Mutex::default(),
            stop_fails: Mutex::default(),
        }
    }
}

impl FakeManager {
    pub(super) fn complete(&self, report: &str) {
        let mut state = self.state.lock().expect("state lock");
        state.config_options = observed_model_options();
        state.last_turn_result = Some(AcpAgentTurnResult {
            report: report.into(),
            stop_reason: "end_turn".into(),
        });
    }

    pub(super) fn fail(&self, detail: &str) {
        let mut state = self.state.lock().expect("state lock");
        state.config_options = observed_model_options();
        state.last_turn_failure = Some(AgentTurnFailure::new(
            AgentTurnFailureCategory::ProviderRejected,
            AgentTurnFailureStage::Execution,
            detail,
        ));
    }

    pub(super) fn fail_with_partial_output(&self, detail: &str, partial_output: &str) {
        self.fail(detail);
        self.state
            .lock()
            .expect("state lock")
            .last_turn_partial_output = Some(partial_output.into());
    }

    /// Detach the turn the way a finished or dead agent process does: `inspect`
    /// stops reporting it while the session it left behind keeps its last state.
    pub(super) fn evict(&self) {
        *self.attached.lock().expect("attached lock") = false;
    }

    /// Drop the session with the turn, so nothing remains to read after the
    /// detach. This is what a daemon restart leaves behind.
    pub(super) fn forget(&self) {
        self.evict();
        *self.state.lock().expect("state lock") = AcpAgentSessionState::default();
        *self.session_retained.lock().expect("retained lock") = false;
    }

    pub(super) fn make_unavailable(&self) {
        *self.available.lock().expect("available lock") = false;
        self.evict();
    }
}

fn observed_model_options() -> Vec<AcpSessionConfigOptionState> {
    vec![
        AcpSessionConfigOptionState {
            id: "model".into(),
            name: "Model".into(),
            category: Some("model".into()),
            current_value: "requested-selection-is-not-provenance".into(),
        },
        AcpSessionConfigOptionState {
            id: super::super::PROVIDER_EFFECTIVE_MODEL_CONFIG_OPTION_ID.into(),
            name: "Provider effective model".into(),
            category: Some("model".into()),
            current_value: MODEL.into(),
        },
    ]
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
        let agents = if *self.attached.lock().expect("attached lock") {
            vec![inspect_snapshot(
                self.state.lock().expect("state lock").clone(),
            )]
        } else {
            Vec::new()
        };
        let available = *self.available.lock().expect("available lock");
        Ok(AcpAgentInspectResponse {
            agents,
            daemon_perceived_now: None,
            available,
            issue_message: (!available).then(|| "bridge unavailable".into()),
        })
    }

    fn detached_turn_state(
        &self,
        _session_id: &str,
        _acp_id: &str,
    ) -> Result<Option<AcpAgentSessionState>, CliError> {
        if !*self.session_retained.lock().expect("retained lock") {
            return Ok(None);
        }
        Ok(Some(self.state.lock().expect("state lock").clone()))
    }

    fn runtime_session_id(
        &self,
        _session_id: &str,
        _acp_id: &str,
    ) -> Result<Option<String>, CliError> {
        Ok(self
            .runtime_session_id
            .lock()
            .expect("runtime session lock")
            .clone())
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
    assert_eq!(
        started.capabilities,
        vec![super::super::REPORT_ONLY_REVIEW_CAPABILITY]
    );
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
async fn resumed_turn_reuses_the_original_provider_session() {
    let manager = Arc::new(FakeManager::default());
    let runtime =
        OpenRouterAgentTurnRuntime::with_manager(manager.clone(), "session-a".into(), None);
    let original_id = runtime.start(request()).await.expect("start original turn");
    let original_session_id = runtime
        .runtime_session_id(&original_id)
        .expect("original provider session");

    runtime
        .start_with_resume_session(request(), Some(original_session_id))
        .await
        .expect("resume turn");

    let resumed = manager
        .request
        .lock()
        .expect("request lock")
        .clone()
        .expect("captured resumed start");
    assert!(!resumed.resume_disabled);
    assert_eq!(
        resumed.resume_session_id.as_deref(),
        Some("openrouter-session-1")
    );
}

#[tokio::test]
async fn resumed_turn_fails_closed_when_the_provider_opens_a_new_session() {
    let manager = Arc::new(FakeManager::default());
    let runtime =
        OpenRouterAgentTurnRuntime::with_manager(manager.clone(), "session-a".into(), None);
    *manager
        .runtime_session_id
        .lock()
        .expect("runtime session lock") = Some("fallback-session".into());

    runtime
        .start_with_resume_session(request(), Some("openrouter-session-1".into()))
        .await
        .expect_err("fallback session must fail closed");

    assert!(*manager.stopped.lock().expect("stopped lock"));
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

pub(super) async fn open_store() -> (tempfile::TempDir, Arc<AsyncDaemonDb>) {
    let dir = tempfile::tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open async db");
    (dir, Arc::new(db))
}

pub(super) fn request() -> AgentTurnRequest {
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
