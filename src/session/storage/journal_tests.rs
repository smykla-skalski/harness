use crate::session::types::{Review, ReviewVerdict, SessionTransition, TaskCheckpoint};
use crate::workspace::layout::SessionLayout;

use super::journal::{
    append_log_entry, append_review, append_task_checkpoint, load_log_entries, load_reviews,
    load_task_checkpoints,
};

fn layout(tmp: &std::path::Path, session_id: &str) -> SessionLayout {
    SessionLayout {
        sessions_root: tmp.join("sessions"),
        project_name: "demo".into(),
        session_id: session_id.to_string(),
    }
}

#[test]
fn append_and_load_log_entries() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let layout = layout(tmp.path(), "sess-1");
    fs_err::create_dir_all(layout.session_root()).expect("create session dir");

    append_log_entry(
        &layout,
        SessionTransition::SessionStarted {
            title: "test title".into(),
            context: "test".into(),
        },
        Some("leader"),
        None,
    )
    .expect("append started");
    append_log_entry(
        &layout,
        SessionTransition::SessionEnded,
        Some("leader"),
        None,
    )
    .expect("append ended");

    let entries = load_log_entries(&layout).expect("load log");
    assert_eq!(entries.len(), 2);
    assert_eq!(entries[1].sequence, 2);
}

#[test]
fn checkpoint_round_trip_is_append_only() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let layout = layout(tmp.path(), "sess-1");
    fs_err::create_dir_all(layout.session_root()).expect("create session dir");

    let checkpoint = TaskCheckpoint {
        checkpoint_id: "task-1-cp-1".into(),
        task_id: "task-1".into(),
        recorded_at: "2026-03-28T12:00:00Z".into(),
        actor_id: Some("claude-leader".into()),
        summary: "watch attached".into(),
        progress: 40,
    };
    append_task_checkpoint(&layout, "task-1", &checkpoint).expect("append checkpoint");
    let checkpoints = load_task_checkpoints(&layout, "task-1").expect("load");
    assert_eq!(checkpoints.len(), 1);
    assert_eq!(checkpoints[0].progress, 40);
}

#[test]
fn append_review_is_idempotent_on_review_id() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let layout = layout(tmp.path(), "sess-rev");
    fs_err::create_dir_all(layout.session_root()).expect("create session dir");

    let review = Review {
        review_id: "rev-1".into(),
        round: 1,
        reviewer_agent_id: "rev-claude".into(),
        reviewer_runtime: "claude".into(),
        verdict: ReviewVerdict::Approve,
        summary: "LGTM".into(),
        points: Vec::new(),
        recorded_at: "2026-04-24T10:00:00Z".into(),
    };

    append_review(&layout, "task-1", &review).expect("first append");
    append_review(&layout, "task-1", &review).expect("idempotent replay");

    let loaded = load_reviews(&layout, "task-1").expect("load reviews");
    assert_eq!(loaded.len(), 1);
    assert_eq!(loaded[0].review_id, "rev-1");

    let review2 = Review {
        review_id: "rev-2".into(),
        round: 1,
        reviewer_agent_id: "rev-codex".into(),
        reviewer_runtime: "codex".into(),
        verdict: ReviewVerdict::RequestChanges,
        summary: "fix tests".into(),
        points: Vec::new(),
        recorded_at: "2026-04-24T10:05:00Z".into(),
    };
    append_review(&layout, "task-1", &review2).expect("second review");
    let loaded = load_reviews(&layout, "task-1").expect("load reviews");
    assert_eq!(loaded.len(), 2);
    assert_eq!(loaded[1].review_id, "rev-2");
}
