use serde_json::json;

use crate::session::types::SessionMetrics;

use super::*;

#[test]
fn bump_change_advances_monotonic_sequence() {
    let db = DaemonDb::open_in_memory().expect("open db");
    db.bump_change("alpha").expect("first bump");
    db.bump_change("beta").expect("second bump");

    let alpha_seq: i64 = db
        .conn
        .query_row(
            "SELECT change_seq
                 FROM change_tracking
                 WHERE scope = 'session:alpha'",
            [],
            |row| row.get(0),
        )
        .expect("alpha change sequence");
    let beta_seq: i64 = db
        .conn
        .query_row(
            "SELECT change_seq
                 FROM change_tracking
                 WHERE scope = 'session:beta'",
            [],
            |row| row.get(0),
        )
        .expect("beta change sequence");
    let last_seq: i64 = db
        .conn
        .query_row(
            "SELECT last_seq
                 FROM change_tracking_state
                 WHERE singleton = 1",
            [],
            |row| row.get(0),
        )
        .expect("last change sequence");

    assert_eq!(alpha_seq, 1);
    assert_eq!(beta_seq, 2);
    assert_eq!(last_seq, 2);
}
#[test]
fn sync_session_with_agents_and_tasks() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");

    let state = sample_session_state();
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    let context: String = db
        .conn
        .query_row(
            "SELECT context FROM sessions WHERE session_id = ?1",
            [&state.session_id],
            |row| row.get(0),
        )
        .expect("query session");
    assert_eq!(context, "test session");

    let agent_count: i64 = db
        .conn
        .query_row(
            "SELECT COUNT(*) FROM agents WHERE session_id = ?1",
            [&state.session_id],
            |row| row.get(0),
        )
        .expect("count agents");
    assert_eq!(agent_count, 1);

    let task_count: i64 = db
        .conn
        .query_row(
            "SELECT COUNT(*) FROM tasks WHERE session_id = ?1",
            [&state.session_id],
            |row| row.get(0),
        )
        .expect("count tasks");
    assert_eq!(task_count, 1);
}

#[test]
fn sync_session_replaces_agents_on_update() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");

    let mut state = sample_session_state();
    db.sync_session(&project.project_id, &state)
        .expect("first sync");

    state.agents.clear();
    state.state_version = 2;
    db.sync_session(&project.project_id, &state)
        .expect("second sync");

    let agent_count: i64 = db
        .conn
        .query_row(
            "SELECT COUNT(*) FROM agents WHERE session_id = ?1",
            [&state.session_id],
            |row| row.get(0),
        )
        .expect("count agents");
    assert_eq!(agent_count, 0);
}

