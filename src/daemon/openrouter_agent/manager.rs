//! In-daemon OpenRouter agent session manager (turn loop in `turn_runner`).
//!
//! Slated for removal once `crates/harness-openrouter-agent` covers the same
//! surface via the ACP catalog.

use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::broadcast;
use tokio::task::JoinHandle;
use tracing::error;
use uuid::Uuid;

use crate::agents::acp::client::HarnessAcpClient;
use crate::agents::openrouter::{
    AgentConfig as OpenRouterAgentConfig, ChatMessage, ChatRole, ModelListResponse,
    OpenRouterClient, OpenRouterError,
};
use crate::daemon::agent_acp::permission_bridge::{
    AcpPermissionDecision, PermissionBridgeHandle,
};
use crate::daemon::protocol::StreamEvent;
use crate::daemon::state;
use crate::errors::{CliError, CliErrorKind};
use crate::hooks::runner_policy::managed_cluster_binaries;
use crate::session::types::ManagedAgentKind;
use crate::workspace::utc_now;

use super::snapshot::{OpenRouterRunSnapshot, OpenRouterRunStatus};

const PERMISSION_BRIDGE_DEADLINE: Duration = Duration::from_secs(300);

mod turn_runner;

/// Default model when the start request leaves it unset.
pub const DEFAULT_OPENROUTER_MODEL: &str = "anthropic/claude-3.7-sonnet";

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct OpenRouterStartRequest {
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub prompt: Option<String>,
    #[serde(default)]
    pub session_agent_id: Option<String>,
    #[serde(default)]
    pub display_name: Option<String>,
    #[serde(default)]
    pub temperature: Option<f32>,
    #[serde(default)]
    pub max_tokens: Option<u32>,
    /// `low` / `medium` / `high`; ignored on models without reasoning support.
    #[serde(default)]
    pub reasoning_effort: Option<String>,
    /// Project directory the tool dispatcher uses as both `working_dir` and
    /// `run_dir`. Defaults to the daemon's current working directory.
    #[serde(default)]
    pub project_dir: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OpenRouterRunListResponse {
    pub runs: Vec<OpenRouterRunSnapshot>,
}

#[derive(Clone)]
pub struct OpenRouterAgentManagerHandle {
    pub(super) inner: Arc<Inner>,
}

pub(super) struct Inner {
    pub(super) sender: broadcast::Sender<StreamEvent>,
    pub(super) sessions: Mutex<BTreeMap<String, SessionEntry>>,
}

pub(super) struct SessionEntry {
    pub(super) snapshot: OpenRouterRunSnapshot,
    pub(super) history: Vec<ChatMessage>,
    pub(super) config: OpenRouterAgentConfig,
    pub(super) active_turn: Option<JoinHandle<()>>,
    pub(super) temperature: Option<f32>,
    pub(super) max_tokens: Option<u32>,
    pub(super) reasoning_effort: Option<String>,
    pub(super) project_dir: PathBuf,
    pub(super) tool_client: Arc<HarnessAcpClient>,
    pub(super) permissions: PermissionBridgeHandle,
}

pub(super) struct TurnParams {
    pub snapshot: OpenRouterRunSnapshot,
    pub history: Vec<ChatMessage>,
    pub config: OpenRouterAgentConfig,
    pub temperature: Option<f32>,
    pub max_tokens: Option<u32>,
    pub reasoning_effort: Option<String>,
    pub project_dir: PathBuf,
    pub tool_client: Arc<HarnessAcpClient>,
}

impl OpenRouterAgentManagerHandle {
    #[must_use]
    pub fn new(sender: broadcast::Sender<StreamEvent>) -> Self {
        Self {
            inner: Arc::new(Inner {
                sender,
                sessions: Mutex::new(BTreeMap::new()),
            }),
        }
    }

    /// Create a new session and optionally kick off the first turn when the
    /// request carries a prompt.
    ///
    /// # Errors
    /// Returns an error if `OPENROUTER_API_KEY` is missing from the daemon's
    /// environment.
    pub fn start(
        &self,
        harness_session: &str,
        request: OpenRouterStartRequest,
    ) -> Result<OpenRouterRunSnapshot, CliError> {
        let config = OpenRouterAgentConfig::from_env_with_override(
            state::task_board_openrouter_token(),
        )
        .map_err(|error| {
            CliError::from(CliErrorKind::workflow_parse(format!(
                "OpenRouter configuration error: {error}"
            )))
        })?;
        let model = request
            .model
            .clone()
            .unwrap_or_else(|| DEFAULT_OPENROUTER_MODEL.to_owned());
        let project_dir = resolve_project_dir(request.project_dir.as_deref());
        let run_id = format!("openrouter-{}", Uuid::new_v4());
        let permissions = PermissionBridgeHandle::spawn_with_kind(
            run_id.clone(),
            harness_session.to_owned(),
            ManagedAgentKind::OpenRouter,
            self.inner.sender.clone(),
        );
        let tool_client = Arc::new(build_tool_client(&project_dir, &permissions));
        let now = utc_now();
        let snapshot = OpenRouterRunSnapshot {
            run_id: run_id.clone(),
            session_id: harness_session.to_owned(),
            session_agent_id: request.session_agent_id.clone(),
            display_name: request
                .display_name
                .clone()
                .unwrap_or_else(|| "OpenRouter".to_owned()),
            model,
            status: OpenRouterRunStatus::Pending,
            latest_message: None,
            latest_reasoning: None,
            final_message: None,
            error: None,
            turn_count: 0,
            pending_permission_batches: Vec::new(),
            created_at: now.clone(),
            updated_at: now,
        };
        let prompt_text = request.prompt.clone();
        {
            let mut sessions = lock_sessions(&self.inner);
            sessions.insert(
                run_id.clone(),
                SessionEntry {
                    snapshot: snapshot.clone(),
                    history: Vec::new(),
                    config,
                    active_turn: None,
                    temperature: request.temperature,
                    max_tokens: request.max_tokens,
                    reasoning_effort: request.reasoning_effort,
                    project_dir,
                    tool_client,
                    permissions,
                },
            );
        }
        self.emit(
            &snapshot.session_id,
            "openrouter_run_started",
            json!({
                "run_id": snapshot.run_id,
                "model": snapshot.model,
                "session_id": snapshot.session_id,
            }),
        );
        if let Some(text) = prompt_text {
            return self.prompt(&run_id, text);
        }
        Ok(snapshot)
    }

    /// Append a user turn and start a streaming completion against
    /// `OpenRouter`.
    ///
    /// Returns immediately after the turn task is spawned; chunks fan out
    /// through the broadcast channel and the snapshot updates in place.
    ///
    /// # Errors
    /// Returns an error if `run_id` does not exist.
    pub fn prompt(&self, run_id: &str, text: String) -> Result<OpenRouterRunSnapshot, CliError> {
        let turn_params = {
            let mut sessions = lock_sessions(&self.inner);
            let entry = sessions.get_mut(run_id).ok_or_else(|| not_found(run_id))?;
            entry.history.push(ChatMessage {
                role: ChatRole::User,
                content: Some(text),
                tool_call_id: None,
                name: None,
                tool_calls: Vec::new(),
            });
            entry.snapshot.status = OpenRouterRunStatus::Streaming;
            entry.snapshot.latest_message = None;
            entry.snapshot.latest_reasoning = None;
            entry.snapshot.error = None;
            entry.snapshot.updated_at = utc_now();
            entry.snapshot.turn_count = entry.snapshot.turn_count.saturating_add(1);
            TurnParams {
                snapshot: entry.snapshot.clone(),
                history: entry.history.clone(),
                config: entry.config.clone(),
                temperature: entry.temperature,
                max_tokens: entry.max_tokens,
                reasoning_effort: entry.reasoning_effort.clone(),
                project_dir: entry.project_dir.clone(),
                tool_client: Arc::clone(&entry.tool_client),
            }
        };
        let snapshot = turn_params.snapshot.clone();
        let manager = self.clone();
        let run_id_owned = run_id.to_owned();
        let join = tokio::spawn(async move {
            manager.run_turn(run_id_owned, turn_params).await;
        });
        if let Some(entry) = lock_sessions(&self.inner).get_mut(run_id) {
            entry.active_turn = Some(join);
        }
        Ok(snapshot)
    }

    /// Abort any in-flight turn and mark the snapshot as cancelled.
    ///
    /// # Errors
    /// Returns an error if `run_id` does not exist.
    pub fn cancel(&self, run_id: &str) -> Result<OpenRouterRunSnapshot, CliError> {
        let mut sessions = lock_sessions(&self.inner);
        let entry = sessions.get_mut(run_id).ok_or_else(|| not_found(run_id))?;
        if let Some(handle) = entry.active_turn.take() {
            handle.abort();
        }
        entry.snapshot.status = OpenRouterRunStatus::Cancelled;
        entry.snapshot.updated_at = utc_now();
        let snapshot = entry.snapshot.clone();
        drop(sessions);
        self.emit(
            &snapshot.session_id,
            "openrouter_run_cancelled",
            json!({"run_id": snapshot.run_id}),
        );
        Ok(snapshot)
    }

    /// Fetch the current snapshot for a session, with live pending permission
    /// batches mixed in.
    ///
    /// # Errors
    /// Returns an error if `run_id` does not exist.
    pub fn get(&self, run_id: &str) -> Result<OpenRouterRunSnapshot, CliError> {
        let sessions = lock_sessions(&self.inner);
        let entry = sessions.get(run_id).ok_or_else(|| not_found(run_id))?;
        Ok(snapshot_with_pending(entry))
    }

    /// Resolve a pending permission batch produced by this session's tool
    /// dispatcher.
    ///
    /// # Errors
    /// Returns an error if `run_id` does not exist or the batch is stale.
    pub fn resolve_permission_batch(
        &self,
        run_id: &str,
        batch_id: &str,
        decision: &AcpPermissionDecision,
    ) -> Result<OpenRouterRunSnapshot, CliError> {
        let snapshot = {
            let sessions = lock_sessions(&self.inner);
            let entry = sessions.get(run_id).ok_or_else(|| not_found(run_id))?;
            if entry
                .permissions
                .resolve_batch(batch_id, decision)
                .is_none()
            {
                return Err(CliError::from(CliErrorKind::session_not_active(format!(
                    "permission_batch_stale: OpenRouter permission batch '{batch_id}' is not pending for session '{run_id}'"
                ))));
            }
            snapshot_with_pending(entry)
        };
        self.emit(
            &snapshot.session_id,
            "openrouter_permission_batch_resolved",
            json!({"run_id": snapshot.run_id, "batch_id": batch_id}),
        );
        Ok(snapshot)
    }

    /// Return whether the manager owns a session for the given run id. Used by
    /// the shared permission resolve route to decide which manager handles a
    /// batch.
    #[must_use]
    pub fn has_session(&self, run_id: &str) -> bool {
        lock_sessions(&self.inner).contains_key(run_id)
    }

    /// Fetch the live per-key model catalog from `OpenRouter`'s `/models/user`
    /// endpoint. Uses the daemon-state token first, falling back to env.
    ///
    /// # Errors
    /// Returns an error if the API key is missing, transport fails, or the
    /// response cannot be parsed.
    pub async fn list_models(&self) -> Result<ModelListResponse, CliError> {
        let config = OpenRouterAgentConfig::from_env_with_override(
            state::task_board_openrouter_token(),
        )
        .map_err(|error| {
            CliError::from(CliErrorKind::workflow_parse(format!(
                "OpenRouter configuration error: {error}"
            )))
        })?;
        let client = OpenRouterClient::new(
            config.base_url,
            config.api_key,
            config.http_referer,
            config.x_title,
        )
        .map_err(|error| {
            CliError::from(CliErrorKind::workflow_parse(format!(
                "OpenRouter client init failed: {error}"
            )))
        })?;
        client
            .list_models()
            .await
            .map_err(|error| CliError::from(CliErrorKind::workflow_parse(classify(error))))
    }

    /// List every `OpenRouter` session belonging to the given harness session.
    #[must_use]
    pub fn list_for_session(&self, harness_session: &str) -> OpenRouterRunListResponse {
        let sessions = lock_sessions(&self.inner);
        let runs = sessions
            .values()
            .filter(|entry| entry.snapshot.session_id == harness_session)
            .map(snapshot_with_pending)
            .collect();
        OpenRouterRunListResponse { runs }
    }

    pub(super) fn update_snapshot<F: FnOnce(&mut OpenRouterRunSnapshot)>(
        &self,
        run_id: &str,
        mutate: F,
    ) {
        let mut sessions = lock_sessions(&self.inner);
        if let Some(entry) = sessions.get_mut(run_id) {
            mutate(&mut entry.snapshot);
        }
    }

    pub(super) fn finish_with_assistant_message(&self, run_id: &str, message: String) {
        let snapshot = {
            let mut sessions = lock_sessions(&self.inner);
            let Some(entry) = sessions.get_mut(run_id) else {
                return;
            };
            if !message.is_empty() {
                entry.history.push(ChatMessage {
                    role: ChatRole::Assistant,
                    content: Some(message.clone()),
                    tool_call_id: None,
                    name: None,
                    tool_calls: Vec::new(),
                });
            }
            entry.snapshot.status = OpenRouterRunStatus::Idle;
            entry.snapshot.final_message = Some(message);
            entry.snapshot.updated_at = utc_now();
            entry.snapshot.error = None;
            entry.active_turn = None;
            entry.snapshot.clone()
        };
        self.emit(
            &snapshot.session_id,
            "openrouter_run_completed",
            json!({
                "run_id": snapshot.run_id,
                "final_message": snapshot.final_message,
                "turn_count": snapshot.turn_count,
            }),
        );
    }

    pub(super) fn finish_with_error(&self, run_id: &str, message: &str) {
        if let Some(snapshot) = self.mark_failed(run_id, message) {
            self.emit_failure(&snapshot, message);
        }
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macros inflate cognitive complexity; logging plus a single emit call is already minimal"
    )]
    fn emit_failure(&self, snapshot: &OpenRouterRunSnapshot, message: &str) {
        error!(run_id = %snapshot.run_id, error = %message, "OpenRouter turn failed");
        self.emit(
            &snapshot.session_id,
            "openrouter_run_failed",
            json!({"run_id": snapshot.run_id, "error": message}),
        );
    }

    fn mark_failed(&self, run_id: &str, message: &str) -> Option<OpenRouterRunSnapshot> {
        let mut sessions = lock_sessions(&self.inner);
        let entry = sessions.get_mut(run_id)?;
        entry.snapshot.status = OpenRouterRunStatus::Failed;
        entry.snapshot.error = Some(message.to_owned());
        entry.snapshot.updated_at = utc_now();
        entry.active_turn = None;
        Some(entry.snapshot.clone())
    }

    pub(super) fn emit(&self, session_id: &str, event: &str, payload: Value) {
        let event = StreamEvent {
            event: event.to_owned(),
            recorded_at: utc_now(),
            session_id: Some(session_id.to_owned()),
            payload,
        };
        let _ = self.inner.sender.send(event);
    }
}

