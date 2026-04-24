pub(super) const UPSERT_PROJECT_SQL: &str = "INSERT INTO projects (
    project_id, name, project_dir, repository_root, checkout_id,
    checkout_name, context_root, is_worktree, worktree_name,
    origin_json, discovered_at, updated_at
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?11)
ON CONFLICT(project_id) DO UPDATE SET
    name = excluded.name,
    project_dir = excluded.project_dir,
    repository_root = excluded.repository_root,
    checkout_id = excluded.checkout_id,
    checkout_name = excluded.checkout_name,
    context_root = excluded.context_root,
    is_worktree = excluded.is_worktree,
    worktree_name = excluded.worktree_name,
    origin_json = excluded.origin_json,
    updated_at = excluded.updated_at";

pub(super) const UPSERT_SESSION_SQL: &str = "INSERT INTO sessions (
    session_id, project_id, schema_version, state_version,
    title, context,
    status, leader_id, observe_id, created_at, updated_at,
    last_activity_at, archived_at, pending_leader_transfer,
    metrics_json, state_json, is_active
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)
ON CONFLICT(session_id) DO UPDATE SET
    schema_version = excluded.schema_version,
    state_version = excluded.state_version,
    title = excluded.title,
    context = excluded.context,
    status = excluded.status,
    leader_id = excluded.leader_id,
    observe_id = excluded.observe_id,
    updated_at = excluded.updated_at,
    last_activity_at = excluded.last_activity_at,
    archived_at = excluded.archived_at,
    pending_leader_transfer = excluded.pending_leader_transfer,
    metrics_json = excluded.metrics_json,
    state_json = excluded.state_json,
    is_active = excluded.is_active";

pub(super) const ENSURE_SESSION_TIMELINE_STATE_SQL: &str = "INSERT INTO session_timeline_state (
    session_id, revision, entry_count, newest_recorded_at,
    oldest_recorded_at, integrity_hash, updated_at
) VALUES (?1, 0, 0, NULL, NULL, '', ?2)
ON CONFLICT(session_id) DO NOTHING";

pub(super) const DELETE_SESSION_AGENTS_SQL: &str = "DELETE FROM agents WHERE session_id = ?1";

pub(super) const INSERT_AGENT_SQL: &str = "INSERT INTO agents (
    agent_id, session_id, name, runtime, role, capabilities_json,
    status, agent_session_id, joined_at, updated_at,
    last_activity_at, current_task_id, runtime_capabilities_json
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)";

pub(super) const DELETE_SESSION_TASKS_SQL: &str = "DELETE FROM tasks WHERE session_id = ?1";

pub(super) const INSERT_TASK_SQL: &str = "INSERT INTO tasks (
    task_id, session_id, title, context, severity, status,
    assigned_to, created_at, updated_at, created_by,
    suggested_fix, source, blocked_reason, completed_at,
    notes_json, checkpoint_summary_json,
    awaiting_review_queued_at, awaiting_review_submitter_agent_id,
    awaiting_review_required_consensus, review_round,
    review_claim_json, consensus_json, arbitration_json, suggested_persona
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16,
    ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24)";

pub(super) const INSERT_CHECKPOINT_SQL: &str = "INSERT OR IGNORE INTO task_checkpoints (
    checkpoint_id, task_id, session_id, recorded_at,
    actor_id, summary, progress
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)";

pub(super) const MARK_SESSION_ACTIVE_SQL: &str =
    "UPDATE sessions SET is_active = 1 WHERE session_id = ?1";

pub(super) const NEXT_LOG_SEQUENCE_SQL: &str =
    "SELECT COALESCE(MAX(sequence), 0) + 1 FROM session_log WHERE session_id = ?1";

pub(super) const INSERT_LOG_ENTRY_SQL: &str = "INSERT OR IGNORE INTO session_log (
    session_id, sequence, recorded_at, transition_kind,
    transition_json, actor_id, reason
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)";

pub(super) const UPSERT_TIMELINE_ENTRY_SQL: &str = "INSERT INTO session_timeline_entries (
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
    sort_tiebreaker = excluded.sort_tiebreaker";

pub(super) const UPSERT_TIMELINE_STATE_SQL: &str = "INSERT INTO session_timeline_state (
    session_id, revision, entry_count, newest_recorded_at,
    oldest_recorded_at, integrity_hash, updated_at
) VALUES (
    ?1,
    1,
    (SELECT COUNT(*) FROM session_timeline_entries WHERE session_id = ?1),
    (SELECT MAX(recorded_at) FROM session_timeline_entries WHERE session_id = ?1),
    (SELECT MIN(recorded_at) FROM session_timeline_entries WHERE session_id = ?1),
    '',
    ?2
)
ON CONFLICT(session_id) DO UPDATE SET
    revision = revision + 1,
    entry_count = (SELECT COUNT(*) FROM session_timeline_entries WHERE session_id = ?1),
    newest_recorded_at = (SELECT MAX(recorded_at) FROM session_timeline_entries WHERE session_id = ?1),
    oldest_recorded_at = (SELECT MIN(recorded_at) FROM session_timeline_entries WHERE session_id = ?1),
    updated_at = excluded.updated_at";

pub(super) const ADVANCE_CHANGE_SEQUENCE_SQL: &str = "
UPDATE change_tracking_state
SET last_seq = last_seq + 1
WHERE singleton = 1";

pub(super) const CURRENT_CHANGE_SEQUENCE_SQL: &str =
    "SELECT last_seq FROM change_tracking_state WHERE singleton = 1";

pub(super) const UPSERT_CHANGE_SQL: &str = "INSERT INTO change_tracking (
    scope, version, updated_at, change_seq
) VALUES (?1, 1, ?2, ?3)
ON CONFLICT(scope) DO UPDATE SET
    version = version + 1,
    updated_at = excluded.updated_at,
    change_seq = excluded.change_seq";

pub(super) const DELETE_SESSION_ROW_SQL: &str = "DELETE FROM sessions WHERE session_id = ?1";
