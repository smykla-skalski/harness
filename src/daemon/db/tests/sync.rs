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
