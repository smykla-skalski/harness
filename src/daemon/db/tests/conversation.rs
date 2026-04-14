use super::*;

    #[test]
    fn sync_conversation_events_replaces_existing_rows() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let first = vec![
            sample_conversation_event(1, "first"),
            sample_conversation_event(2, "second"),
        ];
        db.sync_conversation_events("sess-test-1", "claude-leader", "claude", &first)
            .expect("first sync");

        let replacement = vec![
            sample_conversation_event(1, "updated"),
            sample_conversation_event(3, "third"),
        ];
        db.sync_conversation_events("sess-test-1", "claude-leader", "claude", &replacement)
            .expect("replacement sync");

        let count: i64 = db
            .conn
            .query_row(
                "SELECT COUNT(*) FROM conversation_events
                 WHERE session_id = ?1 AND agent_id = ?2",
                ["sess-test-1", "claude-leader"],
                |row| row.get(0),
            )
            .expect("count conversation events");
        assert_eq!(count, 2);

        let loaded = db
            .load_conversation_events("sess-test-1", "claude-leader")
            .expect("load events");
        assert_eq!(loaded.len(), 2);
        assert_eq!(loaded[0].sequence, 1);
        assert_eq!(loaded[1].sequence, 3);
        match &loaded[0].kind {
            ConversationEventKind::AssistantText { content } => assert_eq!(content, "updated"),
            other => panic!("unexpected event kind: {other:?}"),
        }

        db.sync_conversation_events("sess-test-1", "claude-leader", "claude", &[])
            .expect("clear events");
        let cleared_count: i64 = db
            .conn
            .query_row(
                "SELECT COUNT(*) FROM conversation_events
                 WHERE session_id = ?1 AND agent_id = ?2",
                ["sess-test-1", "claude-leader"],
                |row| row.get(0),
            )
            .expect("count cleared conversation events");
        assert_eq!(cleared_count, 0);
    }

    #[test]
    fn sync_conversation_events_only_bumps_revision_when_visible_rows_change() {
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = sample_project();
        db.sync_project(&project).expect("sync project");
        let state = sample_session_state();
        db.sync_session(&project.project_id, &state)
            .expect("sync session");

        let first = vec![ConversationEvent {
            kind: ConversationEventKind::Error {
                code: None,
                message: "first failure".into(),
                recoverable: true,
            },
            ..sample_conversation_event(1, "ignored")
        }];
        db.sync_conversation_events(&state.session_id, "claude-leader", "claude", &first)
            .expect("sync first events");

        let first_revision: i64 = db
            .conn
            .query_row(
                "SELECT revision
                 FROM session_timeline_state
                 WHERE session_id = ?1",
                [&state.session_id],
                |row| row.get(0),
            )
            .expect("load first revision");

        db.sync_conversation_events(&state.session_id, "claude-leader", "claude", &first)
            .expect("resync identical events");
        let unchanged_revision: i64 = db
            .conn
            .query_row(
                "SELECT revision
                 FROM session_timeline_state
                 WHERE session_id = ?1",
                [&state.session_id],
                |row| row.get(0),
            )
            .expect("load unchanged revision");
        assert_eq!(unchanged_revision, first_revision);

        let replacement = vec![ConversationEvent {
            kind: ConversationEventKind::Error {
                code: None,
                message: "replacement failure".into(),
                recoverable: true,
            },
            ..sample_conversation_event(1, "ignored")
        }];
        db.sync_conversation_events(&state.session_id, "claude-leader", "claude", &replacement)
            .expect("sync replacement events");

        let (replacement_revision, summary): (i64, String) = db
            .conn
            .query_row(
                "SELECT state.revision, entries.summary
                 FROM session_timeline_state AS state
                 JOIN session_timeline_entries AS entries
                   ON entries.session_id = state.session_id
                 WHERE state.session_id = ?1
                   AND entries.source_kind = 'conversation'
                   AND entries.source_key = 'conversation:claude-leader:1'",
                [&state.session_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("load replacement revision and summary");
        assert_eq!(replacement_revision, first_revision + 1);
        assert_eq!(summary, "claude-leader error: replacement failure");
    }

    #[test]
    fn clear_session_conversation_events_removes_rows_for_removed_agents() {
        let db = DaemonDb::open_in_memory().expect("open db");
        db.sync_conversation_events(
            "sess-test-1",
            "claude-leader",
            "claude",
            &[sample_conversation_event(1, "leader")],
        )
        .expect("sync leader events");

        let other_agent_events = vec![ConversationEvent {
            agent: "codex-worker".into(),
            ..sample_conversation_event(1, "worker")
        }];
        db.sync_conversation_events("sess-test-1", "codex-worker", "codex", &other_agent_events)
            .expect("sync worker events");

        clear_session_conversation_events(db.connection(), "sess-test-1")
            .expect("clear session events");
        db.sync_conversation_events(
            "sess-test-1",
            "claude-leader",
            "claude",
            &[sample_conversation_event(1, "leader")],
        )
        .expect("resync current agent");

        let total_count: i64 = db
            .conn
            .query_row(
                "SELECT COUNT(*) FROM conversation_events WHERE session_id = ?1",
                ["sess-test-1"],
                |row| row.get(0),
            )
            .expect("count session conversation events");
        assert_eq!(total_count, 1);

        let worker_count: i64 = db
            .conn
            .query_row(
                "SELECT COUNT(*) FROM conversation_events
                 WHERE session_id = ?1 AND agent_id = ?2",
                ["sess-test-1", "codex-worker"],
                |row| row.get(0),
            )
            .expect("count worker conversation events");
        assert_eq!(worker_count, 0);
    }

    #[test]
    fn prepare_agent_conversation_imports_and_activity_loads_each_agent_once() {
        use crate::agents::runtime::RuntimeCapabilities;
        use crate::session::types::{AgentRegistration, AgentStatus, SessionRole};

        let mut state = sample_session_state();
        state.agents.insert(
            "codex-worker".into(),
            AgentRegistration {
                agent_id: "codex-worker".into(),
                name: "Codex Worker".into(),
                runtime: "codex".into(),
                role: SessionRole::Worker,
                capabilities: vec!["general".into()],
                joined_at: "2026-04-03T12:01:00Z".into(),
                updated_at: "2026-04-03T12:05:30Z".into(),
                status: AgentStatus::Active,
                agent_session_id: Some("codex-session-1".into()),
                last_activity_at: Some("2026-04-03T12:05:30Z".into()),
                current_task_id: None,
                runtime_capabilities: RuntimeCapabilities::default(),
                persona: None,
            },
        );
        let session_id = state.session_id.clone();

        let mut calls = Vec::new();
        let (activities, conversation_events) = prepare_agent_conversation_imports_and_activity(
            &state,
            |agent_id, runtime, session_key| {
                calls.push((
                    agent_id.to_string(),
                    runtime.to_string(),
                    session_key.to_string(),
                ));
                let events = match agent_id {
                    "claude-leader" => vec![
                        ConversationEvent {
                            timestamp: Some("2026-04-03T12:00:01Z".into()),
                            sequence: 1,
                            kind: ConversationEventKind::ToolInvocation {
                                tool_name: "Read".into(),
                                category: "fs".into(),
                                input: serde_json::json!({"path": "README.md"}),
                                invocation_id: Some("call-1".into()),
                            },
                            agent: agent_id.to_string(),
                            session_id: session_id.clone(),
                        },
                        ConversationEvent {
                            timestamp: Some("2026-04-03T12:00:02Z".into()),
                            sequence: 2,
                            kind: ConversationEventKind::ToolResult {
                                tool_name: "Read".into(),
                                invocation_id: Some("call-1".into()),
                                output: serde_json::json!({"lines": 12}),
                                is_error: false,
                                duration_ms: Some(5),
                            },
                            agent: agent_id.to_string(),
                            session_id: session_id.clone(),
                        },
                    ],
                    "codex-worker" => vec![ConversationEvent {
                        timestamp: Some("2026-04-03T12:00:03Z".into()),
                        sequence: 1,
                        kind: ConversationEventKind::Error {
                            code: Some("tool_error".into()),
                            message: "boom".into(),
                            recoverable: true,
                        },
                        agent: agent_id.to_string(),
                        session_id: session_id.clone(),
                    }],
                    other => panic!("unexpected agent: {other}"),
                };
                Ok(events)
            },
        )
        .expect("prepare conversation imports");

        assert_eq!(
            calls,
            vec![
                (
                    "claude-leader".to_string(),
                    "claude".to_string(),
                    "claude-session-1".to_string(),
                ),
                (
                    "codex-worker".to_string(),
                    "codex".to_string(),
                    "codex-session-1".to_string(),
                ),
            ]
        );
        assert_eq!(conversation_events.len(), 2);
        assert_eq!(conversation_events[0].events.len(), 2);
        assert_eq!(conversation_events[1].events.len(), 1);
        assert_eq!(activities.len(), 2);
        assert_eq!(activities[0].agent_id, "claude-leader");
        assert_eq!(activities[0].tool_invocation_count, 1);
        assert_eq!(activities[0].tool_result_count, 1);
        assert_eq!(activities[0].tool_error_count, 0);
        assert_eq!(activities[0].latest_tool_name.as_deref(), Some("Read"));
        assert_eq!(activities[1].agent_id, "codex-worker");
        assert_eq!(activities[1].tool_invocation_count, 0);
        assert_eq!(activities[1].tool_result_count, 0);
        assert_eq!(activities[1].tool_error_count, 1);
    }
