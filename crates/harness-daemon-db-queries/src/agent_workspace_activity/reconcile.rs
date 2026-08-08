use harness_daemon_db_core::db_error;
use harness_kernel::errors::CliError;
use sha2::{Digest, Sha256};
use sqlx::{FromRow, Sqlite, Transaction, query, query_as, query_scalar};

#[derive(Debug, FromRow)]
struct ActivityRevisionRow {
    source_revision: i64,
    reconciled_revision: i64,
}

#[derive(Debug, FromRow)]
struct DigestRow {
    record_kind: String,
    first_key: String,
    second_key: String,
    source_digest: String,
}

pub(super) async fn reconcile_one(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
) -> Result<(), CliError> {
    let Some(revision) = load_revision(transaction, workspace_id).await? else {
        return Err(db_error(format!(
            "durable agent activity workspace '{workspace_id}' was not found"
        )));
    };
    if revision.source_revision == revision.reconciled_revision {
        return Ok(());
    }
    ensure_sources_mapped(transaction, workspace_id).await?;
    clear_active_legacy_projection(transaction, workspace_id).await?;
    project_signals(transaction, workspace_id).await?;
    project_conversation(transaction, workspace_id).await?;
    project_activity_summaries(transaction, workspace_id).await?;
    project_timeline(transaction, workspace_id).await?;
    finalize_reconciliation(transaction, workspace_id, revision.source_revision).await
}

async fn load_revision(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
) -> Result<Option<ActivityRevisionRow>, CliError> {
    query_as::<_, ActivityRevisionRow>(
        "SELECT source_revision, reconciled_revision
         FROM agent_workspace_activity_state WHERE workspace_id = ?1",
    )
    .bind(workspace_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load durable agent activity revision: {error}")))
}

async fn ensure_sources_mapped(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
) -> Result<(), CliError> {
    let unmapped = query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM (
            SELECT signal.session_id, signal.agent_id
            FROM signal_index signal
            JOIN agent_workspace_activity_sources source
              ON source.source_session_id = signal.session_id
             AND source.workspace_id = ?1 AND source.status = 'active'
            LEFT JOIN agent_workspace_member_provenance provenance
              ON provenance.workspace_id = source.workspace_id
             AND provenance.source_session_id = signal.session_id
             AND provenance.source_agent_id = signal.agent_id
            WHERE provenance.member_id IS NULL
            UNION ALL
            SELECT event.session_id, event.agent_id
            FROM conversation_events event
            JOIN agent_workspace_activity_sources source
              ON source.source_session_id = event.session_id
             AND source.workspace_id = ?1 AND source.status = 'active'
            LEFT JOIN agent_workspace_member_provenance provenance
              ON provenance.workspace_id = source.workspace_id
             AND provenance.source_session_id = event.session_id
             AND provenance.source_agent_id = event.agent_id
            WHERE provenance.member_id IS NULL
            UNION ALL
            SELECT activity.session_id, activity.agent_id
            FROM agent_activity_cache activity
            JOIN agent_workspace_activity_sources source
              ON source.source_session_id = activity.session_id
             AND source.workspace_id = ?1 AND source.status = 'active'
            LEFT JOIN agent_workspace_member_provenance provenance
              ON provenance.workspace_id = source.workspace_id
             AND provenance.source_session_id = activity.session_id
             AND provenance.source_agent_id = activity.agent_id
            WHERE provenance.member_id IS NULL
            UNION ALL
            SELECT entry.session_id, entry.agent_id
            FROM session_timeline_entries entry
            JOIN agent_workspace_activity_sources source
              ON source.source_session_id = entry.session_id
             AND source.workspace_id = ?1 AND source.status = 'active'
            LEFT JOIN agent_workspace_member_provenance provenance
              ON provenance.workspace_id = source.workspace_id
             AND provenance.source_session_id = entry.session_id
             AND provenance.source_agent_id = entry.agent_id
            WHERE entry.agent_id IS NOT NULL AND provenance.member_id IS NULL
         )",
    )
    .bind(workspace_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("verify agent activity ownership: {error}")))?;
    if unmapped == 0 {
        Ok(())
    } else {
        Err(db_error(format!(
            "agent workspace '{workspace_id}' has {unmapped} observation records without a durable member owner"
        )))
    }
}