#[test]
fn sync_session_canonicalizes_active_sessions_without_leader() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");

    let mut state = sample_session_state();
    state.agents.clear();
    state.leader_id = None;
    state.status = SessionStatus::Active;
    state.metrics = SessionMetrics::recalculate(&state);
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    let (stored_status, stored_leader_id): (String, Option<String>) = db
        .conn
        .query_row(
            "SELECT status, leader_id
                 FROM sessions
                 WHERE session_id = ?1",
            [&state.session_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("query persisted session");
    assert_eq!(stored_status, "leaderless_degraded");
    assert!(stored_leader_id.is_none());

    let loaded = db
        .load_session_state(&state.session_id)
        .expect("load session")
        .expect("session present");
    assert_eq!(loaded.status, SessionStatus::LeaderlessDegraded);
    assert!(loaded.leader_id.is_none());
    assert_eq!(loaded.schema_version, crate::session::types::CURRENT_VERSION);

    let summaries = db.list_session_summaries_full().expect("session summaries");
    assert_eq!(summaries.len(), 1);
    assert_eq!(summaries[0].status, SessionStatus::LeaderlessDegraded);
    assert!(summaries[0].leader_id.is_none());
}

#[test]
fn list_session_summaries_repair_legacy_active_rows_and_state_payloads() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");

    let mut state = sample_session_state();
    state.agents.clear();
    state.leader_id = None;
    state.status = SessionStatus::Active;
    state.metrics = SessionMetrics::recalculate(&state);
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    let legacy_payload = json!({
        "schema_version": 6,
        "state_version": 1,
        "session_id": state.session_id.clone(),
        "title": state.title.clone(),
        "context": state.context.clone(),
        "status": "active",
        "created_at": state.created_at.clone(),
        "updated_at": state.updated_at.clone(),
        "agents": {},
        "tasks": {},
        "leader_id": null,
        "archived_at": null,
        "last_activity_at": state.last_activity_at.clone(),
        "observe_id": state.observe_id.clone(),
        "pending_leader_transfer": null,
        "metrics": {
            "agent_count": 0,
            "active_agent_count": 0,
            "idle_agent_count": 0,
            "open_task_count": 0,
            "in_progress_task_count": 0,
            "blocked_task_count": 0,
            "completed_task_count": 0
        }
    })
    .to_string();
    db.conn
        .execute(
            "UPDATE sessions
             SET status = 'active',
                 leader_id = NULL,
                 metrics_json = ?1,
                 state_json = ?2,
                 is_active = 1
             WHERE session_id = ?3",
            rusqlite::params![
                json!({
                    "agent_count": 0,
                    "active_agent_count": 0,
                    "idle_agent_count": 0,
                    "open_task_count": 0,
                    "in_progress_task_count": 0,
                    "blocked_task_count": 0,
                    "completed_task_count": 0
                })
                .to_string(),
                legacy_payload,
                state.session_id.clone(),
            ],
        )
        .expect("corrupt session row");

    let summaries = db.list_session_summaries_full().expect("session summaries");
    assert_eq!(summaries.len(), 1);
    assert_eq!(summaries[0].status, SessionStatus::LeaderlessDegraded);
    assert!(summaries[0].leader_id.is_none());

    let (stored_status, stored_state_json): (String, String) = db
        .conn
        .query_row(
            "SELECT status, state_json
                 FROM sessions
                WHERE session_id = ?1",
            [&state.session_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("load repaired row");
    let repaired_state: SessionState =
        serde_json::from_str(&stored_state_json).expect("parse repaired state");
    assert_eq!(stored_status, "leaderless_degraded");
    assert_eq!(repaired_state.status, SessionStatus::LeaderlessDegraded);
    assert!(repaired_state.leader_id.is_none());
    assert_eq!(repaired_state.schema_version, crate::session::types::CURRENT_VERSION);
}

#[test]
fn sync_session_preserves_leaderless_degraded_status_for_summaries() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");

    let mut state = sample_session_state();
    state.status = SessionStatus::LeaderlessDegraded;
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    let stored_status: String = db
        .conn
        .query_row(
            "SELECT status FROM sessions WHERE session_id = ?1",
            [&state.session_id],
            |row| row.get(0),
        )
        .expect("query status");
    assert_eq!(stored_status, "leaderless_degraded");

    let summaries = db.list_session_summaries_full().expect("session summaries");
    assert_eq!(summaries.len(), 1);
    assert_eq!(summaries[0].status, SessionStatus::LeaderlessDegraded);
}

#[test]
fn append_log_entry_inserts() {
    use crate::session::types::SessionTransition;

    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");
    let state = sample_session_state();
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    let entry = SessionLogEntry {
        sequence: 1,
        recorded_at: "2026-04-03T12:00:00Z".into(),
        session_id: state.session_id.clone(),
        transition: SessionTransition::SessionStarted {
            title: "test title".into(),
            context: "test".into(),
        },
        actor_id: Some("claude-leader".into()),
        reason: None,
    };
    db.append_log_entry(&entry).expect("append log entry");

    let count: i64 = db
        .conn
        .query_row(
            "SELECT COUNT(*) FROM session_log WHERE session_id = ?1",
            [&state.session_id],
            |row| row.get(0),
        )
        .expect("count log entries");
    assert_eq!(count, 1);
}

#[test]
fn append_log_entry_updates_session_timeline_revision_and_count() {
    use crate::session::types::SessionTransition;

    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");
    let state = sample_session_state();
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    let entry = SessionLogEntry {
        sequence: 1,
        recorded_at: "2026-04-03T12:00:00Z".into(),
        session_id: state.session_id.clone(),
        transition: SessionTransition::SessionStarted {
            title: "test title".into(),
            context: "test".into(),
        },
        actor_id: Some("claude-leader".into()),
        reason: None,
    };
    db.append_log_entry(&entry).expect("append log entry");

    let (revision, entry_count): (i64, i64) = db
        .conn
        .query_row(
            "SELECT revision, entry_count
                 FROM session_timeline_state
                 WHERE session_id = ?1",
            [&state.session_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("load timeline state");
    assert_eq!(revision, 1);
    assert_eq!(entry_count, 1);

    let summary: String = db
        .conn
        .query_row(
            "SELECT summary
                 FROM session_timeline_entries
                 WHERE session_id = ?1 AND source_kind = 'log' AND source_key = 'log:1'",
            [&state.session_id],
            |row| row.get(0),
        )
        .expect("load timeline summary");
    assert_eq!(summary, "Session started: test title - test");
}

#[test]
fn bump_change_increments() {
    let db = DaemonDb::open_in_memory().expect("open db");
    db.bump_change("global").expect("first bump");
    db.bump_change("global").expect("second bump");

    let version: i64 = db
        .conn
        .query_row(
            "SELECT version FROM change_tracking WHERE scope = 'global'",
            [],
            |row| row.get(0),
        )
        .expect("version");
    assert_eq!(version, 2);
}

#[test]
fn bump_change_creates_new_scope() {
    let db = DaemonDb::open_in_memory().expect("open db");
    db.bump_change("session:test-1").expect("bump");

    let version: i64 = db
        .conn
        .query_row(
            "SELECT version FROM change_tracking WHERE scope = 'session:test-1'",
            [],
            |row| row.get(0),
        )
        .expect("version");
    assert_eq!(version, 1);
}

#[test]
fn bump_change_normalizes_raw_session_scope() {
    let db = DaemonDb::open_in_memory().expect("open db");
    db.bump_change("test-1").expect("bump");

    let version: i64 = db
        .conn
        .query_row(
            "SELECT version FROM change_tracking WHERE scope = 'session:test-1'",
            [],
            |row| row.get(0),
        )
        .expect("version");
    assert_eq!(version, 1);
}

#[test]
fn append_daemon_event_inserts() {
    let db = DaemonDb::open_in_memory().expect("open db");
    db.append_daemon_event("info", "test message")
        .expect("append event");

    let count: i64 = db
        .conn
        .query_row("SELECT COUNT(*) FROM daemon_events", [], |row| row.get(0))
        .expect("count events");
    assert_eq!(count, 1);
}
