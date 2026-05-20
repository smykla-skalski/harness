//! Streaming turn loop + tool dispatch for the `OpenRouter` agent backend.
//!
//! Each prompt spawns one `run_turn` task that:
//!
//! 1. Builds a `ChatRequest` from the session's current `history` plus the
//!    fixed tool catalog and starts a streaming completion.
//! 2. Consumes the stream chunk-by-chunk, fanning text and reasoning out
//!    through the daemon's broadcast channel and accumulating any
//!    `tool_calls` deltas keyed by index.
//! 3. If the choice finishes with `finish_reason: ToolCalls`, dispatches each
//!    finalized call through [`HarnessAcpClient`], appends an assistant
//!    message (carrying `tool_calls`) and one `role: tool` message per call
//!    to `history`, then loops for another stream.
//! 4. When the choice finishes without tool calls, finalizes the snapshot
//!    via `finish_with_assistant_message`.
//!
//! A hard ceiling of [`MAX_TOOL_ITERATIONS`] guards against runaway loops
//! where the model keeps asking for tools forever.

use std::collections::BTreeMap;
use std::pin::Pin;

use futures_util::Stream;
use futures_util::StreamExt;
use serde_json::json;
use tokio::task;
use tokio::task::JoinError;
use tracing::warn;

use crate::agents::openrouter::{
    AssistantToolCall, ChatChoiceDelta, ChatMessage, ChatRequest, ChatRole, FinishReason,
    OpenRouterError, ReasoningRequest, StreamChunk, ToolChoice, ToolChoiceMode,
};
use crate::workspace::utc_now;

use super::super::tools::{
    PartialToolCall, absorb_tool_call_delta, dispatch_tool_call, finalize_tool_calls, tool_catalog,
};
use super::{
    OpenRouterAgentManagerHandle, TurnParams, build_client, classify, lock_sessions,
};

/// Maximum number of tool-call loops per user turn.
pub(super) const MAX_TOOL_ITERATIONS: u32 = 10;

pub(super) struct TurnResult {
    pub text: String,
    pub tool_calls: Vec<AssistantToolCall>,
    pub finished_with_tool_calls: bool,
}

impl OpenRouterAgentManagerHandle {
    pub(super) async fn run_turn(self, run_id: String, params: TurnParams) {
        let client = match build_client(&params) {
            Ok(client) => client,
            Err(message) => {
                self.finish_with_error(&run_id, &message);
                return;
            }
        };
        let mut history = params.history.clone();
        for _ in 0..MAX_TOOL_ITERATIONS {
            let request = build_request(&params, &history);
            let stream = match client.stream_chat(request).await {
                Ok(stream) => stream,
                Err(error) => {
                    self.finish_with_error(&run_id, &classify(error));
                    return;
                }
            };
            let turn_result = match self.drain_stream(&run_id, stream).await {
                Ok(result) => result,
                Err(message) => {
                    self.finish_with_error(&run_id, &message);
                    return;
                }
            };
            if !turn_result.finished_with_tool_calls || turn_result.tool_calls.is_empty() {
                self.finish_with_assistant_message(&run_id, turn_result.text);
                return;
            }
            history.push(assistant_tool_message(&turn_result));
            let tool_messages = self
                .execute_tool_calls(&run_id, &params, &turn_result.tool_calls)
                .await;
            history.extend(tool_messages);
            self.replace_history(&run_id, history.clone());
        }
        self.finish_with_error(&run_id, "tool call iteration cap reached");
    }

    async fn drain_stream(
        &self,
        run_id: &str,
        mut stream: Pin<
            Box<dyn Stream<Item = Result<StreamChunk, OpenRouterError>> + Send>,
        >,
    ) -> Result<TurnResult, String> {
        let mut text = String::new();
        let mut reasoning = String::new();
        let mut accumulator: BTreeMap<u32, PartialToolCall> = BTreeMap::new();
        let mut finished_with_tool_calls = false;
        while let Some(chunk_result) = stream.next().await {
            let chunk = chunk_result.map_err(classify)?;
            for choice in chunk.choices {
                self.absorb_choice_delta(
                    run_id,
                    choice.delta,
                    &mut text,
                    &mut reasoning,
                    &mut accumulator,
                );
                if matches!(choice.finish_reason, Some(FinishReason::ToolCalls)) {
                    finished_with_tool_calls = true;
                }
            }
        }
        Ok(TurnResult {
            text,
            tool_calls: finalize_tool_calls(accumulator),
            finished_with_tool_calls,
        })
    }

