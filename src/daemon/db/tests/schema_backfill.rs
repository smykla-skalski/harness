use super::*;
use crate::session::types::CURRENT_VERSION;
use serde_json::json;

#[test]
fn migrates_v6_schema_backfills_timeline_from_session_log() {
    use crate::session::types::SessionTransition;

    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("harness.db");

    let session_id = {
        let db = DaemonDb::open(&path).expect("open fresh db");
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
                title: "legacy title".into(),
                context: "legacy context".into(),
            },
            actor_id: Some("claude-leader".into()),
            reason: None,
        };
        db.append_log_entry(&entry).expect("append log entry");

        simulate_pre_v7_timeline_state(&db.conn);
        state.session_id
    };

    let db = DaemonDb::open(&path).expect("open migrated db");
    assert_eq!(db.schema_version().expect("version"), SCHEMA_VERSION);

    let (revision, entry_count): (i64, i64) = db
        .conn
        .query_row(
            "SELECT revision, entry_count FROM session_timeline_state WHERE session_id = ?1",
            [&session_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("timeline state row");
    assert_eq!(entry_count, 1, "session_log entry should be backfilled");
    assert!(
        revision > 0,
        "revision must advance when entries are backfilled"
    );

    let entries_count: i64 = db
        .conn
        .query_row(
            "SELECT COUNT(*) FROM session_timeline_entries WHERE session_id = ?1",
            [&session_id],
            |row| row.get(0),
        )
        .expect("count timeline entries");
    assert_eq!(entries_count, 1);

    let summary: String = db
        .conn
        .query_row(
            "SELECT summary FROM session_timeline_entries
                 WHERE session_id = ?1 AND source_kind = 'log'",
            [&session_id],
            |row| row.get(0),
        )
        .expect("load backfilled log summary");
    assert_eq!(summary, "Session started: legacy title - legacy context");
}

#[test]
fn migrates_v6_schema_backfills_timeline_from_conversation_events() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("harness.db");

    let session_id = {
        let db = DaemonDb::open(&path).expect("open fresh db");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");
        let state = sample_session_state();
        db.sync_session(&project.project_id, &state)
            .expect("sync session");

        let events = (1..=5)
            .map(|sequence| ConversationEvent {
                kind: ConversationEventKind::ToolInvocation {
                    tool_name: "Read".into(),
                    category: "read".into(),
                    input: serde_json::json!({ "sequence": sequence }),
                    invocation_id: Some(format!("invocation-{sequence}")),
                },
                ..sample_conversation_event(sequence, "ignored")
            })
            .collect::<Vec<_>>();
        db.sync_conversation_events(&state.session_id, "claude-leader", "claude", &events)
            .expect("sync conversation events");

        simulate_pre_v7_timeline_state(&db.conn);
        state.session_id
    };

    let db = DaemonDb::open(&path).expect("open migrated db");
    assert_eq!(db.schema_version().expect("version"), SCHEMA_VERSION);

    let entry_count: i64 = db
        .conn
        .query_row(
            "SELECT entry_count FROM session_timeline_state WHERE session_id = ?1",
            [&session_id],
            |row| row.get(0),
        )
        .expect("timeline state row");
    assert_eq!(
        entry_count, 5,
        "conversation_events should be replayed into the ledger"
    );

    let conversation_rows: i64 = db
        .conn
        .query_row(
            "SELECT COUNT(*) FROM session_timeline_entries
                 WHERE session_id = ?1 AND source_kind = 'conversation'",
            [&session_id],
            |row| row.get(0),
        )
        .expect("count conversation rows");
    assert_eq!(conversation_rows, 5);
}

