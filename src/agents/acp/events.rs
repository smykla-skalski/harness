//! Flush-boundary materialiser: `RawSessionUpdate` → `ConversationEvent`.
//!
//! Called once per batch at the flush boundary. Converts the compact ring
//! representation into the normalised `ConversationEvent` shape that downstream
//! consumers (Swift UI, observe module, ledger, tests) expect.
//!
//! # Event filtering policy
//!
//! The following `SessionUpdate` variants are **skipped** (not materialised):
//!
//! - `ToolCallUpdate` with status `InProgress` — intermediate progress, not a result
//! - `AvailableCommandsUpdate` — UI chrome, not conversation content
//! - `CurrentModeUpdate` — internal state, not conversation content
//! - `ConfigOptionUpdate` — internal state, not conversation content
//!
//! This means output sequence numbers may have gaps relative to input. Downstream
//! consumers must not assume contiguous sequences.

use agent_client_protocol::schema::{ContentBlock, SessionUpdate, ToolCallStatus, ToolKind};
use serde_json::Value;

use crate::agents::runtime::event::{ConversationEvent, ConversationEventKind};

use super::ring::RawSessionUpdate;

/// Materialise a batch of raw updates into conversation events.
///
/// Each update is assigned a monotonic sequence number starting from
/// `sequence_start`. Returns the events and the next sequence number.
#[must_use]
pub fn materialise_batch(
    batch: Vec<RawSessionUpdate>,
    agent: &str,
    session_id: &str,
    sequence_start: u64,
) -> (Vec<ConversationEvent>, u64) {
    let mut events = Vec::with_capacity(batch.len());
    let mut sequence = sequence_start;

    for update in batch {
        if let Some(event) =
            materialise_one(&update.notification.update, agent, session_id, sequence)
        {
            events.push(event);
            sequence += 1;
        }
    }

    (events, sequence)
}

/// Materialise a single session update into a conversation event.
///
/// Returns `None` for updates that don't map to a conversation event (e.g.,
/// config updates, mode changes).
#[must_use]
pub fn materialise_one(
    update: &SessionUpdate,
    agent: &str,
    session_id: &str,
    sequence: u64,
) -> Option<ConversationEvent> {
    let kind = match update {
        SessionUpdate::UserMessageChunk(chunk) => {
            let content = extract_text_content(&chunk.content);
            ConversationEventKind::UserPrompt { content }
        }

        SessionUpdate::AgentMessageChunk(chunk) => {
            let content = extract_text_content(&chunk.content);
            ConversationEventKind::AssistantText { content }
        }

        SessionUpdate::AgentThoughtChunk(chunk) => {
            let content = extract_text_content(&chunk.content);
            ConversationEventKind::Other {
                label: "thought".to_string(),
                data: Value::String(content),
            }
        }

        SessionUpdate::ToolCall(tc) => ConversationEventKind::ToolInvocation {
            tool_name: tc.title.clone(),
            category: tool_kind_to_str(tc.kind).to_string(),
            input: tc.raw_input.clone().unwrap_or(Value::Null),
            invocation_id: Some(tc.tool_call_id.0.to_string()),
        },

        SessionUpdate::ToolCallUpdate(tcu) => {
            let status = tcu.fields.status.as_ref();
            let is_error = status == Some(&ToolCallStatus::Failed);
            let output = tcu.fields.raw_output.clone().unwrap_or(Value::Null);

            if status == Some(&ToolCallStatus::Completed) || status == Some(&ToolCallStatus::Failed)
            {
                ConversationEventKind::ToolResult {
                    tool_name: tcu
                        .fields
                        .title
                        .clone()
                        .unwrap_or_else(|| "tool".to_string()),
                    invocation_id: Some(tcu.tool_call_id.0.to_string()),
                    output,
                    is_error,
                    duration_ms: None,
                }
            } else {
                return None;
            }
        }

        SessionUpdate::Plan(plan) => ConversationEventKind::Other {
            label: "plan".to_string(),
            data: serde_json::to_value(plan).unwrap_or(Value::Null),
        },

        SessionUpdate::SessionInfoUpdate(info) => {
            if let Some(title) = info.title.value() {
                ConversationEventKind::StateChange {
                    from: String::new(),
                    to: format!("title:{title}"),
                }
            } else {
                return None;
            }
        }

        _ => {
            return None;
        }
    };

    Some(ConversationEvent {
        timestamp: Some(chrono::Utc::now().to_rfc3339()),
        sequence,
        kind,
        agent: agent.to_string(),
        session_id: session_id.to_string(),
    })
}

/// Extract text content from a content block.
fn extract_text_content(block: &ContentBlock) -> String {
    use agent_client_protocol::schema::EmbeddedResourceResource;

    match block {
        ContentBlock::Text(tc) => tc.text.clone(),
        ContentBlock::Image(_) => "[image]".to_string(),
        ContentBlock::Audio(_) => "[audio]".to_string(),
        ContentBlock::ResourceLink(rl) => format!("[resource: {}]", rl.uri),
        ContentBlock::Resource(res) => match &res.resource {
            EmbeddedResourceResource::TextResourceContents(trc) => {
                format!("[embedded: {}]", trc.uri)
            }
            EmbeddedResourceResource::BlobResourceContents(brc) => {
                format!("[embedded blob: {}]", brc.uri)
            }
            _ => "[embedded resource]".to_string(),
        },
        _ => "[unknown content]".to_string(),
    }
}

