//! `OpenRouter` agent session manager.
//!
//! Holds in-memory session state keyed by `run_id`. Each session owns a
//! conversation history and (optionally) an in-flight turn task. Streaming
//! deltas fan out through the daemon's shared `broadcast::Sender<StreamEvent>`
//! so SSE consumers see chunks in real time.

use std::collections::BTreeMap;
use std::pin::Pin;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::broadcast;
use tokio::task::JoinHandle;
use tracing::{error, warn};
use uuid::Uuid;

use crate::agents::openrouter::{
    AgentConfig as OpenRouterAgentConfig, ChatChoiceDelta, ChatMessage, ChatRequest, ChatRole,
    OpenRouterClient, OpenRouterError, ReasoningRequest, StreamChunk,
};
use crate::daemon::protocol::StreamEvent;
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;

use super::snapshot::{OpenRouterRunSnapshot, OpenRouterRunStatus};

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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OpenRouterRunListResponse {
    pub runs: Vec<OpenRouterRunSnapshot>,
}

#[derive(Clone)]
pub struct OpenRouterAgentManagerHandle {
    inner: Arc<Inner>,
}

struct Inner {
    sender: broadcast::Sender<StreamEvent>,
    sessions: Mutex<BTreeMap<String, SessionEntry>>,
}

struct SessionEntry {
    snapshot: OpenRouterRunSnapshot,
    history: Vec<ChatMessage>,
    config: OpenRouterAgentConfig,
    active_turn: Option<JoinHandle<()>>,
    temperature: Option<f32>,
    max_tokens: Option<u32>,
    reasoning_effort: Option<String>,
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
        let config = OpenRouterAgentConfig::from_env().map_err(|error| {
            CliError::from(CliErrorKind::workflow_parse(format!(
                "OpenRouter configuration error: {error}"
            )))
        })?;
        let model = request
            .model
            .clone()
            .unwrap_or_else(|| DEFAULT_OPENROUTER_MODEL.to_owned());
        let run_id = format!("openrouter-{}", Uuid::new_v4());
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

    /// Fetch the current snapshot for a session.
    ///
    /// # Errors
    /// Returns an error if `run_id` does not exist.
    pub fn get(&self, run_id: &str) -> Result<OpenRouterRunSnapshot, CliError> {
        lock_sessions(&self.inner)
            .get(run_id)
            .map(|entry| entry.snapshot.clone())
            .ok_or_else(|| not_found(run_id))
    }

    /// List every `OpenRouter` session belonging to the given harness session.
    #[must_use]
    pub fn list_for_session(&self, harness_session: &str) -> OpenRouterRunListResponse {
        let sessions = lock_sessions(&self.inner);
        let runs = sessions
            .values()
            .filter(|entry| entry.snapshot.session_id == harness_session)
            .map(|entry| entry.snapshot.clone())
            .collect();
        OpenRouterRunListResponse { runs }
    }

    async fn run_turn(self, run_id: String, params: TurnParams) {
        let client = match build_client(&params) {
            Ok(client) => client,
            Err(message) => {
                self.finish_with_error(&run_id, &message);
                return;
            }
        };
        let request = build_request(&params);
        let stream = match client.stream_chat(request).await {
            Ok(stream) => stream,
            Err(error) => {
                self.finish_with_error(&run_id, &classify(error));
                return;
            }
        };
        match self.drain_stream(&run_id, stream).await {
            Ok(final_text) => self.finish_with_assistant_message(&run_id, final_text),
            Err(message) => self.finish_with_error(&run_id, &message),
        }
    }