#[test]
fn migrates_v7_schema_backfills_stuck_timeline_ledger() {
    // Regression guard for the population that already ran the broken v6 -> v7
    // migration before the backfill landed: their DB is stamped v7 with empty
    // ledger rows even though source tables still hold conversation history.
    // Opening the DB must now detect the v7 stamp, run the backfill, and bump
    // to the next schema version so the ledger is coherent again.
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("harness.db");

    let session_id = {
        let db = DaemonDb::open(&path).expect("open fresh db");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");
        let state = sample_session_state();
        db.sync_session(&project.project_id, &state)
            .expect("sync session");

        let events = (1..=4)
            .map(|sequence| ConversationEvent {
                kind: ConversationEventKind::ToolInvocation {
                    tool_name: "Write".into(),
                    category: "write".into(),
                    input: serde_json::json!({ "sequence": sequence }),
                    invocation_id: Some(format!("write-{sequence}")),
                },
                ..sample_conversation_event(sequence, "ignored")
            })
            .collect::<Vec<_>>();
        db.sync_conversation_events(&state.session_id, "claude-leader", "claude", &events)
            .expect("sync conversation events");

        simulate_stuck_v7_timeline_state(&db.conn);
        state.session_id
    };

    let db = DaemonDb::open(&path).expect("open migrated db");
    assert_eq!(db.schema_version().expect("version"), SCHEMA_VERSION);

    let entry_count: i64 = db
        .conn
        .query_row(
            "SELECT entry_count FROM session_timeline_state WHERE session_id = ?1",
            [&session_id],
            |row| row.get(0),
        )
        .expect("timeline state row");
    assert_eq!(
        entry_count, 4,
        "stuck v7 ledger should be rebuilt from conversation_events on upgrade"
    );

    let conversation_rows: i64 = db
        .conn
        .query_row(
            "SELECT COUNT(*) FROM session_timeline_entries
                 WHERE session_id = ?1 AND source_kind = 'conversation'",
            [&session_id],
            |row| row.get(0),
        )
        .expect("count conversation rows");
    assert_eq!(conversation_rows, 4);
}

#[test]
fn migrates_v8_schema_repairs_active_sessions_without_leader() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("harness.db");

    let session_id = {
        let db = DaemonDb::open(&path).expect("open fresh db");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");
        let state = sample_session_state();
        db.sync_session(&project.project_id, &state)
            .expect("sync session");

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
                    json!({
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
                    .to_string(),
                    state.session_id.clone(),
                ],
            )
            .expect("corrupt active row");
        db.conn
            .execute(
                "UPDATE schema_meta SET value = '8' WHERE key = 'version'",
                [],
            )
            .expect("downgrade schema");
        state.session_id
    };

    let db = DaemonDb::open(&path).expect("open migrated db");
    assert_eq!(db.schema_version().expect("version"), SCHEMA_VERSION);

    let (stored_status, stored_leader_id, is_active, stored_state_json): (
        String,
        Option<String>,
        i64,
        String,
    ) = db
        .conn
        .query_row(
            "SELECT status, leader_id, is_active, state_json
                 FROM sessions
                WHERE session_id = ?1",
            [&session_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .expect("load repaired row");
    let repaired_state: SessionState =
        serde_json::from_str(&stored_state_json).expect("parse repaired state");
    assert_eq!(stored_status, "leaderless_degraded");
    assert!(stored_leader_id.is_none());
    assert_eq!(is_active, 0);
    assert_eq!(repaired_state.status, SessionStatus::LeaderlessDegraded);
    assert!(repaired_state.leader_id.is_none());
    assert_eq!(repaired_state.schema_version, CURRENT_VERSION);
}

fn simulate_pre_v7_timeline_state(conn: &Connection) {
    wipe_timeline_ledger(conn);
    conn.execute(
        "UPDATE schema_meta SET value = '6' WHERE key = 'version'",
        [],
    )
    .expect("downgrade schema");
}

fn simulate_stuck_v7_timeline_state(conn: &Connection) {
    wipe_timeline_ledger(conn);
    conn.execute(
        "UPDATE schema_meta SET value = '7' WHERE key = 'version'",
        [],
    )
    .expect("stamp schema as v7");
}

fn wipe_timeline_ledger(conn: &Connection) {
    conn.execute("DELETE FROM session_timeline_entries", [])
        .expect("clear timeline entries");
    conn.execute(
        "UPDATE session_timeline_state SET revision = 0, entry_count = 0,
             newest_recorded_at = NULL, oldest_recorded_at = NULL,
             integrity_hash = ''",
        [],
    )
    .expect("reset timeline state");
}