async fn clear_active_legacy_projection(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
) -> Result<(), CliError> {
    for (label, statement) in [
        (
            "signals",
            "DELETE FROM agent_workspace_signals
             WHERE workspace_id = ?1 AND origin_kind = 'legacy'
               AND source_session_id IN (
                   SELECT source_session_id FROM agent_workspace_activity_sources
                   WHERE workspace_id = ?1 AND status = 'active')",
        ),
        (
            "conversation events",
            "DELETE FROM agent_workspace_conversation_events
             WHERE workspace_id = ?1 AND origin_kind = 'legacy'
               AND source_session_id IN (
                   SELECT source_session_id FROM agent_workspace_activity_sources
                   WHERE workspace_id = ?1 AND status = 'active')",
        ),
        (
            "activity summaries",
            "DELETE FROM agent_workspace_activity_summaries
             WHERE workspace_id = ?1 AND origin_kind = 'legacy'
               AND source_session_id IN (
                   SELECT source_session_id FROM agent_workspace_activity_sources
                   WHERE workspace_id = ?1 AND status = 'active')",
        ),
        (
            "timeline entries",
            "DELETE FROM agent_workspace_timeline_entries
             WHERE workspace_id = ?1 AND origin_kind = 'legacy'
               AND source_session_id IN (
                   SELECT source_session_id FROM agent_workspace_activity_sources
                   WHERE workspace_id = ?1 AND status = 'active')",
        ),
    ] {
        query(statement)
            .bind(workspace_id)
            .execute(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("clear durable {label} projection: {error}")))?;
    }
    Ok(())
}

async fn project_signals(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
) -> Result<(), CliError> {
    query(
        "INSERT INTO agent_workspace_signals (
            workspace_id, member_id, signal_id, runtime, status, signal_json,
            ack_json, origin_kind, source_session_id, source_agent_id,
            source_digest, created_at, updated_at
         )
         SELECT source.workspace_id, provenance.member_id, signal.signal_id,
                signal.runtime,
                CASE signal.status
                    WHEN 'acknowledged' THEN 'delivered'
                    WHEN 'delivered' THEN 'delivered'
                    WHEN 'rejected' THEN 'rejected'
                    WHEN 'deferred' THEN 'deferred'
                    WHEN 'expired' THEN 'expired'
                    ELSE 'pending'
                END,
                signal.signal_json, signal.ack_json, 'legacy', signal.session_id,
                signal.agent_id,
                lower(hex(
                    signal.signal_id || char(0) || signal.session_id || char(0)
                    || signal.agent_id || char(0) || signal.runtime || char(0)
                    || signal.status || char(0) || signal.signal_json || char(0)
                    || COALESCE(signal.ack_json, '') || char(0) || signal.created_at || char(0)
                    || signal.indexed_at
                )),
                signal.created_at, signal.indexed_at
         FROM signal_index signal
         JOIN agent_workspace_activity_sources source
           ON source.source_session_id = signal.session_id
          AND source.workspace_id = ?1 AND source.status = 'active'
         JOIN agent_workspace_member_provenance provenance
           ON provenance.workspace_id = source.workspace_id
          AND provenance.source_session_id = signal.session_id
          AND provenance.source_agent_id = signal.agent_id
         WHERE TRUE
         ON CONFLICT(workspace_id, signal_id) DO UPDATE SET
            member_id = excluded.member_id, runtime = excluded.runtime,
            status = excluded.status, signal_json = excluded.signal_json,
            ack_json = excluded.ack_json, source_session_id = excluded.source_session_id,
            source_agent_id = excluded.source_agent_id,
            source_digest = excluded.source_digest, updated_at = excluded.updated_at",
    )
    .bind(workspace_id)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("project durable agent signals: {error}")))?;
    Ok(())
}

