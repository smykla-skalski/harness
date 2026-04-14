use temp_env::with_vars;
use tempfile::tempdir;

use super::super::super::{db::DaemonDb, index};
use super::super::{
    TimelinePayloadScope, checkpoint_entry, conversation_entry, log_entry_timeline_entry,
    session_timeline, session_timeline_from_resolved, session_timeline_from_resolved_with_db,
};
use super::support::{context_root, write_standard_timeline_fixture};

#[test]
fn timeline_round_trip_smoke_covers_public_surface() {
    let tmp = tempdir().expect("tempdir");
    with_vars(
        [(
            "XDG_DATA_HOME",
            Some(tmp.path().to_str().expect("utf8 path")),
        )],
        || {
            let context_root = context_root(tmp.path());
            let session_id = "sess-round-trip";
            let fixture = write_standard_timeline_fixture(&context_root, session_id);

            let file_entries = session_timeline(session_id).expect("timeline");
            let resolved = index::resolve_session(session_id).expect("resolve session");
            let resolved_entries =
                session_timeline_from_resolved(&resolved).expect("resolved timeline");
            let db = DaemonDb::open_in_memory().expect("open db");
            db.sync_project(&resolved.project).expect("sync project");
            db.sync_session(&resolved.project.project_id, &resolved.state)
                .expect("sync session");
            db.append_log_entry(&fixture.log_entry).expect("append log");
            db.append_log_entry(&fixture.signal_sent)
                .expect("append signal log");
            db.append_checkpoint(session_id, &fixture.checkpoint)
                .expect("append checkpoint");
            db.sync_conversation_events(
                &resolved.state.session_id,
                "codex-worker",
                "codex",
                &fixture.db_events,
            )
            .expect("sync conversation events");
            let db_entries =
                session_timeline_from_resolved_with_db(&resolved, &db).expect("db timeline");

            assert_eq!(file_entries.len(), 7);
            let file_signature = file_entries
                .iter()
                .map(|entry| (&entry.kind, &entry.summary))
                .collect::<Vec<_>>();
            assert_eq!(
                resolved_entries
                    .iter()
                    .map(|entry| (&entry.kind, &entry.summary))
                    .collect::<Vec<_>>(),
                file_signature
            );
            assert_eq!(
                db_entries
                    .iter()
                    .map(|entry| (&entry.kind, &entry.summary))
                    .collect::<Vec<_>>(),
                file_signature
            );

            let standalone_log =
                log_entry_timeline_entry(&fixture.log_entry, TimelinePayloadScope::Full)
                    .expect("log entry converts");
            assert_eq!(standalone_log.kind, "task_created");
            let standalone_checkpoint =
                checkpoint_entry(session_id, &fixture.checkpoint, TimelinePayloadScope::Full)
                    .expect("checkpoint converts");
            assert_eq!(standalone_checkpoint.kind, "task_checkpoint");
            let standalone_conversation = conversation_entry(
                session_id,
                "codex-worker",
                "codex",
                &fixture.db_events[0],
                TimelinePayloadScope::Full,
            )
            .expect("conversation entry converts")
            .expect("conversation entry emitted");
            assert_eq!(standalone_conversation.kind, "tool_invocation");
        },
    );
}

#[test]
fn session_timeline_merges_log_checkpoint_signal_and_observer_entries() {
    let tmp = tempdir().expect("tempdir");
    with_vars(
        [(
            "XDG_DATA_HOME",
            Some(tmp.path().to_str().expect("utf8 path")),
        )],
        || {
            let context_root = context_root(tmp.path());
            let session_id = "sess-merge";
            write_standard_timeline_fixture(&context_root, session_id);

            let entries = session_timeline(session_id).expect("timeline");
            assert_eq!(entries.len(), 7);
            assert_eq!(entries[0].kind, "task_checkpoint");
            assert_eq!(
                entries[0].summary,
                "Checkpoint 70%: timeline rows are live-backed"
            );
            assert_eq!(entries[1].kind, "tool_result");
            assert_eq!(
                entries[1].summary,
                "codex-worker received a result from Read"
            );
            assert_eq!(entries[2].kind, "tool_invocation");
            assert_eq!(entries[2].summary, "codex-worker invoked Read");
            assert_eq!(entries[3].kind, "observe_snapshot");
            assert_eq!(
                entries[3].summary,
                "Observe scan: 1 open, 1 active workers, 1 muted codes"
            );
            assert_eq!(entries[4].kind, "signal_acknowledged");
            assert_eq!(
                entries[4].summary,
                "sig-acked delivered to codex-worker: Accepted (inject_context)"
            );
            assert_eq!(entries[5].kind, "signal_sent");
            assert_eq!(entries[6].kind, "task_created");
        },
    );
}
