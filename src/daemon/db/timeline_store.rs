use super::*;

pub(super) fn replace_all_session_timeline_entries(
    conn: &Connection,
    session_id: &str,
    entries: &[StoredTimelineEntry],
) -> Result<(), CliError> {
    let (current_revision, current_hash, current_count): (i64, String, usize) = conn
        .query_row(
            "SELECT revision, integrity_hash, entry_count
             FROM session_timeline_state
             WHERE session_id = ?1",
            [session_id],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get::<_, i64>(2).map(usize_from_i64)?,
                ))
            },
        )
        .optional()
        .map_err(|error| db_error(format!("load timeline state for replace: {error}")))?
        .unwrap_or((0, String::new(), 0));
    let next_hash = timeline_integrity_hash(entries);
    if current_hash == next_hash && current_count == entries.len() {
        return Ok(());
    }

    let transaction = conn
        .unchecked_transaction()
        .map_err(|error| db_error(format!("begin timeline replace transaction: {error}")))?;
    transaction
        .execute(
            "DELETE FROM session_timeline_entries WHERE session_id = ?1",
            [session_id],
        )
        .map_err(|error| db_error(format!("clear timeline entries: {error}")))?;
    insert_session_timeline_entries(&transaction, entries)?;
    persist_session_timeline_state(
        &transaction,
        session_id,
        current_revision + 1,
        Some(next_hash),
    )?;
    transaction
        .commit()
        .map_err(|error| db_error(format!("commit timeline replace transaction: {error}")))?;
    Ok(())
}

pub(super) fn upsert_session_timeline_entry(
    transaction: &Connection,
    entry: &StoredTimelineEntry,
) -> Result<(), CliError> {
    let existing = load_timeline_entries_for_source_key(
        transaction,
        &entry.session_id,
        &entry.source_kind,
        &entry.source_key,
    )?;
    if existing.len() == 1 && existing[0] == *entry {
        return Ok(());
    }

    transaction
        .execute(
            "INSERT INTO session_timeline_entries (
                session_id, entry_id, source_kind, source_key, recorded_at, kind,
                agent_id, task_id, summary, payload_json, sort_recorded_at, sort_tiebreaker
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
            ON CONFLICT(session_id, source_kind, source_key) DO UPDATE SET
                entry_id = excluded.entry_id,
                recorded_at = excluded.recorded_at,
                kind = excluded.kind,
                agent_id = excluded.agent_id,
                task_id = excluded.task_id,
                summary = excluded.summary,
                payload_json = excluded.payload_json,
                sort_recorded_at = excluded.sort_recorded_at,
                sort_tiebreaker = excluded.sort_tiebreaker",
            rusqlite::params![
                entry.session_id,
                entry.entry_id,
                entry.source_kind,
                entry.source_key,
                entry.recorded_at,
                entry.kind,
                entry.agent_id,
                entry.task_id,
                entry.summary,
                entry.payload_json,
                entry.sort_recorded_at,
                entry.sort_tiebreaker,
            ],
        )
        .map_err(|error| db_error(format!("upsert timeline entry: {error}")))?;
    let current_revision = load_session_timeline_revision(transaction, &entry.session_id)?;
    persist_session_timeline_state(transaction, &entry.session_id, current_revision + 1, None)
}

pub(super) fn replace_session_timeline_entries_for_prefix(
    transaction: &Connection,
    session_id: &str,
    source_kind: &str,
    source_prefix: &str,
    entries: &[StoredTimelineEntry],
) -> Result<(), CliError> {
    let existing = load_timeline_entries_for_source_prefix(
        transaction,
        session_id,
        source_kind,
        source_prefix,
    )?;
    if existing == entries {
        return Ok(());
    }

    transaction
        .execute(
            "DELETE FROM session_timeline_entries
             WHERE session_id = ?1
               AND source_kind = ?2
               AND source_key LIKE ?3",
            rusqlite::params![session_id, source_kind, format!("{source_prefix}%")],
        )
        .map_err(|error| db_error(format!("delete timeline source entries: {error}")))?;
    insert_session_timeline_entries(transaction, entries)?;
    let current_revision = load_session_timeline_revision(transaction, session_id)?;
    persist_session_timeline_state(transaction, session_id, current_revision + 1, None)
}

fn insert_session_timeline_entries(
    transaction: &Connection,
    entries: &[StoredTimelineEntry],
) -> Result<(), CliError> {
    let mut statement = transaction
        .prepare(
            "INSERT INTO session_timeline_entries (
                session_id, entry_id, source_kind, source_key, recorded_at, kind,
                agent_id, task_id, summary, payload_json, sort_recorded_at, sort_tiebreaker
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
        )
        .map_err(|error| db_error(format!("prepare timeline insert: {error}")))?;
    for entry in entries {
        statement
            .execute(rusqlite::params![
                entry.session_id,
                entry.entry_id,
                entry.source_kind,
                entry.source_key,
                entry.recorded_at,
                entry.kind,
                entry.agent_id,
                entry.task_id,
                entry.summary,
                entry.payload_json,
                entry.sort_recorded_at,
                entry.sort_tiebreaker,
            ])
            .map_err(|error| db_error(format!("insert timeline entry: {error}")))?;
    }
    Ok(())
}

