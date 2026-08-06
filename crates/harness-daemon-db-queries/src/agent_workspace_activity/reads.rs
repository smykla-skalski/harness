use harness_daemon_db_core::{db_error, usize_from_i64};
use harness_kernel::errors::CliError;
use harness_protocol::agent::{Signal, SignalAck};
use harness_protocol::daemon::activity::{
    AgentWorkspaceActivityEntry, AgentWorkspaceActivityOwner, AgentWorkspaceActivityOwnerKind,
    AgentWorkspaceActivityWindowResponse, AgentWorkspaceConversationRecord,
    AgentWorkspaceMemberActivityResponse, AgentWorkspaceSignalRecord,
};
use harness_protocol::session::SessionSignalStatus;
use harness_protocol::timeline::{TimelineCursor, TimelineWindowRequest};
use serde_json::Value;
use sqlx::{FromRow, Sqlite, Transaction, query_as, query_scalar};

use crate::derive_effective_signal_status;

#[derive(Debug, FromRow)]
struct ActivityEntryRow {
    entry_id: String,
    recorded_at: String,
    kind: String,
    owner_kind: String,
    owner_id: String,
    member_id: Option<String>,
    source_session_id: Option<String>,
    source_agent_id: Option<String>,
    legacy_task_id: Option<String>,
    summary: String,
    payload_json: String,
}

#[derive(Debug, FromRow)]
struct ConversationRow {
    workspace_id: String,
    member_id: String,
    runtime: String,
    recorded_at: String,
    event_json: String,
    source_session_id: Option<String>,
    source_agent_id: Option<String>,
}

#[derive(Debug, FromRow)]
struct SignalRow {
    workspace_id: String,
    member_id: String,
    runtime: String,
    status: String,
    signal_json: String,
    ack_json: Option<String>,
    source_session_id: Option<String>,
    source_agent_id: Option<String>,
}

pub(super) async fn load_activity_window(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
    request: &TimelineWindowRequest,
) -> Result<AgentWorkspaceActivityWindowResponse, CliError> {
    crate::timeline::validate_timeline_window_request(request)?;
    let (revision, count) = query_as::<_, (i64, i64)>(
        "SELECT revision, entry_count FROM agent_workspace_timeline_state
         WHERE workspace_id = ?1",
    )
    .bind(workspace_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load durable activity timeline state: {error}")))?;
    let total_count = usize_from_i64(count);
    let limit = request.limit.unwrap_or(total_count).max(1);
    if request.known_revision == Some(revision)
        && request.before.is_none()
        && request.after.is_none()
    {
        return unchanged_window(transaction, workspace_id, revision, total_count, limit).await;
    }
    let window_start = window_start(transaction, workspace_id, request, total_count, limit).await?;
    let rows = window_rows(
        transaction,
        workspace_id,
        request,
        window_start,
        total_count,
        limit,
    )
    .await?;
    let summary_only = request.scope.as_deref() == Some("summary");
    let entries = rows
        .into_iter()
        .map(|row| row.into_entry(summary_only))
        .collect::<Result<Vec<_>, _>>()?;
    let window_end = window_start + entries.len();
    Ok(AgentWorkspaceActivityWindowResponse {
        workspace_id: workspace_id.to_string(),
        revision,
        total_count,
        window_start,
        window_end,
        has_older: window_end < total_count,
        has_newer: window_start > 0,
        oldest_cursor: entries.last().map(entry_cursor),
        newest_cursor: entries.first().map(entry_cursor),
        entries: Some(entries),
        unchanged: false,
    })
}

pub(super) async fn load_member_activity(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
    member_id: &str,
) -> Result<AgentWorkspaceMemberActivityResponse, CliError> {
    let exists = query_scalar::<_, i64>(
        "SELECT EXISTS (SELECT 1 FROM agent_workspace_members
                        WHERE workspace_id = ?1 AND member_id = ?2)",
    )
    .bind(workspace_id)
    .bind(member_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("verify durable activity member: {error}")))?;
    if exists != 1 {
        return Err(db_error(format!(
            "durable agent member '{member_id}' was not found in workspace '{workspace_id}'"
        )));
    }
    let activity = query_scalar::<_, String>(
        "SELECT activity_json FROM agent_workspace_activity_summaries
         WHERE workspace_id = ?1 AND member_id = ?2",
    )
    .bind(workspace_id)
    .bind(member_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load durable activity summary: {error}")))?
    .map(|json| parse_json(&json, "activity summary"))
    .transpose()?;
    let conversation = query_as::<_, ConversationRow>(
        "SELECT workspace_id, member_id, runtime, recorded_at, event_json,
                source_session_id, source_agent_id
         FROM agent_workspace_conversation_events
         WHERE workspace_id = ?1 AND member_id = ?2
         ORDER BY recorded_at, stream_id, sequence",
    )
    .bind(workspace_id)
    .bind(member_id)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load durable conversation events: {error}")))?
    .into_iter()
    .map(ConversationRow::into_record)
    .collect::<Result<Vec<_>, _>>()?;
    let signals = query_as::<_, SignalRow>(
        "SELECT workspace_id, member_id, runtime, status, signal_json, ack_json,
                source_session_id, source_agent_id
         FROM agent_workspace_signals
         WHERE workspace_id = ?1 AND member_id = ?2
         ORDER BY created_at DESC, signal_id DESC",
    )
    .bind(workspace_id)
    .bind(member_id)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load durable agent signals: {error}")))?
    .into_iter()
    .map(SignalRow::into_record)
    .collect::<Result<Vec<_>, _>>()?;
    Ok(AgentWorkspaceMemberActivityResponse {
        workspace_id: workspace_id.to_string(),
        member_id: member_id.to_string(),
        owner: AgentWorkspaceActivityOwner {
            kind: AgentWorkspaceActivityOwnerKind::ManagedAgent,
            id: member_id.to_string(),
        },
        activity,
        conversation,
        signals,
    })
}

