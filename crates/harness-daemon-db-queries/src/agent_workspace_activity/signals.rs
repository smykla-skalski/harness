use harness_daemon_db_core::db_error;
use harness_kernel::errors::CliError;
use harness_protocol::agent::{AckResult, Signal, SignalAck};
use harness_protocol::daemon::activity::AgentWorkspaceSignalRecord;
use sha2::{Digest, Sha256};
use sqlx::{FromRow, Sqlite, Transaction, query, query_as};

use super::reads::load_signal_record;
use super::types::{AgentWorkspaceSignalInsertion, AgentWorkspaceSignalTarget};

#[derive(Debug, FromRow)]
struct SignalTargetRow {
    workspace_id: String,
    member_id: String,
    runtime: String,
    managed_agent_kind: Option<String>,
    managed_agent_id: Option<String>,
    runtime_session_id: Option<String>,
    project_dir: String,
    source_session_id: Option<String>,
    source_agent_id: Option<String>,
}

pub(super) async fn load_signal_target(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
    member_id: &str,
) -> Result<AgentWorkspaceSignalTarget, CliError> {
    load_signal_target_with_policy(transaction, workspace_id, member_id, true).await
}

pub(super) async fn load_signal_cleanup_target(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
    member_id: &str,
) -> Result<AgentWorkspaceSignalTarget, CliError> {
    load_signal_target_with_policy(transaction, workspace_id, member_id, false).await
}

async fn load_signal_target_with_policy(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
    member_id: &str,
    require_addressable: bool,
) -> Result<AgentWorkspaceSignalTarget, CliError> {
    let row = query_as::<_, SignalTargetRow>(
        "SELECT member.workspace_id, member.member_id, member.runtime_kind AS runtime,
                member.managed_agent_kind, member.managed_agent_id,
                member.runtime_session_id,
                COALESCE(workspace.project_dir, workspace.context_root) AS project_dir,
                member.source_session_id, member.source_agent_id
         FROM agent_workspace_members member
         JOIN agent_workspaces workspace ON workspace.workspace_id = member.workspace_id
         WHERE member.workspace_id = ?1 AND member.member_id = ?2
           AND (
               ?3 = 0
               OR (
                   member.membership_status IN ('joined', 'pending_registration')
                   AND (
                       member.runtime_lifecycle IN ('running', 'recoverable')
                       OR (
                           member.runtime_lifecycle = 'unavailable'
                           AND member.liveness_status IN ('active', 'idle', 'awaiting_review')
                       )
                   )
               )
           )",
    )
    .bind(workspace_id)
    .bind(member_id)
    .bind(require_addressable)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load durable signal target: {error}")))?
    .ok_or_else(|| {
        let qualifier = if require_addressable { "active " } else { "" };
        db_error(format!(
            "{qualifier}durable agent member '{member_id}' was not found in workspace '{workspace_id}'"
        ))
    })?;
    let managed_agent_kind = row.managed_agent_kind.ok_or_else(|| {
        db_error(format!(
            "durable agent member '{member_id}' has no managed runtime identity"
        ))
    })?;
    let managed_agent_id = row.managed_agent_id.ok_or_else(|| {
        db_error(format!(
            "durable agent member '{member_id}' has no managed runtime identifier"
        ))
    })?;
    Ok(AgentWorkspaceSignalTarget {
        workspace_id: row.workspace_id,
        member_id: row.member_id,
        runtime: row.runtime,
        managed_agent_kind,
        managed_agent_id,
        runtime_session_id: row.runtime_session_id,
        project_dir: row.project_dir,
        source_session_id: row.source_session_id,
        source_agent_id: row.source_agent_id,
    })
}

