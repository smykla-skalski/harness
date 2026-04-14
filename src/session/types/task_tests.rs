use super::test_support::work_item;
use super::{
    TaskCheckpoint, TaskCheckpointSummary, TaskQueuePolicy, TaskSeverity, TaskSource, TaskStatus,
    WorkItem,
};

#[test]
fn work_item_serde_round_trip() {
    let mut item = work_item("task-1", "fix bug", TaskSeverity::High, TaskStatus::Open);
    item.context = Some("details here".into());
    item.created_by = Some("agent-1".into());
    item.suggested_fix = Some("check the failing watch path".into());

    let json = serde_json::to_string(&item).expect("serializes");
    let parsed: WorkItem = serde_json::from_str(&json).expect("deserializes");
    assert_eq!(parsed.task_id, "task-1");
    assert_eq!(parsed.severity, TaskSeverity::High);
    assert_eq!(
        parsed.suggested_fix.as_deref(),
        Some("check the failing watch path")
    );
}

#[test]
fn task_checkpoint_summary_copies_checkpoint_fields() {
    let checkpoint = TaskCheckpoint {
        checkpoint_id: "cp-1".into(),
        task_id: "task-1".into(),
        recorded_at: "2026-03-28T12:02:00Z".into(),
        actor_id: Some("leader".into()),
        summary: "Split complete".into(),
        progress: 80,
    };

    let summary = TaskCheckpointSummary::from(&checkpoint);
    assert_eq!(summary.checkpoint_id, "cp-1");
    assert_eq!(summary.actor_id.as_deref(), Some("leader"));
    assert_eq!(summary.progress, 80);
}

#[test]
fn task_queue_policy_serialization_skips_default_policy() {
    let mut item = work_item("task-1", "fix bug", TaskSeverity::Low, TaskStatus::Open);
    let json = serde_json::to_string(&item).expect("serializes");
    assert!(
        !json.contains("queue_policy"),
        "default queue policy is omitted"
    );

    item.queue_policy = TaskQueuePolicy::ReassignWhenFree;
    item.source = TaskSource::Observe;
    let json = serde_json::to_string(&item).expect("serializes");
    assert!(json.contains("reassign_when_free"));
    assert!(json.contains("observe"));
}