    async fn drain_stream(
        &self,
        run_id: &str,
        mut stream: Pin<
            Box<dyn futures_util::Stream<Item = Result<StreamChunk, OpenRouterError>> + Send>,
        >,
    ) -> Result<String, String> {
        let mut text = String::new();
        let mut reasoning = String::new();
        while let Some(chunk_result) = stream.next().await {
            let chunk = chunk_result.map_err(classify)?;
            for choice in chunk.choices {
                self.absorb_choice_delta(run_id, choice.delta, &mut text, &mut reasoning);
            }
        }
        Ok(text)
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macros inflate cognitive complexity; three if-let branches are clearer than further decomposition"
    )]
    fn absorb_choice_delta(
        &self,
        run_id: &str,
        delta: ChatChoiceDelta,
        text: &mut String,
        reasoning: &mut String,
    ) {
        if let Some(content) = delta.content {
            self.absorb_message_delta(run_id, &content, text);
        }
        if let Some(thought) = delta.reasoning {
            self.absorb_thought_delta(run_id, &thought, reasoning);
        }
        if !delta.tool_calls.is_empty() {
            warn!(run_id = %run_id, "OpenRouter tool calls received but not yet supported");
        }
    }

    fn absorb_message_delta(&self, run_id: &str, content: &str, text: &mut String) {
        text.push_str(content);
        self.observe_chunk(run_id, "openrouter_message_chunk", content);
        let snapshot_text = text.clone();
        self.update_snapshot(run_id, |snap| {
            snap.latest_message = Some(snapshot_text);
            snap.updated_at = utc_now();
        });
    }

    fn absorb_thought_delta(&self, run_id: &str, thought: &str, reasoning: &mut String) {
        reasoning.push_str(thought);
        self.observe_chunk(run_id, "openrouter_thought_chunk", thought);
        let snapshot_reasoning = reasoning.clone();
        self.update_snapshot(run_id, |snap| {
            snap.latest_reasoning = Some(snapshot_reasoning);
            snap.updated_at = utc_now();
        });
    }

    fn update_snapshot<F: FnOnce(&mut OpenRouterRunSnapshot)>(&self, run_id: &str, mutate: F) {
        let mut sessions = lock_sessions(&self.inner);
        if let Some(entry) = sessions.get_mut(run_id) {
            mutate(&mut entry.snapshot);
        }
    }

    fn finish_with_assistant_message(&self, run_id: &str, message: String) {
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

    fn finish_with_error(&self, run_id: &str, message: &str) {
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

    fn observe_chunk(&self, run_id: &str, event: &str, text: &str) {
        let session_id = lock_sessions(&self.inner)
            .get(run_id)
            .map(|entry| entry.snapshot.session_id.clone())
            .unwrap_or_default();
        self.emit(
            &session_id,
            event,
            json!({"run_id": run_id, "delta": text}),
        );
    }

    fn emit(&self, session_id: &str, event: &str, payload: Value) {
        let event = StreamEvent {
            event: event.to_owned(),
            recorded_at: utc_now(),
            session_id: Some(session_id.to_owned()),
            payload,
        };
        let _ = self.inner.sender.send(event);
    }
}

struct TurnParams {
    snapshot: OpenRouterRunSnapshot,
    history: Vec<ChatMessage>,
    config: OpenRouterAgentConfig,
    temperature: Option<f32>,
    max_tokens: Option<u32>,
    reasoning_effort: Option<String>,
}

fn lock_sessions(inner: &Inner) -> MutexGuard<'_, BTreeMap<String, SessionEntry>> {
    inner.sessions.lock().unwrap_or_else(PoisonError::into_inner)
}

fn build_client(params: &TurnParams) -> Result<OpenRouterClient, String> {
    OpenRouterClient::new(
        params.config.base_url.clone(),
        params.config.api_key.clone(),
        params.config.http_referer.clone(),
        params.config.x_title.clone(),
    )
    .map_err(|error| format!("client init failed: {error}"))
}

fn build_request(params: &TurnParams) -> ChatRequest {
    ChatRequest {
        model: params.snapshot.model.clone(),
        messages: params.history.clone(),
        stream: true,
        tools: Vec::new(),
        tool_choice: None,
        parallel_tool_calls: None,
        reasoning: params
            .reasoning_effort
            .clone()
            .map(|effort| ReasoningRequest {
                effort: Some(effort),
                exclude: None,
            }),
        temperature: params.temperature,
        max_tokens: params.max_tokens,
    }
}

fn not_found(run_id: &str) -> CliError {
    CliError::from(CliErrorKind::session_not_active(format!(
        "openrouter run '{run_id}' not found"
    )))
}

fn classify(error: OpenRouterError) -> String {
    match error {
        OpenRouterError::RateLimited { retry_after } => match retry_after {
            Some(duration) => format!(
                "OpenRouter rate limit exceeded (retry after {}s)",
                duration.as_secs()
            ),
            None => "OpenRouter rate limit exceeded".to_owned(),
        },
        OpenRouterError::AuthenticationFailed { body } => {
            format!("OpenRouter authentication failed: {body}")
        }
        OpenRouterError::Moderation { body } => {
            format!("OpenRouter moderation block: {body}")
        }
        OpenRouterError::Overloaded { status } => {
            format!("OpenRouter upstream overloaded (HTTP {status})")
        }
        OpenRouterError::ApiError { status, body } => {
            format!("OpenRouter HTTP {status}: {body}")
        }
        other => other.to_string(),
    }
}

#[cfg(test)]
mod tests;
