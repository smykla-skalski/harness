use std::collections::{BTreeMap, HashSet};

use serde_json::{Map, Value, to_value};

use crate::errors::{CliError, CliErrorKind};
use crate::session::types::{SessionLogEntry, SessionState, SessionTransition, TaskCheckpoint};

use super::index;
use super::protocol::TimelineEntry;
use observer::observer_snapshot_entry;
use signals::{LoggedSignal, signal_ack_entries};

mod entries;
mod observer;
mod signals;
mod summary;
#[cfg(test)]
mod tests;

pub(crate) use entries::{checkpoint_entry, conversation_entry, log_entry_timeline_entry};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TimelinePayloadScope {
    Full,
    Summary,
}

/// Build a merged session timeline from session transitions and task checkpoints.
///
/// # Errors
/// Returns `CliError` on discovery or parse failures.
pub fn session_timeline(session_id: &str) -> Result<Vec<TimelineEntry>, CliError> {
    session_timeline_with_scope(session_id, TimelinePayloadScope::Full)
}

/// Build a timeline with caller-selected payload detail.
///
/// # Errors
/// Returns [`CliError`] on discovery or parse failures.
pub(crate) fn session_timeline_with_scope(
    session_id: &str,
    payload_scope: TimelinePayloadScope,
) -> Result<Vec<TimelineEntry>, CliError> {
    let resolved = index::resolve_session(session_id)?;
    session_timeline_from_resolved_with_scope(&resolved, payload_scope)
}

/// Build a timeline from a pre-resolved session (avoids full discovery).
///
/// # Errors
/// Returns [`CliError`] on parse failures.
pub fn session_timeline_from_resolved(
    resolved: &index::ResolvedSession,
) -> Result<Vec<TimelineEntry>, CliError> {
    session_timeline_from_resolved_with_scope(resolved, TimelinePayloadScope::Full)
}

fn session_timeline_from_resolved_with_scope(
    resolved: &index::ResolvedSession,
    payload_scope: TimelinePayloadScope,
) -> Result<Vec<TimelineEntry>, CliError> {
    build_timeline(resolved, None, payload_scope)
}

/// Build timeline using the DB for log entries and checkpoints when available.
///
/// # Errors
/// Returns [`CliError`] on parse failures.
pub fn session_timeline_from_resolved_with_db(
    resolved: &index::ResolvedSession,
    db: &super::db::DaemonDb,
) -> Result<Vec<TimelineEntry>, CliError> {
    session_timeline_from_resolved_with_db_scope(resolved, db, TimelinePayloadScope::Full)
}

/// Build timeline using the DB for log entries and checkpoints with caller-selected payload detail.
///
/// # Errors
/// Returns [`CliError`] on parse failures.
pub(crate) fn session_timeline_from_resolved_with_db_scope(
    resolved: &index::ResolvedSession,
    db: &super::db::DaemonDb,
    payload_scope: TimelinePayloadScope,
) -> Result<Vec<TimelineEntry>, CliError> {
    build_timeline(resolved, Some(db), payload_scope)
}

fn build_timeline(
    resolved: &index::ResolvedSession,
    db: Option<&super::db::DaemonDb>,
    payload_scope: TimelinePayloadScope,
) -> Result<Vec<TimelineEntry>, CliError> {
    let session_id = &resolved.state.session_id;
    let mut entries = Vec::new();
    let mut logged_signal_acks = HashSet::new();
    let mut sent_signals = BTreeMap::new();

    let log_entries = load_log_entries_hybrid(db, &resolved.project, session_id)?;
    for log_entry in log_entries {
        if let SessionTransition::SignalAcknowledged { signal_id, .. } = &log_entry.transition {
            logged_signal_acks.insert(signal_id.clone());
        }
        if let SessionTransition::SignalSent {
            signal_id,
            agent_id,
            command,
        } = &log_entry.transition
        {
            sent_signals.insert(
                signal_id.clone(),
                LoggedSignal {
                    agent_id: agent_id.clone(),
                    command: command.clone(),
                },
            );
        }
        entries.push(log_entry_timeline_entry(&log_entry, payload_scope)?);
    }

    entries.extend(load_conversation_entries_hybrid(
        db,
        &resolved.project,
        &resolved.state,
        payload_scope,
    )?);

    for task_id in resolved.state.tasks.keys() {
        let checkpoints = load_checkpoints_hybrid(db, &resolved.project, session_id, task_id)?;
        for checkpoint in checkpoints {
            entries.push(checkpoint_entry(session_id, &checkpoint, payload_scope)?);
        }
    }

    entries.extend(signal_ack_entries(
        &resolved.state,
        &resolved.project.context_root,
        &sent_signals,
        &logged_signal_acks,
        payload_scope,
    )?);

    if let Some(observer_entry) = observer_snapshot_entry(
        &resolved.state,
        &resolved.project.context_root,
        payload_scope,
    )? {
        entries.push(observer_entry);
    }

    entries.sort_by(|left, right| right.recorded_at.cmp(&left.recorded_at));
    Ok(entries)
}