/// Convert `ToolKind` to a string category.
fn tool_kind_to_str(kind: ToolKind) -> &'static str {
    match kind {
        ToolKind::Read => "read",
        ToolKind::Edit => "edit",
        ToolKind::Delete => "delete",
        ToolKind::Move => "move",
        ToolKind::Search => "search",
        ToolKind::Execute => "execute",
        ToolKind::Think => "think",
        ToolKind::Fetch => "fetch",
        ToolKind::SwitchMode => "switch_mode",
        _ => "other",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use agent_client_protocol::schema::{
        ContentChunk, SessionId, SessionNotification, TextContent, ToolCall, ToolCallId,
        ToolCallUpdate, ToolCallUpdateFields, ToolKind,
    };

    use crate::agents::acp::ring::RawSessionUpdate;

    fn make_raw_update(update: SessionUpdate) -> RawSessionUpdate {
        RawSessionUpdate::new(SessionNotification::new(
            SessionId::new("test-session"),
            update,
        ))
    }

    #[test]
    fn materialise_agent_message_chunk() {
        let update = SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(
            TextContent::new("Hello, world!"),
        )));
        let raw = make_raw_update(update);

        let (events, next_seq) = materialise_batch(vec![raw], "copilot", "sess1", 0);

        assert_eq!(events.len(), 1);
        assert_eq!(next_seq, 1);

        let event = &events[0];
        assert_eq!(event.agent, "copilot");
        assert_eq!(event.session_id, "sess1");
        assert_eq!(event.sequence, 0);

        match &event.kind {
            ConversationEventKind::AssistantText { content } => {
                assert_eq!(content, "Hello, world!");
            }
            _ => panic!("expected AssistantText"),
        }
    }

    #[test]
    fn materialise_tool_call() {
        let tc = ToolCall::new(ToolCallId::new("tc-1"), "Read file")
            .kind(ToolKind::Read)
            .raw_input(Some(serde_json::json!({"path": "/foo/bar"})));
        let update = SessionUpdate::ToolCall(tc);
        let raw = make_raw_update(update);

        let (events, _) = materialise_batch(vec![raw], "copilot", "sess1", 10);

        assert_eq!(events.len(), 1);
        let event = &events[0];
        assert_eq!(event.sequence, 10);

        match &event.kind {
            ConversationEventKind::ToolInvocation {
                tool_name,
                invocation_id,
                input,
                ..
            } => {
                assert_eq!(tool_name, "Read file");
                assert_eq!(invocation_id.as_deref(), Some("tc-1"));
                assert_eq!(input["path"], "/foo/bar");
            }
            _ => panic!("expected ToolInvocation"),
        }
    }

    #[test]
    fn materialise_tool_call_update_completed() {
        let tcu = ToolCallUpdate::new(
            ToolCallId::new("tc-1"),
            ToolCallUpdateFields::default()
                .title("Read file")
                .status(ToolCallStatus::Completed)
                .raw_output(serde_json::json!({"content": "file contents"})),
        );
        let update = SessionUpdate::ToolCallUpdate(tcu);
        let raw = make_raw_update(update);

        let (events, _) = materialise_batch(vec![raw], "copilot", "sess1", 0);

        assert_eq!(events.len(), 1);
        match &events[0].kind {
            ConversationEventKind::ToolResult {
                is_error,
                output,
                invocation_id,
                ..
            } => {
                assert!(!is_error);
                assert_eq!(invocation_id.as_deref(), Some("tc-1"));
                assert_eq!(output["content"], "file contents");
            }
            _ => panic!("expected ToolResult"),
        }
    }

    #[test]
    fn materialise_tool_call_update_failed() {
        let tcu = ToolCallUpdate::new(
            ToolCallId::new("tc-2"),
            ToolCallUpdateFields::default()
                .title("Write file")
                .status(ToolCallStatus::Failed),
        );
        let update = SessionUpdate::ToolCallUpdate(tcu);
        let raw = make_raw_update(update);

        let (events, _) = materialise_batch(vec![raw], "copilot", "sess1", 0);

        assert_eq!(events.len(), 1);
        match &events[0].kind {
            ConversationEventKind::ToolResult { is_error, .. } => {
                assert!(is_error);
            }
            _ => panic!("expected ToolResult"),
        }
    }

    #[test]
    fn materialise_skips_in_progress_tool_update() {
        let tcu = ToolCallUpdate::new(
            ToolCallId::new("tc-3"),
            ToolCallUpdateFields::default().status(ToolCallStatus::InProgress),
        );
        let update = SessionUpdate::ToolCallUpdate(tcu);
        let raw = make_raw_update(update);

        let (events, next_seq) = materialise_batch(vec![raw], "copilot", "sess1", 5);

        assert!(events.is_empty());
        assert_eq!(next_seq, 5);
    }

    #[test]
    fn materialise_skips_config_updates() {
        let update = SessionUpdate::ConfigOptionUpdate(
            agent_client_protocol::schema::ConfigOptionUpdate::new(vec![]),
        );
        let raw = make_raw_update(update);

        let (events, _) = materialise_batch(vec![raw], "copilot", "sess1", 0);
        assert!(events.is_empty());
    }

    #[test]
    fn materialise_batch_sequences_correctly() {
        let updates = vec![
            make_raw_update(SessionUpdate::AgentMessageChunk(ContentChunk::new(
                ContentBlock::Text(TextContent::new("one")),
            ))),
            make_raw_update(SessionUpdate::AgentMessageChunk(ContentChunk::new(
                ContentBlock::Text(TextContent::new("two")),
            ))),
            make_raw_update(SessionUpdate::AgentMessageChunk(ContentChunk::new(
                ContentBlock::Text(TextContent::new("three")),
            ))),
        ];

        let (events, next_seq) = materialise_batch(updates, "agent", "sess", 100);

        assert_eq!(events.len(), 3);
        assert_eq!(next_seq, 103);
        assert_eq!(events[0].sequence, 100);
        assert_eq!(events[1].sequence, 101);
        assert_eq!(events[2].sequence, 102);
    }
}
