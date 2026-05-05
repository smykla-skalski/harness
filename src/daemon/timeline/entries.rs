//! Timeline entry constructors.
//!
//! **Sequence-space contract for synthetic producers:** events arriving here
//! carry a `ConversationEvent::sequence` that is monotonic *within an event
//! source* (the ACP receive loop, the supervisor sink, etc.) but is NOT
//! globally unique. Two different sources may emit the same numeric sequence
//! at the same time. Downstream consumers MUST key on `(entry_kind, sequence)`
//! never on `sequence` alone. This module enforces the contract structurally
//! by composing the `entry_id` as `{runtime}-{agent_id}-{entry_kind}-{sequence}`,
//! so disjoint kind strings make collisions impossible by construction.
//!
//! When adding a new synthetic producer (e.g. `PermissionAsked`, `HookFired`,
//! `ContextInjected`), pick a kind string that is disjoint from every existing
//! arm in `conversation_entry` and any future arm. Assert that contract in a
//! mapper-level test before the producer ships.

use crate::agents::runtime::event::{ConversationEvent, ConversationEventKind};
use crate::errors::CliError;
use crate::session::types::{SessionLogEntry, TaskCheckpoint};

use super::super::protocol::TimelineEntry;
use super::summary::transition_summary;
use super::{TimelinePayloadScope, timeline_payload};

pub(crate) fn log_entry_timeline_entry(
    log_entry: &SessionLogEntry,
    payload_scope: TimelinePayloadScope,
) -> Result<TimelineEntry, CliError> {
    let (kind, task_id, summary) = transition_summary(&log_entry.transition);
    let payload = timeline_payload(&log_entry.transition, "session transition", payload_scope)?;
    Ok(TimelineEntry {
        entry_id: format!("log-{}", log_entry.sequence),
        recorded_at: log_entry.recorded_at.clone(),
        kind: kind.to_string(),
        session_id: log_entry.session_id.clone(),
        agent_id: log_entry.actor_id.clone(),
        task_id,
        summary,
        payload,
    })
}

pub(crate) fn checkpoint_entry(
    session_id: &str,
    checkpoint: &TaskCheckpoint,
    payload_scope: TimelinePayloadScope,
) -> Result<TimelineEntry, CliError> {
    let payload = timeline_payload(checkpoint, "task checkpoint", payload_scope)?;
    Ok(TimelineEntry {
        entry_id: checkpoint.checkpoint_id.clone(),
        recorded_at: checkpoint.recorded_at.clone(),
        kind: "task_checkpoint".into(),
        session_id: session_id.to_string(),
        agent_id: checkpoint.actor_id.clone(),
        task_id: Some(checkpoint.task_id.clone()),
        summary: format!(
            "Checkpoint {}%: {}",
            checkpoint.progress, checkpoint.summary
        ),
        payload,
    })
}

pub(crate) fn conversation_entry(
    session_id: &str,
    agent_id: &str,
    runtime: &str,
    event: &ConversationEvent,
    payload_scope: TimelinePayloadScope,
) -> Result<Option<TimelineEntry>, CliError> {
    let Some(recorded_at) = event.timestamp.clone() else {
        return Ok(None);
    };

    let (entry_kind, summary) = match &event.kind {
        ConversationEventKind::UserPrompt { content } => (
            "user_prompt",
            transcript_summary(content, "Prompt submitted"),
        ),
        ConversationEventKind::AssistantText { content } => (
            "assistant_text",
            transcript_summary(content, "Assistant response"),
        ),
        ConversationEventKind::ToolInvocation { tool_name, .. } => {
            ("tool_invocation", format!("{agent_id} invoked {tool_name}"))
        }
        ConversationEventKind::ToolResult {
            tool_name,
            is_error,
            ..
        } => {
            let kind = if *is_error {
                "tool_result_error"
            } else {
                "tool_result"
            };
            let summary = if *is_error {
                format!("{agent_id} received an error from {tool_name}")
            } else {
                format!("{agent_id} received a result from {tool_name}")
            };
            (kind, summary)
        }
        ConversationEventKind::Error { message, .. } => {
            ("agent_error", format!("{agent_id} error: {message}"))
        }
        ConversationEventKind::SignalReceived { signal_id, command } => (
            "signal_received",
            format!("{agent_id} picked up {signal_id} ({command})"),
        ),
        ConversationEventKind::StateChange { from, to } => (
            "agent_state_change",
            format!("{agent_id} state changed {from} -> {to}"),
        ),
        ConversationEventKind::FileModification { path, operation } => (
            "file_modification",
            format!("{agent_id} {operation} {}", path.display()),
        ),
        ConversationEventKind::SessionMarker { marker } => (
            "agent_session_marker",
            format!("{agent_id} marked {marker}"),
        ),
        ConversationEventKind::WatchdogState { from, to, reason } => (
            "agent_watchdog_state",
            watchdog_summary(agent_id, from, to, reason.as_deref()),
        ),
        ConversationEventKind::PermissionAsked { tool, scope, .. } => (
            "agent_permission_asked",
            format!("{agent_id} asked for permission on {tool} ({scope})"),
        ),
        ConversationEventKind::ContextInjected { actor, .. } => (
            "agent_context_injected",
            format!("{agent_id} accepted context from {actor}"),
        ),
        ConversationEventKind::Other { .. } => return Ok(None),
    };
    let payload = timeline_payload(
        &serde_json::json!({
            "runtime": runtime,
            "event": event.kind,
        }),
        "agent conversation event",
        payload_scope,
    )?;

    Ok(Some(TimelineEntry {
        entry_id: format!("{runtime}-{agent_id}-{entry_kind}-{}", event.sequence),
        recorded_at,
        kind: entry_kind.into(),
        session_id: session_id.to_string(),
        agent_id: Some(agent_id.to_string()),
        task_id: None,
        summary,
        payload,
    }))
}

fn transcript_summary(content: &str, fallback: &str) -> String {
    let trimmed = content.trim();
    if trimmed.is_empty() {
        fallback.to_string()
    } else {
        trimmed.to_string()
    }
}

fn watchdog_summary(agent_id: &str, from: &str, to: &str, reason: Option<&str>) -> String {
    let base = format!("{agent_id} watchdog {from} -> {to}");
    match reason.map(str::trim).filter(|value| !value.is_empty()) {
        Some(reason) => format!("{base} ({reason})"),
        None => base,
    }
}