pub(super) async fn load_signal_record(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
    member_id: &str,
    signal_id: &str,
) -> Result<AgentWorkspaceSignalRecord, CliError> {
    query_as::<_, SignalRow>(
        "SELECT workspace_id, member_id, runtime, status, signal_json, ack_json,
                source_session_id, source_agent_id
         FROM agent_workspace_signals
         WHERE workspace_id = ?1 AND member_id = ?2 AND signal_id = ?3",
    )
    .bind(workspace_id)
    .bind(member_id)
    .bind(signal_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load durable signal record: {error}")))?
    .ok_or_else(|| {
        db_error(format!(
            "durable signal '{signal_id}' was not found for member '{member_id}'"
        ))
    })?
    .into_record()
}

async fn unchanged_window(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
    revision: i64,
    total_count: usize,
    limit: usize,
) -> Result<AgentWorkspaceActivityWindowResponse, CliError> {
    let end = total_count.min(limit);
    Ok(AgentWorkspaceActivityWindowResponse {
        workspace_id: workspace_id.to_string(),
        revision,
        total_count,
        window_start: 0,
        window_end: end,
        has_older: end < total_count,
        has_newer: false,
        oldest_cursor: cursor_at_offset(transaction, workspace_id, end.checked_sub(1)).await?,
        newest_cursor: cursor_at_offset(transaction, workspace_id, Some(0)).await?,
        entries: None,
        unchanged: true,
    })
}

async fn window_start(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
    request: &TimelineWindowRequest,
    total_count: usize,
    limit: usize,
) -> Result<usize, CliError> {
    if let Some(before) = &request.before {
        return cursor_offset(transaction, workspace_id, before)
            .await
            .map(|value| value.map_or(total_count, |offset| offset.saturating_add(1)));
    }
    if let Some(after) = &request.after {
        return cursor_offset(transaction, workspace_id, after)
            .await
            .map(|value| value.unwrap_or(0).saturating_sub(limit));
    }
    Ok(0)
}

async fn window_rows(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
    request: &TimelineWindowRequest,
    window_start: usize,
    total_count: usize,
    limit: usize,
) -> Result<Vec<ActivityEntryRow>, CliError> {
    let (offset, count) = if let Some(after) = &request.after {
        let end = cursor_offset(transaction, workspace_id, after)
            .await?
            .unwrap_or(0);
        let start = end.saturating_sub(limit);
        (start, end - start)
    } else {
        (
            window_start,
            total_count.saturating_sub(window_start).min(limit),
        )
    };
    query_as::<_, ActivityEntryRow>(
        "SELECT entry_id, recorded_at, kind, owner_kind, owner_id, member_id,
                source_session_id, source_agent_id, legacy_task_id, summary, payload_json
         FROM agent_workspace_timeline_entries WHERE workspace_id = ?1
         ORDER BY sort_recorded_at DESC, sort_tiebreaker DESC
         LIMIT ?2 OFFSET ?3",
    )
    .bind(workspace_id)
    .bind(i64::try_from(count).unwrap_or(i64::MAX))
    .bind(i64::try_from(offset).unwrap_or(i64::MAX))
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load durable activity timeline window: {error}")))
}

async fn cursor_offset(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
    cursor: &TimelineCursor,
) -> Result<Option<usize>, CliError> {
    let offset = query_scalar::<_, i64>(
        "WITH target AS (
            SELECT sort_recorded_at, sort_tiebreaker
            FROM agent_workspace_timeline_entries
            WHERE workspace_id = ?1 AND recorded_at = ?2 AND entry_id = ?3
         )
         SELECT (
            SELECT COUNT(*) FROM agent_workspace_timeline_entries entry
            WHERE entry.workspace_id = ?1 AND (
                entry.sort_recorded_at > target.sort_recorded_at OR
                (entry.sort_recorded_at = target.sort_recorded_at
                 AND entry.sort_tiebreaker > target.sort_tiebreaker)
            )
         ) FROM target",
    )
    .bind(workspace_id)
    .bind(&cursor.recorded_at)
    .bind(&cursor.entry_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load durable activity cursor offset: {error}")))?;
    Ok(offset.map(usize_from_i64))
}

async fn cursor_at_offset(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
    offset: Option<usize>,
) -> Result<Option<TimelineCursor>, CliError> {
    let Some(offset) = offset else {
        return Ok(None);
    };
    query_as::<_, (String, String)>(
        "SELECT recorded_at, entry_id FROM agent_workspace_timeline_entries
         WHERE workspace_id = ?1
         ORDER BY sort_recorded_at DESC, sort_tiebreaker DESC LIMIT 1 OFFSET ?2",
    )
    .bind(workspace_id)
    .bind(i64::try_from(offset).unwrap_or(i64::MAX))
    .fetch_optional(transaction.as_mut())
    .await
    .map(|row| {
        row.map(|(recorded_at, entry_id)| TimelineCursor {
            recorded_at,
            entry_id,
        })
    })
    .map_err(|error| db_error(format!("load durable activity cursor: {error}")))
}

impl ActivityEntryRow {
    fn into_entry(self, summary_only: bool) -> Result<AgentWorkspaceActivityEntry, CliError> {
        Ok(AgentWorkspaceActivityEntry {
            entry_id: self.entry_id,
            recorded_at: self.recorded_at,
            kind: self.kind,
            owner: AgentWorkspaceActivityOwner {
                kind: parse_owner_kind(&self.owner_kind)?,
                id: self.owner_id,
            },
            member_id: self.member_id,
            legacy_session_id: self.source_session_id,
            legacy_agent_id: self.source_agent_id,
            legacy_task_id: self.legacy_task_id,
            summary: self.summary,
            payload: if summary_only {
                Value::Null
            } else {
                parse_json(&self.payload_json, "activity timeline payload")?
            },
        })
    }
}

impl ConversationRow {
    fn into_record(self) -> Result<AgentWorkspaceConversationRecord, CliError> {
        Ok(AgentWorkspaceConversationRecord {
            workspace_id: self.workspace_id,
            member_id: self.member_id.clone(),
            owner: AgentWorkspaceActivityOwner {
                kind: AgentWorkspaceActivityOwnerKind::ManagedAgent,
                id: self.member_id,
            },
            runtime: self.runtime,
            recorded_at: self.recorded_at,
            event: parse_json(&self.event_json, "conversation event")?,
            legacy_session_id: self.source_session_id,
            legacy_agent_id: self.source_agent_id,
        })
    }
}

impl SignalRow {
    pub(super) fn into_record(self) -> Result<AgentWorkspaceSignalRecord, CliError> {
        let signal: Signal = parse_json(&self.signal_json, "durable signal")?;
        let acknowledgment: Option<SignalAck> = self
            .ack_json
            .as_deref()
            .map(|json| parse_json(json, "durable signal acknowledgment"))
            .transpose()?;
        let stored = parse_signal_status(&self.status)?;
        Ok(AgentWorkspaceSignalRecord {
            workspace_id: self.workspace_id,
            member_id: self.member_id.clone(),
            owner: AgentWorkspaceActivityOwner {
                kind: AgentWorkspaceActivityOwnerKind::ManagedAgent,
                id: self.member_id,
            },
            runtime: self.runtime,
            status: derive_effective_signal_status(stored, &signal),
            signal,
            acknowledgment,
            legacy_session_id: self.source_session_id,
            legacy_agent_id: self.source_agent_id,
        })
    }
}

fn entry_cursor(entry: &AgentWorkspaceActivityEntry) -> TimelineCursor {
    TimelineCursor {
        recorded_at: entry.recorded_at.clone(),
        entry_id: entry.entry_id.clone(),
    }
}

fn parse_owner_kind(value: &str) -> Result<AgentWorkspaceActivityOwnerKind, CliError> {
    match value {
        "workspace" => Ok(AgentWorkspaceActivityOwnerKind::Workspace),
        "managed_agent" => Ok(AgentWorkspaceActivityOwnerKind::ManagedAgent),
        "work_item" => Ok(AgentWorkspaceActivityOwnerKind::WorkItem),
        "review" => Ok(AgentWorkspaceActivityOwnerKind::Review),
        "execution" => Ok(AgentWorkspaceActivityOwnerKind::Execution),
        _ => Err(db_error(format!(
            "unknown durable activity owner kind '{value}'"
        ))),
    }
}

fn parse_signal_status(value: &str) -> Result<SessionSignalStatus, CliError> {
    match value {
        "pending" => Ok(SessionSignalStatus::Pending),
        "delivered" => Ok(SessionSignalStatus::Delivered),
        "rejected" => Ok(SessionSignalStatus::Rejected),
        "deferred" => Ok(SessionSignalStatus::Deferred),
        "expired" => Ok(SessionSignalStatus::Expired),
        _ => Err(db_error(format!("unknown durable signal status '{value}'"))),
    }
}

fn parse_json<T: serde::de::DeserializeOwned>(json: &str, label: &str) -> Result<T, CliError> {
    serde_json::from_str(json).map_err(|error| db_error(format!("parse {label}: {error}")))
}