fn load_log_entries_hybrid(
    db: Option<&super::db::DaemonDb>,
    project: &index::DiscoveredProject,
    session_id: &str,
) -> Result<Vec<SessionLogEntry>, CliError> {
    if let Some(db) = db {
        return db.load_session_log(session_id);
    }
    index::load_log_entries(project, session_id)
}

fn load_checkpoints_hybrid(
    db: Option<&super::db::DaemonDb>,
    project: &index::DiscoveredProject,
    session_id: &str,
    task_id: &str,
) -> Result<Vec<TaskCheckpoint>, CliError> {
    if let Some(db) = db {
        return db.load_task_checkpoints(session_id, task_id);
    }
    index::load_task_checkpoints(project, session_id, task_id)
}

fn load_conversation_entries_hybrid(
    db: Option<&super::db::DaemonDb>,
    project: &index::DiscoveredProject,
    state: &SessionState,
    payload_scope: TimelinePayloadScope,
) -> Result<Vec<TimelineEntry>, CliError> {
    if let Some(db) = db {
        return conversation_entries_from_db(db, state, payload_scope);
    }
    conversation_entries(project, state, payload_scope)
}

fn conversation_entries_from_db(
    db: &super::db::DaemonDb,
    state: &SessionState,
    payload_scope: TimelinePayloadScope,
) -> Result<Vec<TimelineEntry>, CliError> {
    let mut entries = Vec::new();
    for (agent_id, agent) in &state.agents {
        let events = db.load_conversation_events(&state.session_id, agent_id)?;
        for event in events {
            if let Some(entry) = conversation_entry(
                &state.session_id,
                agent_id,
                agent.runtime.runtime_name(),
                &event,
                payload_scope,
            )? {
                entries.push(entry);
            }
        }
    }
    Ok(entries)
}

fn conversation_entries(
    project: &index::DiscoveredProject,
    state: &SessionState,
    payload_scope: TimelinePayloadScope,
) -> Result<Vec<TimelineEntry>, CliError> {
    let mut entries = Vec::new();
    for (agent_id, agent) in &state.agents {
        let session_key = agent
            .agent_session_id
            .as_deref()
            .unwrap_or(&state.session_id);
        let events = index::load_conversation_events(
            project,
            agent.runtime.runtime_name(),
            session_key,
            agent_id,
        )?;
        for event in events {
            if let Some(entry) = conversation_entry(
                &state.session_id,
                agent_id,
                agent.runtime.runtime_name(),
                &event,
                payload_scope,
            )? {
                entries.push(entry);
            }
        }
    }
    Ok(entries)
}

pub(super) fn timeline_payload(
    value: &impl serde::Serialize,
    label: &str,
    payload_scope: TimelinePayloadScope,
) -> Result<Value, CliError> {
    if payload_scope == TimelinePayloadScope::Summary {
        return Ok(Value::Object(Map::new()));
    }
    to_value(value).map_err(|error| {
        CliError::from(CliErrorKind::workflow_serialize(format!(
            "serialize {label} for timeline: {error}"
        )))
    })
}
