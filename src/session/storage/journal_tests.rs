use crate::session::types::{SessionTransition, TaskCheckpoint};

use super::journal::{
    append_log_entry, append_task_checkpoint, load_log_entries, load_task_checkpoints,
};

#[test]
fn append_and_load_log_entries() {
    let tmp = tempfile::tempdir().expect("tempdir");
    temp_env::with_vars(
        [
            (
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            ),
            ("CLAUDE_SESSION_ID", Some("test-log")),
        ],
        || {
            let project = tmp.path().join("project");
            append_log_entry(
                &project,
                "sess-1",
                SessionTransition::SessionStarted {
                    title: "test title".into(),
                    context: "test".into(),
                },
                Some("leader"),
                None,
            )
            .expect("append started");
            append_log_entry(
                &project,
                "sess-1",
                SessionTransition::SessionEnded,
                Some("leader"),
                None,
            )
            .expect("append ended");

            let entries = load_log_entries(&project, "sess-1").expect("load log");
            assert_eq!(entries.len(), 2);
            assert_eq!(entries[1].sequence, 2);
        },
    );
}

#[test]
fn checkpoint_round_trip_is_append_only() {
    let tmp = tempfile::tempdir().expect("tempdir");
    temp_env::with_vars(
        [
            (
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            ),
            ("CLAUDE_SESSION_ID", Some("test-checkpoints")),
        ],
        || {
            let project = tmp.path().join("project");
            let checkpoint = TaskCheckpoint {
                checkpoint_id: "task-1-cp-1".into(),
                task_id: "task-1".into(),
                recorded_at: "2026-03-28T12:00:00Z".into(),
                actor_id: Some("claude-leader".into()),
                summary: "watch attached".into(),
                progress: 40,
            };
            append_task_checkpoint(&project, "sess-1", "task-1", &checkpoint)
                .expect("append checkpoint");
            let checkpoints = load_task_checkpoints(&project, "sess-1", "task-1").expect("load");
            assert_eq!(checkpoints.len(), 1);
            assert_eq!(checkpoints[0].progress, 40);
        },
    );
}
