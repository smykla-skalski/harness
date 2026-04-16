use tempfile::tempdir;

use super::*;

#[tokio::test]
async fn load_session_timeline_window_reads_summary_scope_from_async_ledger() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let sync_db = DaemonDb::open(&db_path).expect("open sync daemon db");
    let project = sample_project();
    sync_db.sync_project(&project).expect("sync project");
    sync_db
        .save_session_state(&project.project_id, &sample_session_state())
        .expect("save session state");
    sync_db
        .sync_conversation_events(
            "sess-test-1",
            "claude-leader",
            "claude",
            &[sample_tool_result_event()],
        )
        .expect("sync conversation events");
    drop(sync_db);

    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("open async daemon db");
    let response = async_db
        .load_session_timeline_window(
            "sess-test-1",
            &TimelineWindowRequest {
                scope: Some("summary".into()),
                ..TimelineWindowRequest::default()
            },
        )
        .await
        .expect("load async timeline window")
        .expect("timeline window present");

    assert_eq!(response.revision, 1);
    assert_eq!(response.total_count, 1);
    assert_eq!(response.entries.as_ref().map(Vec::len), Some(1));
    assert_eq!(
        response
            .entries
            .as_ref()
            .and_then(|entries| entries.first())
            .map(|entry| entry.payload.clone()),
        Some(serde_json::json!({}))
    );
}

#[tokio::test]
async fn load_session_timeline_window_reports_unchanged_known_revision() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let sync_db = DaemonDb::open(&db_path).expect("open sync daemon db");
    let project = sample_project();
    sync_db.sync_project(&project).expect("sync project");
    sync_db
        .save_session_state(&project.project_id, &sample_session_state())
        .expect("save session state");
    sync_db
        .sync_conversation_events(
            "sess-test-1",
            "claude-leader",
            "claude",
            &[sample_tool_result_event()],
        )
        .expect("sync conversation events");
    drop(sync_db);

    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("open async daemon db");
    let response = async_db
        .load_session_timeline_window(
            "sess-test-1",
            &TimelineWindowRequest {
                known_revision: Some(1),
                ..TimelineWindowRequest::default()
            },
        )
        .await
        .expect("load async timeline window")
        .expect("timeline window present");

    assert!(response.unchanged);
    assert!(response.entries.is_none());
    assert_eq!(response.revision, 1);
    assert_eq!(response.total_count, 1);
}

#[tokio::test]
async fn list_session_summaries_preserves_leaderless_degraded_status() {
    let tmp = tempdir().expect("tempdir");
    let db_path = tmp.path().join("harness.db");
    let sync_db = DaemonDb::open(&db_path).expect("open sync daemon db");
    let project = sample_project();
    sync_db.sync_project(&project).expect("sync project");
    let mut state = sample_session_state();
    state.status = SessionStatus::LeaderlessDegraded;
    sync_db
        .save_session_state(&project.project_id, &state)
        .expect("save session state");
    drop(sync_db);

    let async_db = AsyncDaemonDb::connect(&db_path)
        .await
        .expect("open async daemon db");
    let summaries = async_db
        .list_session_summaries()
        .await
        .expect("load async session summaries");

    assert_eq!(summaries.len(), 1);
    assert_eq!(summaries[0].status, SessionStatus::LeaderlessDegraded);
}

fn sample_tool_result_event() -> crate::agents::runtime::event::ConversationEvent {
    let mut event = sample_conversation_event(1, "ignored");
    event.kind = ConversationEventKind::ToolResult {
        tool_name: "Bash".into(),
        invocation_id: Some("call-bash-1".into()),
        output: serde_json::json!({
            "stdout": "x".repeat(128),
            "exit_code": 0,
        }),
        is_error: false,
        duration_ms: Some(125),
    };
    event
}