    fn absorb_choice_delta(
        &self,
        run_id: &str,
        delta: ChatChoiceDelta,
        text: &mut String,
        reasoning: &mut String,
        accumulator: &mut BTreeMap<u32, PartialToolCall>,
    ) {
        if let Some(content) = delta.content {
            self.absorb_message_delta(run_id, &content, text);
        }
        if let Some(thought) = delta.reasoning {
            self.absorb_thought_delta(run_id, &thought, reasoning);
        }
        for tool_delta in delta.tool_calls {
            absorb_tool_call_delta(accumulator, tool_delta);
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

    async fn execute_tool_calls(
        &self,
        run_id: &str,
        params: &TurnParams,
        calls: &[AssistantToolCall],
    ) -> Vec<ChatMessage> {
        let mut messages = Vec::with_capacity(calls.len());
        for call in calls {
            let result = self.execute_one_tool_call(run_id, params, call).await;
            messages.push(ChatMessage {
                role: ChatRole::Tool,
                content: Some(result.to_string()),
                tool_call_id: Some(call.id.clone()),
                name: Some(call.function.name.clone()),
                tool_calls: Vec::new(),
            });
        }
        messages
    }

    async fn execute_one_tool_call(
        &self,
        run_id: &str,
        params: &TurnParams,
        call: &AssistantToolCall,
    ) -> serde_json::Value {
        let session_id = params.snapshot.session_id.clone();
        self.emit(
            &session_id,
            "openrouter_tool_call_started",
            json!({
                "run_id": run_id,
                "tool_call_id": call.id,
                "name": call.function.name,
                "arguments": call.function.arguments,
            }),
        );
        let client = params.tool_client.clone();
        let project_dir = params.project_dir.clone();
        let session_id_inner = session_id.clone();
        let name = call.function.name.clone();
        let arguments = call.function.arguments.clone();
        let result = task::spawn_blocking(move || {
            dispatch_tool_call(&client, &session_id_inner, &project_dir, &name, &arguments)
        })
        .await
        .unwrap_or_else(|join_error| join_error_to_value(&join_error));
        self.emit(
            &session_id,
            "openrouter_tool_call_completed",
            json!({
                "run_id": run_id,
                "tool_call_id": call.id,
                "name": call.function.name,
                "result": result,
            }),
        );
        result
    }

    fn replace_history(&self, run_id: &str, history: Vec<ChatMessage>) {
        let mut sessions = lock_sessions(&self.inner);
        if let Some(entry) = sessions.get_mut(run_id) {
            entry.history = history;
            entry.snapshot.updated_at = utc_now();
        }
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macros inflate cognitive complexity; the body is a single log line plus a json! call"
)]
fn join_error_to_value(join_error: &JoinError) -> serde_json::Value {
    warn!(error = %join_error, "tool dispatch task panicked");
    json!({ "error": format!("tool dispatch panicked: {join_error}") })
}

fn assistant_tool_message(result: &TurnResult) -> ChatMessage {
    ChatMessage {
        role: ChatRole::Assistant,
        content: if result.text.is_empty() {
            None
        } else {
            Some(result.text.clone())
        },
        tool_call_id: None,
        name: None,
        tool_calls: result.tool_calls.clone(),
    }
}

pub(super) fn build_request(params: &TurnParams, history: &[ChatMessage]) -> ChatRequest {
    ChatRequest {
        model: params.snapshot.model.clone(),
        messages: history.to_vec(),
        stream: true,
        tools: tool_catalog(),
        tool_choice: Some(ToolChoice::Mode(ToolChoiceMode::Auto)),
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