pub(super) async fn insert_signal(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
    member_id: &str,
    runtime: &str,
    signal: &Signal,
) -> Result<AgentWorkspaceSignalInsertion, CliError> {
    let idempotency_key = signal
        .delivery
        .idempotency_key
        .as_deref()
        .filter(|key| !key.trim().is_empty())
        .ok_or_else(|| db_error("durable agent signal is missing its idempotency key"))?;
    let signal_json = serde_json::to_string(signal)
        .map_err(|error| db_error(format!("serialize durable signal: {error}")))?;
    let source_digest = digest(&signal_json);
    let now = harness_workspace::workspace::utc_now();
    let inserted = query(
        "INSERT INTO agent_workspace_signals (
            workspace_id, member_id, signal_id, idempotency_key, runtime, status, signal_json,
            ack_json, origin_kind, source_session_id, source_agent_id,
            source_digest, created_at, updated_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, 'pending', ?6, NULL, 'native',
                   NULL, NULL, ?7, ?8, ?8)
         ON CONFLICT DO NOTHING",
    )
    .bind(workspace_id)
    .bind(member_id)
    .bind(&signal.signal_id)
    .bind(idempotency_key)
    .bind(runtime)
    .bind(&signal_json)
    .bind(&source_digest)
    .bind(&now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("insert durable agent signal: {error}")))?
    .rows_affected();
    if inserted == 0 {
        return load_idempotent_signal(
            transaction,
            workspace_id,
            member_id,
            runtime,
            &signal.signal_id,
            idempotency_key,
            signal,
        )
        .await;
    }
    let timeline_payload = serde_json::json!({
        "runtime": runtime,
        "signal": signal,
    });
    insert_signal_timeline(
        transaction,
        workspace_id,
        member_id,
        &signal.signal_id,
        &signal.created_at,
        "signal_sent",
        &format!("Signal {} sent", signal.command),
        &timeline_payload,
        &source_digest,
    )
    .await?;
    refresh_timeline_state(transaction, workspace_id).await?;
    let record =
        load_signal_record(transaction, workspace_id, member_id, &signal.signal_id).await?;
    Ok(AgentWorkspaceSignalInsertion {
        record,
        inserted: true,
    })
}

pub(super) async fn acknowledge_signal(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
    member_id: &str,
    signal_id: &str,
    result: AckResult,
    details: Option<&str>,
    acknowledged_at: Option<&str>,
) -> Result<AgentWorkspaceSignalRecord, CliError> {
    let existing = load_signal_record(transaction, workspace_id, member_id, signal_id).await?;
    if let Some(acknowledgment) = &existing.acknowledgment {
        if acknowledgment.result == result && acknowledgment.details.as_deref() == details {
            return Ok(existing);
        }
        return Err(db_error(format!(
            "durable signal '{signal_id}' already has a different acknowledgment"
        )));
    }
    let now = acknowledged_at
        .filter(|value| chrono::DateTime::parse_from_rfc3339(value).is_ok())
        .map_or_else(harness_workspace::workspace::utc_now, str::to_string);
    let acknowledgment = SignalAck {
        signal_id: signal_id.to_string(),
        acknowledged_at: now.clone(),
        result,
        agent: member_id.to_string(),
        session_id: workspace_id.to_string(),
        details: details.map(str::to_string),
    };
    let acknowledgment_json = serde_json::to_string(&acknowledgment)
        .map_err(|error| db_error(format!("serialize durable signal acknowledgment: {error}")))?;
    let result_label = acknowledgment_label(result);
    let updated = query(
        "UPDATE agent_workspace_signals
         SET status = ?4, ack_json = ?5,
             source_digest = source_digest || ':' || ?4 || ':' || ?6,
             updated_at = ?6
         WHERE workspace_id = ?1 AND member_id = ?2 AND signal_id = ?3
           AND ack_json IS NULL",
    )
    .bind(workspace_id)
    .bind(member_id)
    .bind(signal_id)
    .bind(result_label)
    .bind(&acknowledgment_json)
    .bind(&now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("acknowledge durable agent signal: {error}")))?
    .rows_affected();
    if updated != 1 {
        return Err(db_error(format!(
            "durable signal '{signal_id}' was not found for member '{member_id}'"
        )));
    }
    let payload = serde_json::to_value(&acknowledgment)
        .map_err(|error| db_error(format!("serialize signal acknowledgment payload: {error}")))?;
    insert_signal_timeline(
        transaction,
        workspace_id,
        member_id,
        signal_id,
        &now,
        "signal_acknowledged",
        &format!("Signal acknowledged as {result_label}"),
        &payload,
        &digest(&acknowledgment_json),
    )
    .await?;
    refresh_timeline_state(transaction, workspace_id).await?;
    load_signal_record(transaction, workspace_id, member_id, signal_id).await
}