async fn project_conversation(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
) -> Result<(), CliError> {
    query(
        "INSERT INTO agent_workspace_conversation_events (
            workspace_id, member_id, stream_id, sequence, runtime, timestamp,
            kind, event_json, origin_kind, source_session_id, source_agent_id,
            source_digest, recorded_at, updated_at
         )
         SELECT source.workspace_id, provenance.member_id,
                event.session_id || ':' || event.agent_id,
                event.sequence, event.runtime, event.timestamp, event.kind,
                event.event_json, 'legacy', event.session_id, event.agent_id,
                event.event_json,
                COALESCE(event.timestamp, source.linked_at), datetime('now')
         FROM conversation_events event
         JOIN agent_workspace_activity_sources source
           ON source.source_session_id = event.session_id
          AND source.workspace_id = ?1 AND source.status = 'active'
         JOIN agent_workspace_member_provenance provenance
           ON provenance.workspace_id = source.workspace_id
          AND provenance.source_session_id = event.session_id
          AND provenance.source_agent_id = event.agent_id
         WHERE TRUE
         ON CONFLICT(workspace_id, member_id, stream_id, sequence) DO UPDATE SET
            runtime = excluded.runtime, timestamp = excluded.timestamp,
            kind = excluded.kind, event_json = excluded.event_json,
            source_digest = excluded.source_digest, recorded_at = excluded.recorded_at,
            updated_at = excluded.updated_at",
    )
    .bind(workspace_id)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("project durable conversation events: {error}")))?;
    Ok(())
}

async fn project_activity_summaries(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
) -> Result<(), CliError> {
    query(
        "INSERT INTO agent_workspace_activity_summaries (
            workspace_id, member_id, runtime, activity_json, origin_kind,
            source_session_id, source_agent_id, source_digest, cached_at
         )
         SELECT source.workspace_id, provenance.member_id, activity.runtime,
                activity.activity_json, 'legacy', activity.session_id,
                activity.agent_id, activity.activity_json, activity.cached_at
         FROM agent_activity_cache activity
         JOIN agent_workspace_activity_sources source
           ON source.source_session_id = activity.session_id
          AND source.workspace_id = ?1 AND source.status = 'active'
         JOIN agent_workspace_member_provenance provenance
           ON provenance.workspace_id = source.workspace_id
          AND provenance.source_session_id = activity.session_id
          AND provenance.source_agent_id = activity.agent_id
         WHERE TRUE
         ORDER BY activity.cached_at, activity.session_id, activity.agent_id
         ON CONFLICT(workspace_id, member_id) DO UPDATE SET
            runtime = excluded.runtime, activity_json = excluded.activity_json,
            origin_kind = excluded.origin_kind,
            source_session_id = excluded.source_session_id,
            source_agent_id = excluded.source_agent_id,
            source_digest = excluded.source_digest, cached_at = excluded.cached_at",
    )
    .bind(workspace_id)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("project durable agent activity: {error}")))?;
    Ok(())
}