pub(super) fn lock_sessions(inner: &Inner) -> MutexGuard<'_, BTreeMap<String, SessionEntry>> {
    inner.sessions.lock().unwrap_or_else(PoisonError::into_inner)
}

pub(super) fn build_client(params: &TurnParams) -> Result<OpenRouterClient, String> {
    OpenRouterClient::new(
        params.config.base_url.clone(),
        params.config.api_key.clone(),
        params.config.http_referer.clone(),
        params.config.x_title.clone(),
    )
    .map_err(|error| format!("client init failed: {error}"))
}

fn not_found(run_id: &str) -> CliError {
    CliError::from(CliErrorKind::session_not_active(format!(
        "openrouter run '{run_id}' not found"
    )))
}

pub(super) fn classify(error: OpenRouterError) -> String {
    match error {
        OpenRouterError::RateLimited { retry_after } => retry_after.map_or_else(
            || "OpenRouter rate limit exceeded".to_owned(),
            |d| format!("OpenRouter rate limit exceeded (retry after {}s)", d.as_secs()),
        ),
        OpenRouterError::AuthenticationFailed { body } => {
            format!("OpenRouter authentication failed: {body}")
        }
        OpenRouterError::Moderation { body } => format!("OpenRouter moderation block: {body}"),
        OpenRouterError::Overloaded { status } => {
            format!("OpenRouter upstream overloaded (HTTP {status})")
        }
        OpenRouterError::ApiError { status, body } => format!("OpenRouter HTTP {status}: {body}"),
        other => other.to_string(),
    }
}

fn resolve_project_dir(requested: Option<&str>) -> PathBuf {
    if let Some(path) = requested {
        return PathBuf::from(path);
    }
    env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

pub(super) fn snapshot_with_pending(entry: &SessionEntry) -> OpenRouterRunSnapshot {
    let mut snapshot = entry.snapshot.clone();
    snapshot.pending_permission_batches = entry.permissions.pending_batches();
    snapshot
}

fn build_tool_client(project_dir: &Path, bridge: &PermissionBridgeHandle) -> HarnessAcpClient {
    let denied: BTreeSet<String> = managed_cluster_binaries();
    let permission_mode = bridge.mode(PERMISSION_BRIDGE_DEADLINE);
    HarnessAcpClient::new(
        project_dir.to_path_buf(),
        project_dir.to_path_buf(),
        None,
        denied,
        permission_mode,
    )
}

#[cfg(test)]
mod tests;
