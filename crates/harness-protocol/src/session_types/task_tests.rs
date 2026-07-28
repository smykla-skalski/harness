use super::test_support::work_item;
use super::{
    Review, ReviewPoint, ReviewVerdict, TaskCheckpoint, TaskCheckpointSummary, TaskQueuePolicy,
    TaskSeverity, TaskSource, TaskStatus, WorkItem,
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
fn review_verdict_decodes_legacy_kebab_case_request_changes() {
    let snake: ReviewVerdict = serde_json::from_str("\"request_changes\"").expect("snake_case");
    assert_eq!(snake, ReviewVerdict::RequestChanges);

    let kebab: ReviewVerdict =
        serde_json::from_str("\"request-changes\"").expect("kebab alias must decode");
    assert_eq!(kebab, ReviewVerdict::RequestChanges);
}

#[test]
fn review_payload_decodes_with_legacy_kebab_verdict() {
    let payload = r#"{
        "review_id": "review-1",
        "round": 2,
        "reviewer_agent_id": "rev-1",
        "reviewer_runtime": "claude",
        "verdict": "request-changes",
        "summary": "needs rework",
        "points": [{"point_id": "p1", "text": "nit", "state": "disputed"}],
        "recorded_at": "2026-03-28T12:00:00Z"
    }"#;
    let review: Review = serde_json::from_str(payload).expect("decodes legacy verdict spelling");
    assert_eq!(review.verdict, ReviewVerdict::RequestChanges);
    assert_eq!(review.points.len(), 1);
    assert_eq!(review.points[0].point_id, "p1");
    let _point: ReviewPoint = review.points[0].clone();
}

#[test]
fn review_verdict_serializes_as_snake_case() {
    let json = serde_json::to_string(&ReviewVerdict::RequestChanges).expect("serializes");
    assert_eq!(json, "\"request_changes\"");
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
