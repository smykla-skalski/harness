use harness_daemon_db_core::db_error;
use harness_kernel::errors::CliError;
use harness_protocol::agent::ConversationEvent;
use harness_protocol::session::SessionState;
use harness_session::wire::AgentToolActivitySummary;
use rusqlite::Connection;

use super::{PreparedAgentTranscriptResync, PreparedConversationEventImport};

/// # Errors
/// Returns [`CliError`] when `load_events` fails.
pub fn prepare_agent_conversation_imports_and_activity<F>(
    state: &SessionState,
    mut load_events: F,
) -> Result<
    (
        Vec<AgentToolActivitySummary>,
        Vec<PreparedConversationEventImport>,
    ),
    CliError,
>
where
    F: FnMut(&str, &str, &str) -> Result<Vec<ConversationEvent>, CliError>,
{
    let mut activities = Vec::with_capacity(state.agents.len());
    let mut conversation_events = Vec::with_capacity(state.agents.len());

    for (agent_id, agent) in &state.agents {
        let session_key = agent
            .agent_session_id
            .as_deref()
            .unwrap_or(&state.session_id);
        let events = load_events(agent_id, agent.runtime.runtime_name(), session_key)?;
        activities.push(harness_daemon_snapshot::agent_activity_summary_from_events(
            agent_id,
            agent.runtime.runtime_name(),
            agent.last_activity_at.as_deref(),
            &events,
        ));
        conversation_events.push(PreparedConversationEventImport {
            agent_id: agent_id.clone(),
            runtime: agent.runtime.to_string(),
            events,
        });
    }

    Ok((activities, conversation_events))
}

/// # Errors
/// Returns [`CliError`] when `load_events` fails.
pub fn prepare_runtime_transcript_resync_for_agents<F>(
    state: &SessionState,
    runtime_name: &str,
    runtime_session_id: &str,
    mut load_events: F,
) -> Result<Vec<PreparedAgentTranscriptResync>, CliError>
where
    F: FnMut(&str, &str, &str) -> Result<Vec<ConversationEvent>, CliError>,
{
    let mut prepared = Vec::new();

    for (agent_id, agent) in &state.agents {
        let session_key = agent
            .agent_session_id
            .as_deref()
            .unwrap_or(&state.session_id);
        if agent.runtime != runtime_name || session_key != runtime_session_id {
            continue;
        }

        let events = load_events(agent_id, agent.runtime.runtime_name(), session_key)?;
        let activity = harness_daemon_snapshot::agent_activity_summary_from_events(
            agent_id,
            agent.runtime.runtime_name(),
            agent.last_activity_at.as_deref(),
            &events,
        );
        prepared.push(PreparedAgentTranscriptResync {
            agent_id: agent_id.clone(),
            runtime: agent.runtime.to_string(),
            activity,
            events,
        });
    }

    Ok(prepared)
}

/// Extract the discriminant from a serialized `ConversationEventKind` JSON
/// string. Returns the tagged `type` field (for example `assistant_text` or
/// `permission_asked`) for indexing.
#[must_use]
pub fn extract_conversation_event_kind(json: &str) -> String {
    serde_json::from_str::<serde_json::Value>(json)
        .ok()
        .and_then(|value| {
            value
                .as_object()
                .and_then(|object| object.get("type"))
                .and_then(serde_json::Value::as_str)
                .map(String::from)
                .or_else(|| value.as_str().map(String::from))
        })
        .unwrap_or_default()
}

/// # Errors
/// Returns [`CliError`] on SQL failures.
pub fn clear_session_conversation_events(
    conn: &Connection,
    session_id: &str,
) -> Result<(), CliError> {
    conn.execute(
        "DELETE FROM conversation_events WHERE session_id = ?1",
        [session_id],
    )
    .map_err(|error| db_error(format!("clear session conversation events: {error}")))?;
    Ok(())
}