fn load_timeline_entries_for_source_prefix(
    conn: &Connection,
    session_id: &str,
    source_kind: &str,
    source_prefix: &str,
) -> Result<Vec<StoredTimelineEntry>, CliError> {
    let mut statement = conn
        .prepare(
            "SELECT session_id, entry_id, source_kind, source_key, recorded_at, kind,
                    agent_id, task_id, summary, payload_json, sort_recorded_at, sort_tiebreaker
             FROM session_timeline_entries
             WHERE session_id = ?1
               AND source_kind = ?2
               AND source_key LIKE ?3
             ORDER BY source_key",
        )
        .map_err(|error| db_error(format!("prepare timeline source load: {error}")))?;
    let rows = statement
        .query_map(
            rusqlite::params![session_id, source_kind, format!("{source_prefix}%")],
            stored_timeline_entry_from_row,
        )
        .map_err(|error| db_error(format!("query timeline source load: {error}")))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|error| db_error(format!("read timeline source row: {error}")))
}

fn load_timeline_entries_for_source_key(
    conn: &Connection,
    session_id: &str,
    source_kind: &str,
    source_key: &str,
) -> Result<Vec<StoredTimelineEntry>, CliError> {
    let mut statement = conn
        .prepare(
            "SELECT session_id, entry_id, source_kind, source_key, recorded_at, kind,
                    agent_id, task_id, summary, payload_json, sort_recorded_at, sort_tiebreaker
             FROM session_timeline_entries
             WHERE session_id = ?1
               AND source_kind = ?2
               AND source_key = ?3",
        )
        .map_err(|error| db_error(format!("prepare timeline source key load: {error}")))?;
    let rows = statement
        .query_map(
            rusqlite::params![session_id, source_kind, source_key],
            stored_timeline_entry_from_row,
        )
        .map_err(|error| db_error(format!("query timeline source key load: {error}")))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|error| db_error(format!("read timeline source key row: {error}")))
}

fn load_session_timeline_revision(conn: &Connection, session_id: &str) -> Result<i64, CliError> {
    conn.query_row(
        "SELECT revision FROM session_timeline_state WHERE session_id = ?1",
        [session_id],
        |row| row.get(0),
    )
    .optional()
    .map_err(|error| db_error(format!("load session timeline revision: {error}")))?
    .map_or(Ok(0), Ok)
}

fn persist_session_timeline_state(
    transaction: &Connection,
    session_id: &str,
    revision: i64,
    integrity_hash: Option<String>,
) -> Result<(), CliError> {
    let entries = load_all_session_timeline_entries(transaction, session_id)?;
    let integrity_hash = integrity_hash.unwrap_or_else(|| timeline_integrity_hash(&entries));
    let entry_count = entries.len();
    let newest_recorded_at = entries.first().map(|entry| entry.recorded_at.clone());
    let oldest_recorded_at = entries.last().map(|entry| entry.recorded_at.clone());

    transaction
        .execute(
            "INSERT INTO session_timeline_state (
                session_id, revision, entry_count, newest_recorded_at,
                oldest_recorded_at, integrity_hash, updated_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            ON CONFLICT(session_id) DO UPDATE SET
                revision = excluded.revision,
                entry_count = excluded.entry_count,
                newest_recorded_at = excluded.newest_recorded_at,
                oldest_recorded_at = excluded.oldest_recorded_at,
                integrity_hash = excluded.integrity_hash,
                updated_at = excluded.updated_at",
            rusqlite::params![
                session_id,
                revision,
                i64::try_from(entry_count).unwrap_or(i64::MAX),
                newest_recorded_at,
                oldest_recorded_at,
                integrity_hash,
                utc_now(),
            ],
        )
        .map_err(|error| db_error(format!("persist session timeline state: {error}")))?;
    Ok(())
}

fn load_all_session_timeline_entries(
    conn: &Connection,
    session_id: &str,
) -> Result<Vec<StoredTimelineEntry>, CliError> {
    let mut statement = conn
        .prepare(
            "SELECT session_id, entry_id, source_kind, source_key, recorded_at, kind,
                    agent_id, task_id, summary, payload_json, sort_recorded_at, sort_tiebreaker
             FROM session_timeline_entries
             WHERE session_id = ?1
             ORDER BY sort_recorded_at DESC, sort_tiebreaker DESC",
        )
        .map_err(|error| db_error(format!("prepare timeline load: {error}")))?;
    let rows = statement
        .query_map([session_id], stored_timeline_entry_from_row)
        .map_err(|error| db_error(format!("query timeline load: {error}")))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|error| db_error(format!("read timeline row: {error}")))
}

fn timeline_integrity_hash(entries: &[StoredTimelineEntry]) -> String {
    let mut ordered = entries.to_vec();
    ordered.sort_by(|left, right| {
        right
            .sort_recorded_at
            .cmp(&left.sort_recorded_at)
            .then_with(|| right.sort_tiebreaker.cmp(&left.sort_tiebreaker))
    });
    let mut hasher = Sha256::new();
    for entry in ordered {
        hasher.update(entry.session_id.as_bytes());
        hasher.update(b"\n");
        hasher.update(entry.entry_id.as_bytes());
        hasher.update(b"\n");
        hasher.update(entry.source_kind.as_bytes());
        hasher.update(b"\n");
        hasher.update(entry.source_key.as_bytes());
        hasher.update(b"\n");
        hasher.update(entry.recorded_at.as_bytes());
        hasher.update(b"\n");
        hasher.update(entry.kind.as_bytes());
        hasher.update(b"\n");
        hasher.update(entry.agent_id.as_deref().unwrap_or("").as_bytes());
        hasher.update(b"\n");
        hasher.update(entry.task_id.as_deref().unwrap_or("").as_bytes());
        hasher.update(b"\n");
        hasher.update(entry.summary.as_bytes());
        hasher.update(b"\n");
        hasher.update(entry.payload_json.as_bytes());
        hasher.update(b"\n");
    }
    hex::encode(hasher.finalize())
}
