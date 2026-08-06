use super::*;
use crate::daemon::db::DaemonDbConversation;
use crate::daemon::db::{DaemonDbTimeline, DaemonDbTimelineHandle};

/// Regression coverage for the `TimelineDbSource` seam `harness_timeline`
/// reads through instead of depending on `DaemonDb` directly: builds a
/// session purely from `DaemonDb` writes, then checks the hybrid builder
/// produces the same entries the db-native ledger already recorded via the
/// same writes.
#[test]
fn hybrid_timeline_builder_matches_db_backed_resolution() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    let state = sample_session_state();
    db.sync_project(&project).expect("sync project");
    db.create_session_record(&project.project_id, &state)
        .expect("create session");

    db.append_log_entry(&SessionLogEntry {
        sequence: 1,
        recorded_at: "2026-04-03T12:00:00Z".into(),
        session_id: state.session_id.clone(),
        transition: crate::session::types::SessionTransition::SessionStarted {
            title: "test title".into(),
            context: "test".into(),
        },
        actor_id: Some("claude-leader".into()),
        reason: None,
    })
    .expect("append log entry");
    db.append_checkpoint(
        &state.session_id,
        &TaskCheckpoint {
            checkpoint_id: "checkpoint-1".into(),
            task_id: "task-1".into(),
            recorded_at: "2026-04-03T12:01:00Z".into(),
            actor_id: Some("claude-leader".into()),
            summary: "Investigating".into(),
            progress: 25,
        },
    )
    .expect("append checkpoint");
    let events = vec![sample_conversation_event(1, "ignored")];
    db.sync_conversation_events(&state.session_id, "claude-leader", "claude", &events)
        .expect("sync conversation events");

    let resolved = db
        .resolve_session(&state.session_id)
        .expect("resolve session")
        .expect("resolved session present");

    let hybrid_entries = daemon_timeline::session_timeline_from_resolved_with_db(
        &resolved,
        &DaemonDbTimelineHandle(&db),
    )
    .expect("hybrid timeline");
    let ledger_window = db
        .load_session_timeline_window(&state.session_id, &TimelineWindowRequest::default())
        .expect("load timeline window")
        .expect("timeline window present");
    let ledger_entries = ledger_window.entries.expect("ledger entries present");

    let hybrid_signature = hybrid_entries
        .iter()
        .map(|entry| (&entry.entry_id, &entry.kind, &entry.summary))
        .collect::<std::collections::BTreeSet<_>>();
    let ledger_signature = ledger_entries
        .iter()
        .map(|entry| (&entry.entry_id, &entry.kind, &entry.summary))
        .collect::<std::collections::BTreeSet<_>>();
    assert_eq!(hybrid_entries.len(), 3);
    assert_eq!(hybrid_signature, ledger_signature);
}
