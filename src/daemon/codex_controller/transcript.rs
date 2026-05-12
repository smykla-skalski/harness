use serde_json::{Value, json};

use crate::daemon::protocol::{CodexRunEvent, CodexRunSnapshot, TimelineEntry};

pub(super) fn codex_transcript_entries(run: &CodexRunSnapshot) -> Vec<TimelineEntry> {
    let mut entries = Vec::new();
    entries.push(codex_timeline_entry(
        run,
        "prompt",
        run.created_at.clone(),
        "user_prompt",
        trim_transcript_summary(&run.prompt, "Prompt submitted"),
        json!({
            "type": "user_prompt",
            "content": run.prompt.clone(),
        }),
    ));
    for event in &run.events {
        if let Some(entry) = codex_event_timeline_entry(run, event) {
            entries.push(entry);
        }
    }
    if let Some(final_message) = run
        .final_message
        .as_deref()
        .map(str::trim)
        .filter(|message| !message.is_empty())
        .filter(|message| !run_has_agent_message_text(run, message))
    {
        entries.push(codex_timeline_entry(
            run,
            "final",
            run.updated_at.clone(),
            "assistant_text",
            trim_transcript_summary(final_message, "Assistant response"),
            json!({
                "type": "assistant_text",
                "content": final_message,
                "final": true,
            }),
        ));
    }
    entries
}

fn codex_event_timeline_entry(
    run: &CodexRunSnapshot,
    event: &CodexRunEvent,
) -> Option<TimelineEntry> {
    if event.kind == "turn/steer" {
        let prompt = event
            .payload
            .pointer("/input/0/text")
            .and_then(Value::as_str)
            .unwrap_or(&event.summary);
        return Some(codex_timeline_entry(
            run,
            &event.sequence.to_string(),
            event.recorded_at.clone(),
            "user_prompt",
            trim_transcript_summary(prompt, "Steering prompt sent"),
            json!({
                "type": "user_prompt",
                "content": prompt,
                "source": "steer",
                "event": compact_codex_event_payload(event),
            }),
        ));
    }
    if let Some(entry) = codex_agent_message_entry(run, event) {
        return Some(entry);
    }
    if event.kind.contains("requestApproval") {
        return Some(codex_timeline_entry(
            run,
            &event.sequence.to_string(),
            event.recorded_at.clone(),
            "agent_permission_asked",
            event.summary.clone(),
            json!({
                "type": "permission_asked",
                "message": event.summary,
                "event": compact_codex_event_payload(event),
            }),
        ));
    }
    if event.kind == "error" {
        return Some(codex_timeline_entry(
            run,
            &event.sequence.to_string(),
            event.recorded_at.clone(),
            "agent_error",
            event.summary.clone(),
            json!({
                "type": "error",
                "message": event.summary,
                "event": compact_codex_event_payload(event),
            }),
        ));
    }
    Some(codex_timeline_entry(
        run,
        &event.sequence.to_string(),
        event.recorded_at.clone(),
        "agent_state_change",
        event.summary.clone(),
        json!({
            "type": "state_change",
            "event": compact_codex_event_payload(event),
        }),
    ))
}

fn codex_agent_message_entry(
    run: &CodexRunSnapshot,
    event: &CodexRunEvent,
) -> Option<TimelineEntry> {
    let text = agent_message_text(event)?;
    Some(codex_timeline_entry(
        run,
        &event.sequence.to_string(),
        event.recorded_at.clone(),
        "assistant_text",
        trim_transcript_summary(text, "Assistant response"),
        json!({
            "type": "assistant_text",
            "content": text,
            "event": compact_codex_event_payload(event),
        }),
    ))
}

fn run_has_agent_message_text(run: &CodexRunSnapshot, text: &str) -> bool {
    run.events
        .iter()
        .any(|event| agent_message_text(event).is_some_and(|candidate| candidate.trim() == text))
}

fn agent_message_text(event: &CodexRunEvent) -> Option<&str> {
    if event.kind != "item/completed" {
        return None;
    }
    let item = event.payload.get("item")?;
    if item.get("type").and_then(Value::as_str) != Some("agentMessage") {
        return None;
    }
    item.get("text").and_then(Value::as_str)
}

fn compact_codex_event_payload(event: &CodexRunEvent) -> Value {
    json!({
        "event_id": event.event_id.clone(),
        "sequence": event.sequence,
        "kind": event.kind.clone(),
        "summary": event.summary.clone(),
        "thread_id": event.thread_id.clone(),
        "turn_id": event.turn_id.clone(),
        "item_id": event.item_id.clone(),
    })
}

fn codex_timeline_entry(
    run: &CodexRunSnapshot,
    suffix: &str,
    recorded_at: String,
    kind: &str,
    summary: String,
    event: Value,
) -> TimelineEntry {
    let agent_id = run.session_agent_id.clone();
    TimelineEntry {
        entry_id: format!("codex-{}-{suffix}", run.run_id),
        recorded_at,
        kind: kind.to_string(),
        session_id: run.session_id.clone(),
        agent_id: agent_id.clone(),
        task_id: None,
        summary,
        payload: json!({
            "runtime": "codex",
            "event": event,
            "codex_timeline_identity": {
                "run_id": run.run_id.clone(),
                "agent_id": agent_id,
                "agent_display_name": run.display_name.clone(),
                "thread_id": run.thread_id.clone(),
                "turn_id": run.turn_id.clone(),
            },
        }),
    }
}

fn trim_transcript_summary(text: &str, fallback: &str) -> String {
    let text = text.trim();
    if text.is_empty() {
        return fallback.to_string();
    }
    const MAX_CHARS: usize = 220;
    let mut iter = text.chars();
    let trimmed: String = iter.by_ref().take(MAX_CHARS).collect();
    if iter.next().is_some() {
        format!("{trimmed}...")
    } else {
        trimmed
    }
}