#[expect(
    clippy::too_many_arguments,
    reason = "the ledger write mirrors its explicit durable identity columns"
)]
async fn insert_signal_timeline(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
    member_id: &str,
    signal_id: &str,
    recorded_at: &str,
    kind: &str,
    summary: &str,
    payload: &serde_json::Value,
    source_digest: &str,
) -> Result<(), CliError> {
    let payload_json = serde_json::to_string(payload)
        .map_err(|error| db_error(format!("serialize durable signal timeline: {error}")))?;
    let source_kind = if kind == "signal_sent" {
        "signal"
    } else {
        "signal_ack"
    };
    let source_key = format!("{source_kind}:{signal_id}");
    let entry_id = format!("{source_kind}-{signal_id}");
    query(
        "INSERT INTO agent_workspace_timeline_entries (
            workspace_id, entry_id, source_kind, source_key, owner_kind, owner_id,
            recorded_at, kind, member_id, legacy_task_id, summary, payload_json,
            sort_recorded_at, sort_tiebreaker, origin_kind, source_session_id,
            source_agent_id, source_digest
         ) VALUES (?1, ?2, ?3, ?4, 'managed_agent', ?5, ?6, ?7, ?5,
                   NULL, ?8, ?9, ?6, ?2, 'native', NULL, NULL, ?10)
         ON CONFLICT(workspace_id, source_kind, source_key) DO UPDATE SET
            recorded_at = excluded.recorded_at, summary = excluded.summary,
            payload_json = excluded.payload_json,
            sort_recorded_at = excluded.sort_recorded_at,
            sort_tiebreaker = excluded.sort_tiebreaker,
            source_digest = excluded.source_digest",
    )
    .bind(workspace_id)
    .bind(entry_id)
    .bind(source_kind)
    .bind(source_key)
    .bind(member_id)
    .bind(recorded_at)
    .bind(kind)
    .bind(summary)
    .bind(payload_json)
    .bind(source_digest)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("insert durable signal timeline: {error}")))?;
    Ok(())
}

async fn refresh_timeline_state(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
) -> Result<(), CliError> {
    let digest = super::reconcile::durable_digest(transaction, workspace_id).await?;
    query(
        "UPDATE agent_workspace_timeline_state
         SET revision = revision + 1,
             entry_count = (SELECT COUNT(*) FROM agent_workspace_timeline_entries
                            WHERE workspace_id = ?1),
             newest_recorded_at = (SELECT MAX(recorded_at)
                                   FROM agent_workspace_timeline_entries WHERE workspace_id = ?1),
             oldest_recorded_at = (SELECT MIN(recorded_at)
                                   FROM agent_workspace_timeline_entries WHERE workspace_id = ?1),
             integrity_hash = ?2, updated_at = ?3
         WHERE workspace_id = ?1",
    )
    .bind(workspace_id)
    .bind(digest)
    .bind(harness_workspace::workspace::utc_now())
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("refresh durable signal timeline state: {error}")))?;
    Ok(())
}

async fn load_idempotent_signal(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
    member_id: &str,
    runtime: &str,
    signal_id: &str,
    idempotency_key: &str,
    requested: &Signal,
) -> Result<AgentWorkspaceSignalInsertion, CliError> {
    let identity = query_as::<_, (String, String, String, String, String)>(
        "SELECT signal_id, member_id, runtime, origin_kind, signal_json
         FROM agent_workspace_signals
         WHERE workspace_id = ?1
           AND (signal_id = ?2 OR (member_id = ?3 AND idempotency_key = ?4))
         ORDER BY CASE WHEN signal_id = ?2 THEN 0 ELSE 1 END
         LIMIT 1",
    )
    .bind(workspace_id)
    .bind(signal_id)
    .bind(member_id)
    .bind(idempotency_key)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load duplicate durable agent signal: {error}")))?;
    let Some((stored_signal_id, stored_member_id, stored_runtime, origin_kind, signal_json)) =
        identity
    else {
        return Err(db_error(format!(
            "durable signal idempotency conflict for '{idempotency_key}' has no stored record"
        )));
    };
    let stored = serde_json::from_str::<Signal>(&signal_json)
        .map_err(|error| db_error(format!("parse duplicate durable agent signal: {error}")))?;
    if stored_member_id != member_id
        || stored_runtime != runtime
        || origin_kind != "native"
        || !same_signal_intent(&stored, requested)
    {
        return Err(db_error(format!(
            "durable signal idempotency key '{idempotency_key}' is already used by a different request"
        )));
    }
    let record =
        load_signal_record(transaction, workspace_id, member_id, &stored_signal_id).await?;
    Ok(AgentWorkspaceSignalInsertion {
        record,
        inserted: false,
    })
}

fn same_signal_intent(stored: &Signal, requested: &Signal) -> bool {
    stored.version == requested.version
        && stored.source_agent == requested.source_agent
        && stored.command == requested.command
        && stored.priority == requested.priority
        && stored.payload.message == requested.payload.message
        && stored.payload.action_hint == requested.payload.action_hint
        && stored.payload.related_files == requested.payload.related_files
        && stored.payload.metadata == requested.payload.metadata
        && stored.delivery.max_retries == requested.delivery.max_retries
        && stored.delivery.retry_count == requested.delivery.retry_count
        && stored.delivery.idempotency_key == requested.delivery.idempotency_key
}

const fn acknowledgment_label(result: AckResult) -> &'static str {
    match result {
        AckResult::Accepted => "delivered",
        AckResult::Rejected => "rejected",
        AckResult::Deferred => "deferred",
        AckResult::Expired => "expired",
    }
}

fn digest(value: &str) -> String {
    hex::encode(Sha256::digest(value.as_bytes()))
}
