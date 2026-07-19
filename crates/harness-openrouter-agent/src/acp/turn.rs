//! Streaming turn loop for the OpenRouter ACP shim.
//!
//! One `drive_turn()` call corresponds to one `session/prompt` request. The
//! loop:
//!
//! 1. Builds a `ChatRequest` from the session's current history + tool
//!    catalog and starts a streaming completion.
//! 2. For each SSE chunk, fans content out as ACP `SessionUpdate` notifications
//!    and accumulates tool_calls deltas keyed by index.
//! 3. If the choice finishes with `finish_reason: ToolCalls`, dispatches each
//!    finalized call through the daemon's ACP client side, appends a
//!    `role: tool` message per call to history, and loops for another stream.
//! 4. When the choice finishes without tool calls, returns `StopReason::EndTurn`.
//!
//! `MAX_TOOL_ITERATIONS` caps runaway loops.
//!
//! Cancellation is checked between SSE chunks and between tool calls; once
//! the per-session flag flips, the loop short-circuits to
//! `StopReason::Cancelled` and the partial assistant message is preserved in
//! history.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use agent_client_protocol::schema::v1::{
    ContentBlock, ContentChunk, SessionId, SessionNotification, SessionUpdate, StopReason,
    TextContent,
};
use agent_client_protocol::{Client, ConnectionTo};
use futures_util::StreamExt;

use crate::openrouter::{
    AssistantToolCall, ChatChoiceDelta, ChatMessage, ChatRequest, ChatRole, FinishReason,
    OpenRouterClient, OpenRouterError, ReasoningRequest, ToolChoice, ToolChoiceMode,
};

use super::session::{SessionSnapshot, SessionStore};
use super::tool_dispatch::dispatch_tool_call;
use super::tool_translator::{
    PartialToolCall, absorb_tool_call_delta, finalize_tool_calls, tool_catalog,
};

/// Maximum number of tool-call loops per user turn.
pub const MAX_TOOL_ITERATIONS: u32 = 10;

/// Drive one ACP `session/prompt` turn to completion. Mutates the session's
/// history via `store`. Returns the `StopReason` to embed in the
/// `PromptResponse`.
pub async fn drive_turn(
    connection: &ConnectionTo<Client>,
    client: &OpenRouterClient,
    store: &SessionStore,
    session_id: &SessionId,
    user_prompt: Vec<ContentBlock>,
) -> StopReason {
    store.reset_cancel(session_id).await;
    let Some(initial) = store.snapshot(session_id).await else {
        return StopReason::Refusal;
    };

    let user_message = user_message_from_content(&user_prompt);
    store
        .extend_history(session_id, vec![user_message])
        .await;

    for _ in 0..MAX_TOOL_ITERATIONS {
        let snapshot = match store.snapshot(session_id).await {
            Some(snapshot) => snapshot,
            None => return StopReason::Refusal,
        };
        if snapshot.cancel_flag.load(Ordering::SeqCst) {
            return StopReason::Cancelled;
        }
        let request = build_request(&snapshot);
        let stream = match client.stream_chat(request).await {
            Ok(stream) => stream,
            Err(error) => return error_to_stop_reason(connection, session_id, &error),
        };
        let outcome = drain_stream(connection, session_id, &snapshot.cancel_flag, stream).await;
        let turn = match outcome {
            Ok(turn) => turn,
            Err(stop_reason) => return stop_reason,
        };
        if !turn.finished_with_tool_calls || turn.tool_calls.is_empty() {
            store
                .extend_history(session_id, vec![assistant_text_message(&turn.text)])
                .await;
            return StopReason::EndTurn;
        }
        store
            .extend_history(session_id, vec![assistant_tool_message(&turn)])
            .await;
        let tool_messages = execute_tool_calls(
            connection,
            session_id,
            &initial.project_dir,
            &turn.tool_calls,
            &snapshot.cancel_flag,
        )
        .await;
        store.extend_history(session_id, tool_messages).await;
    }
    StopReason::MaxTurnRequests
}

#[derive(Debug, Default)]
struct TurnResult {
    text: String,
    tool_calls: Vec<AssistantToolCall>,
    finished_with_tool_calls: bool,
}

