use super::*;

#[test]
fn session_timeline_window_known_revision_reloads_when_visible_rows_change_without_count_change() {
    with_temp_project(|project| {
        use crate::session::service::build_new_session;

        let db = crate::daemon::db::DaemonDb::open_in_memory().expect("open in-memory db");
        let project_record = index::discovered_project_for_checkout(project);
        db.sync_project(&project_record).expect("sync project");
        let state = build_new_session(
            "db-only test",
            "",
            "db-only-sess",
            "claude",
            Some("test-session"),
            &utc_now(),
        );
        db.sync_session(&project_record.project_id, &state)
            .expect("sync session");
        let request = TimelineWindowRequest {
            scope: Some("summary".into()),
            limit: Some(20),
            ..TimelineWindowRequest::default()
        };

        let first = crate::agents::runtime::event::ConversationEvent {
            timestamp: Some("2026-04-14T10:00:00Z".into()),
            sequence: 1,
            kind: crate::agents::runtime::event::ConversationEventKind::Error {
                code: None,
                message: "first failure".into(),
                recoverable: true,
            },
            agent: "claude-leader".into(),
            session_id: state.session_id.clone(),
        };
        db.sync_conversation_events(&state.session_id, "claude-leader", "claude", &[first])
            .expect("sync first event");

        let initial = session_timeline_window(&state.session_id, &request, Some(&db))
            .expect("load initial window");
        assert_eq!(initial.total_count, 1);
        assert!(!initial.unchanged);
        let revision = initial.revision;

        let replacement = crate::agents::runtime::event::ConversationEvent {
            timestamp: Some("2026-04-14T10:00:00Z".into()),
            sequence: 1,
            kind: crate::agents::runtime::event::ConversationEventKind::Error {
                code: None,
                message: "replacement failure".into(),
                recoverable: true,
            },
            agent: "claude-leader".into(),
            session_id: state.session_id.clone(),
        };
        db.sync_conversation_events(&state.session_id, "claude-leader", "claude", &[replacement])
            .expect("sync replacement event");

        let refreshed = session_timeline_window(
            &state.session_id,
            &TimelineWindowRequest {
                known_revision: Some(revision),
                ..request.clone()
            },
            Some(&db),
        )
        .expect("load refreshed window");

        assert!(
            !refreshed.unchanged,
            "same-count timeline edits must not short-circuit as unchanged"
        );
        let entries = refreshed.entries.expect("entries");
        assert_eq!(entries.len(), 1);
        assert_eq!(
            entries[0].summary,
            "claude-leader error: replacement failure"
        );
    });
}

#[test]
fn build_timeline_window_response_keeps_latest_window_bounds_when_unchanged() {
    let entries = vec![
        TimelineEntry {
            entry_id: "entry-3".into(),
            recorded_at: "2026-04-14T10:02:00Z".into(),
            kind: "tool_result".into(),
            session_id: "sess-test-1".into(),
            agent_id: Some("agent-1".into()),
            task_id: None,
            summary: "third".into(),
            payload: serde_json::json!({}),
        },
        TimelineEntry {
            entry_id: "entry-2".into(),
            recorded_at: "2026-04-14T10:01:00Z".into(),
            kind: "tool_result".into(),
            session_id: "sess-test-1".into(),
            agent_id: Some("agent-1".into()),
            task_id: None,
            summary: "second".into(),
            payload: serde_json::json!({}),
        },
        TimelineEntry {
            entry_id: "entry-1".into(),
            recorded_at: "2026-04-14T10:00:00Z".into(),
            kind: "tool_result".into(),
            session_id: "sess-test-1".into(),
            agent_id: Some("agent-1".into()),
            task_id: None,
            summary: "first".into(),
            payload: serde_json::json!({}),
        },
    ];

    let response = build_timeline_window_response(
        &entries,
        &TimelineWindowRequest {
            scope: Some("summary".into()),
            limit: Some(2),
            before: None,
            after: None,
            known_revision: Some(3),
        },
    )
    .expect("build unchanged window");

    assert!(response.unchanged);
    assert_eq!(response.window_start, 0);
    assert_eq!(response.window_end, 2);
    assert!(response.has_older);
    assert!(!response.has_newer);
    assert_eq!(
        response.newest_cursor,
        Some(TimelineCursor {
            recorded_at: "2026-04-14T10:02:00Z".into(),
            entry_id: "entry-3".into(),
        })
    );
    assert_eq!(
        response.oldest_cursor,
        Some(TimelineCursor {
            recorded_at: "2026-04-14T10:01:00Z".into(),
            entry_id: "entry-2".into(),
        })
    );
    assert!(response.entries.is_none());
}