async fn project_timeline(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
) -> Result<(), CliError> {
    query(
        "INSERT INTO agent_workspace_timeline_entries (
            workspace_id, entry_id, source_kind, source_key, owner_kind, owner_id,
            recorded_at, kind, member_id, legacy_task_id, summary, payload_json,
            sort_recorded_at, sort_tiebreaker, origin_kind, source_session_id,
            source_agent_id, source_digest
         )
         SELECT source.workspace_id,
                'legacy:' || entry.session_id || ':' || entry.entry_id,
                'legacy:' || entry.source_kind,
                entry.session_id || ':' || entry.source_key,
                CASE
                    WHEN COALESCE(json_extract(entry.payload_json, '$.review_id'), '') <> ''
                        THEN 'review'
                    WHEN COALESCE(json_extract(entry.payload_json, '$.execution_id'), '') <> ''
                        THEN 'execution'
                    WHEN provenance.member_id IS NOT NULL THEN 'managed_agent'
                    WHEN entry.task_id IS NOT NULL THEN 'work_item'
                    ELSE 'workspace'
                END,
                CASE
                    WHEN COALESCE(json_extract(entry.payload_json, '$.review_id'), '') <> ''
                        THEN json_extract(entry.payload_json, '$.review_id')
                    WHEN COALESCE(json_extract(entry.payload_json, '$.execution_id'), '') <> ''
                        THEN json_extract(entry.payload_json, '$.execution_id')
                    WHEN provenance.member_id IS NOT NULL THEN provenance.member_id
                    WHEN entry.task_id IS NOT NULL THEN entry.task_id
                    ELSE source.workspace_id
                END,
                entry.recorded_at, entry.kind, provenance.member_id, entry.task_id,
                entry.summary, entry.payload_json, entry.sort_recorded_at,
                entry.session_id || ':' || entry.sort_tiebreaker, 'legacy',
                entry.session_id, entry.agent_id,
                lower(hex(
                    entry.entry_id || char(0) || entry.source_kind || char(0)
                    || entry.source_key || char(0) || entry.recorded_at || char(0)
                    || entry.kind || char(0) || COALESCE(entry.agent_id, '') || char(0)
                    || COALESCE(entry.task_id, '') || char(0) || entry.summary || char(0)
                    || entry.payload_json || char(0) || entry.sort_recorded_at || char(0)
                    || entry.sort_tiebreaker || char(0)
                    || COALESCE(provenance.member_id, '')
                ))
         FROM session_timeline_entries entry
         JOIN agent_workspace_activity_sources source
           ON source.source_session_id = entry.session_id
          AND source.workspace_id = ?1 AND source.status = 'active'
         LEFT JOIN agent_workspace_member_provenance provenance
           ON provenance.workspace_id = source.workspace_id
          AND provenance.source_session_id = entry.session_id
          AND provenance.source_agent_id = entry.agent_id
         WHERE TRUE
         ON CONFLICT(workspace_id, source_kind, source_key) DO UPDATE SET
            entry_id = excluded.entry_id, owner_kind = excluded.owner_kind,
            owner_id = excluded.owner_id, recorded_at = excluded.recorded_at,
            kind = excluded.kind, member_id = excluded.member_id,
            legacy_task_id = excluded.legacy_task_id, summary = excluded.summary,
            payload_json = excluded.payload_json,
            sort_recorded_at = excluded.sort_recorded_at,
            sort_tiebreaker = excluded.sort_tiebreaker,
            source_agent_id = excluded.source_agent_id,
            source_digest = excluded.source_digest",
    )
    .bind(workspace_id)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("project durable agent timeline: {error}")))?;
    Ok(())
}

async fn finalize_reconciliation(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
    source_revision: i64,
) -> Result<(), CliError> {
    let digest = durable_digest(transaction, workspace_id).await?;
    let now = harness_workspace::workspace::utc_now();
    query(
        "UPDATE agent_workspace_timeline_state
         SET revision = revision + CASE WHEN integrity_hash <> ?2 THEN 1 ELSE 0 END,
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
    .bind(&digest)
    .bind(&now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("finalize durable agent timeline: {error}")))?;
    query(
        "UPDATE agent_workspace_activity_state
         SET reconciled_revision = ?2, shadow_digest = ?3, updated_at = ?4
         WHERE workspace_id = ?1",
    )
    .bind(workspace_id)
    .bind(source_revision)
    .bind(digest)
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("finalize durable agent activity: {error}")))?;
    Ok(())
}

pub(super) async fn durable_digest(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
) -> Result<String, CliError> {
    let rows = query_as::<_, DigestRow>(
        "SELECT 'signal' AS record_kind, member_id AS first_key,
                signal_id AS second_key, source_digest
         FROM agent_workspace_signals WHERE workspace_id = ?1
         UNION ALL
         SELECT 'conversation', member_id, stream_id || ':' || sequence, source_digest
         FROM agent_workspace_conversation_events WHERE workspace_id = ?1
         UNION ALL
         SELECT 'activity', member_id, '', source_digest
         FROM agent_workspace_activity_summaries WHERE workspace_id = ?1
         UNION ALL
         SELECT 'timeline', source_kind, source_key, source_digest
         FROM agent_workspace_timeline_entries WHERE workspace_id = ?1
         ORDER BY record_kind, first_key, second_key",
    )
    .bind(workspace_id)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load durable agent activity digest rows: {error}")))?;
    let mut hasher = Sha256::new();
    for row in rows {
        for field in [
            row.record_kind.as_str(),
            row.first_key.as_str(),
            row.second_key.as_str(),
            row.source_digest.as_str(),
        ] {
            hasher.update(field.len().to_be_bytes());
            hasher.update(field.as_bytes());
        }
    }
    Ok(hex::encode(hasher.finalize()))
}