async fn drain_stream(
    connection: &ConnectionTo<Client>,
    session_id: &SessionId,
    cancel_flag: &Arc<AtomicBool>,
    mut stream: std::pin::Pin<
        Box<dyn futures_util::Stream<Item = Result<crate::openrouter::StreamChunk, OpenRouterError>> + Send>,
    >,
) -> Result<TurnResult, StopReason> {
    let mut text = String::new();
    let mut accumulator: BTreeMap<u32, PartialToolCall> = BTreeMap::new();
    let mut finished_with_tool_calls = false;
    while let Some(chunk_result) = stream.next().await {
        if cancel_flag.load(Ordering::SeqCst) {
            return Err(StopReason::Cancelled);
        }
        let chunk = match chunk_result {
            Ok(chunk) => chunk,
            Err(error) => return Err(error_to_stop_reason(connection, session_id, &error)),
        };
        for choice in chunk.choices {
            absorb_choice_delta(
                connection,
                session_id,
                choice.delta,
                &mut text,
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
    connection: &ConnectionTo<Client>,
    session_id: &SessionId,
    delta: ChatChoiceDelta,
    text: &mut String,
    accumulator: &mut BTreeMap<u32, PartialToolCall>,
) {
    if let Some(content) = delta.content {
        text.push_str(&content);
        send_chunk(
            connection,
            session_id,
            SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(
                TextContent::new(content),
            ))),
        );
    }
    if let Some(reasoning) = delta.reasoning {
        send_chunk(
            connection,
            session_id,
            SessionUpdate::AgentThoughtChunk(ContentChunk::new(ContentBlock::Text(
                TextContent::new(reasoning),
            ))),
        );
    }
    for tool_delta in delta.tool_calls {
        absorb_tool_call_delta(accumulator, tool_delta);
    }
}

fn send_chunk(connection: &ConnectionTo<Client>, session_id: &SessionId, update: SessionUpdate) {
    if let Err(error) =
        connection.send_notification(SessionNotification::new(session_id.clone(), update))
    {
        tracing::warn!(%error, "failed to send session/update notification");
    }
}

async fn execute_tool_calls(
    connection: &ConnectionTo<Client>,
    session_id: &SessionId,
    project_dir: &Path,
    calls: &[AssistantToolCall],
    cancel_flag: &Arc<AtomicBool>,
) -> Vec<ChatMessage> {
    let mut messages = Vec::with_capacity(calls.len());
    for call in calls {
        if cancel_flag.load(Ordering::SeqCst) {
            messages.push(tool_message(call, &serde_json::json!({ "error": "cancelled" })));
            continue;
        }
        let result = dispatch_tool_call(
            connection,
            session_id,
            project_dir,
            &call.function.name,
            &call.function.arguments,
        )
        .await;
        messages.push(tool_message(call, &result));
    }
    messages
}

fn tool_message(call: &AssistantToolCall, result: &serde_json::Value) -> ChatMessage {
    ChatMessage {
        role: ChatRole::Tool,
        content: Some(result.to_string()),
        tool_call_id: Some(call.id.clone()),
        name: Some(call.function.name.clone()),
        tool_calls: Vec::new(),
    }
}

fn assistant_text_message(text: &str) -> ChatMessage {
    ChatMessage {
        role: ChatRole::Assistant,
        content: if text.is_empty() {
            None
        } else {
            Some(text.to_owned())
        },
        tool_call_id: None,
        name: None,
        tool_calls: Vec::new(),
    }
}

fn assistant_tool_message(turn: &TurnResult) -> ChatMessage {
    ChatMessage {
        role: ChatRole::Assistant,
        content: if turn.text.is_empty() {
            None
        } else {
            Some(turn.text.clone())
        },
        tool_call_id: None,
        name: None,
        tool_calls: turn.tool_calls.clone(),
    }
}

fn user_message_from_content(prompt: &[ContentBlock]) -> ChatMessage {
    let text = prompt
        .iter()
        .map(content_block_text)
        .collect::<Vec<_>>()
        .join("\n");
    ChatMessage {
        role: ChatRole::User,
        content: Some(text),
        tool_call_id: None,
        name: None,
        tool_calls: Vec::new(),
    }
}

fn content_block_text(block: &ContentBlock) -> String {
    match block {
        ContentBlock::Text(text) => text.text.clone(),
        ContentBlock::ResourceLink(link) => format!("<resource:{}>", link.uri),
        _ => String::new(),
    }
}

fn build_request(snapshot: &SessionSnapshot) -> ChatRequest {
    ChatRequest {
        model: snapshot.model.clone(),
        messages: snapshot.history.clone(),
        stream: true,
        tools: tool_catalog(),
        tool_choice: Some(ToolChoice::Mode(ToolChoiceMode::Auto)),
        parallel_tool_calls: None,
        reasoning: snapshot.reasoning_effort.clone().map(|effort| ReasoningRequest {
            effort: Some(effort),
            exclude: None,
        }),
        temperature: None,
        max_tokens: None,
    }
}

fn error_to_stop_reason(
    connection: &ConnectionTo<Client>,
    session_id: &SessionId,
    error: &OpenRouterError,
) -> StopReason {
    let message = format!("openrouter error: {error}");
    tracing::warn!(%error, "openrouter turn failed");
    let chunk = ContentChunk::new(ContentBlock::Text(TextContent::new(format!(
        "[openrouter error] {message}"
    ))));
    if let Err(send_error) = connection.send_notification(SessionNotification::new(
        session_id.clone(),
        SessionUpdate::AgentMessageChunk(chunk),
    )) {
        tracing::warn!(%send_error, "failed to surface openrouter error to client");
    }
    match error {
        OpenRouterError::Moderation { .. } => StopReason::Refusal,
        _ => StopReason::EndTurn,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::openrouter::ChatMessage;

    #[test]
    fn assistant_text_message_omits_content_when_empty() {
        let msg = assistant_text_message("");
        assert!(matches!(msg.role, ChatRole::Assistant));
        assert!(msg.content.is_none());
    }

    #[test]
    fn assistant_text_message_sets_content_when_present() {
        let msg = assistant_text_message("hi");
        assert_eq!(msg.content.as_deref(), Some("hi"));
    }

    #[test]
    fn user_message_concatenates_text_blocks() {
        let prompt = vec![
            ContentBlock::Text(TextContent::new("first")),
            ContentBlock::Text(TextContent::new("second")),
        ];
        let msg = user_message_from_content(&prompt);
        assert_eq!(msg.content.as_deref(), Some("first\nsecond"));
    }

    #[test]
    fn build_request_uses_session_model_and_catalog() {
        let snapshot = SessionSnapshot {
            project_dir: std::path::PathBuf::from("/tmp"),
            model: "anthropic/claude-haiku-4-5".to_owned(),
            reasoning_effort: Some("high".to_owned()),
            history: vec![ChatMessage {
                role: ChatRole::User,
                content: Some("hello".to_owned()),
                tool_call_id: None,
                name: None,
                tool_calls: Vec::new(),
            }],
            cancel_flag: Arc::new(AtomicBool::new(false)),
        };
        let request = build_request(&snapshot);
        assert_eq!(request.model, "anthropic/claude-haiku-4-5");
        assert!(request.stream);
        assert!(!request.tools.is_empty());
        assert!(matches!(
            request.reasoning,
            Some(ReasoningRequest {
                effort: Some(ref effort),
                ..
            }) if effort == "high"
        ));
    }

    #[test]
    fn tool_message_round_trip_keeps_id_and_name() {
        let call = AssistantToolCall {
            id: "call-1".to_owned(),
            kind: crate::openrouter::AssistantToolCallKind::Function,
            function: crate::openrouter::AssistantToolCallFunction {
                name: "read_text_file".to_owned(),
                arguments: "{}".to_owned(),
            },
        };
        let msg = tool_message(&call, &serde_json::json!({"content": "x"}));
        assert!(matches!(msg.role, ChatRole::Tool));
        assert_eq!(msg.tool_call_id.as_deref(), Some("call-1"));
        assert_eq!(msg.name.as_deref(), Some("read_text_file"));
    }
}
