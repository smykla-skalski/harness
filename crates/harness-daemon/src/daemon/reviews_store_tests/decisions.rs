use tempfile::{TempDir, tempdir};

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::reviews_store::PolicyGraphQueries;
use crate::task_board::policy_graph::RecordedPolicyDecision;
use crate::task_board::{
    PolicyAction, PolicyDecision, PolicyEvidence, PolicyInput, PolicyReasonCode, PolicySubject,
};

async fn connect() -> (TempDir, AsyncDaemonDb) {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("connect async daemon db");
    (dir, db)
}

fn sample_record(revision: u64) -> RecordedPolicyDecision {
    let input = PolicyInput {
        workflow: Some("merge".to_owned()),
        action: PolicyAction::MergePr,
        subject: PolicySubject {
            repository: Some("octo/repo".to_owned()),
            pull_request: Some("42".to_owned()),
            ..PolicySubject::default()
        },
        evidence: PolicyEvidence {
            checks_green: Some(false),
            ..PolicyEvidence::default()
        },
        evaluated_at: None,
        approvals: Vec::new(),
    };
    let decision = PolicyDecision::Deny {
        reason_code: PolicyReasonCode::ChecksNotGreen,
        policy_version: "task-board-policy-v1".to_owned(),
    };
    RecordedPolicyDecision::new(
        revision,
        input,
        decision,
        vec!["node-1".to_owned()],
        "reviews_github",
    )
}

#[tokio::test]
async fn writer_persists_discrete_columns_and_json_payloads() {
    let (_dir, db) = connect().await;
    let record = sample_record(9);
    db.record_policy_decision_row(&record)
        .await
        .expect("record");

    let (action, revision, enforced, decision_tag, reason_code, source): (
        String,
        i64,
        i64,
        String,
        String,
        String,
    ) = sqlx::query_as(
        "SELECT action, revision, enforced, decision_tag, reason_code, source \
         FROM policy_decisions",
    )
    .fetch_one(db.pool())
    .await
    .expect("read decision row");
    assert_eq!(action, "merge_pr");
    assert_eq!(revision, 9);
    assert_eq!(enforced, 1);
    assert_eq!(decision_tag, "deny");
    assert_eq!(reason_code, "checks_not_green");
    assert_eq!(source, "reviews_github");

    let (subject_json, evidence_json, visited_json): (String, String, String) = sqlx::query_as(
        "SELECT subject_json, evidence_json, visited_node_ids_json FROM policy_decisions",
    )
    .fetch_one(db.pool())
    .await
    .expect("read decision payloads");
    let subject: PolicySubject = serde_json::from_str(&subject_json).expect("subject");
    assert_eq!(subject, record.input.subject);
    let evidence: PolicyEvidence = serde_json::from_str(&evidence_json).expect("evidence");
    assert_eq!(evidence, record.input.evidence);
    let visited: Vec<String> = serde_json::from_str(&visited_json).expect("visited");
    assert_eq!(visited, vec!["node-1".to_owned()]);
}

#[tokio::test]
async fn writer_appends_distinct_rows() {
    let (_dir, db) = connect().await;
    for revision in 0..3 {
        db.record_policy_decision_row(&sample_record(revision))
            .await
            .expect("record");
    }
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM policy_decisions")
        .fetch_one(db.pool())
        .await
        .expect("count");
    assert_eq!(count, 3);
}

#[tokio::test]
async fn writer_round_trips_canvas_id() {
    let (_dir, db) = connect().await;
    let record = sample_record(1).with_canvas_id(Some("canvas-xyz".to_owned()));
    db.record_policy_decision_row(&record)
        .await
        .expect("record");
    let read = db
        .recent_policy_decisions_for_canvas("canvas-xyz", 1)
        .await
        .expect("read");
    assert_eq!(read[0].canvas_id.as_deref(), Some("canvas-xyz"));
}

#[tokio::test]
async fn reader_scopes_to_canvas_and_keeps_legacy_null() {
    let (_dir, db) = connect().await;
    let mut from_a = sample_record(1);
    from_a.id = "decision-a".to_owned();
    from_a.canvas_id = Some("canvas-a".to_owned());
    let mut from_b = sample_record(2);
    from_b.id = "decision-b".to_owned();
    from_b.canvas_id = Some("canvas-b".to_owned());
    let mut legacy = sample_record(3);
    legacy.id = "decision-legacy".to_owned();
    legacy.canvas_id = None;
    for record in [&from_a, &from_b, &legacy] {
        db.record_policy_decision_row(record).await.expect("record");
    }

    let scoped = db
        .recent_policy_decisions_for_canvas("canvas-a", 10)
        .await
        .expect("scoped read");
    let mut ids: Vec<&str> = scoped.iter().map(|record| record.id.as_str()).collect();
    ids.sort_unstable();
    assert_eq!(
        ids,
        vec!["decision-a", "decision-legacy"],
        "replay feed must keep this canvas and legacy rows, exclude other canvases"
    );
}

#[tokio::test]
async fn reader_round_trips_records_and_honors_limit() {
    let (_dir, db) = connect().await;
    for revision in 0..3 {
        db.record_policy_decision_row(&sample_record(revision))
            .await
            .expect("record");
    }

    let all = db
        .recent_policy_decisions_for_canvas("canvas-test", 10)
        .await
        .expect("read all");
    assert_eq!(all.len(), 3);

    let original = sample_record(0);
    let decoded = all
        .iter()
        .find(|record| record.revision == 0)
        .expect("revision 0 present");
    assert_eq!(decoded.input, original.input);
    assert_eq!(decoded.decision, original.decision);
    assert_eq!(decoded.visited_node_ids, original.visited_node_ids);
    assert_eq!(decoded.source, "reviews_github");
    assert!(decoded.enforced);

    let limited = db
        .recent_policy_decisions_for_canvas("canvas-test", 2)
        .await
        .expect("read limited");
    assert_eq!(limited.len(), 2);
}

#[tokio::test]
async fn prune_keeps_only_the_newest_rows() {
    let (_dir, db) = connect().await;
    for second in 0..5 {
        let mut record = sample_record(second);
        record.id = format!("policy-decision-{second}");
        record.recorded_at = format!("2026-06-20T10:00:0{second}Z");
        db.record_policy_decision_row(&record)
            .await
            .expect("record");
    }

    let removed = db.prune_policy_decisions(2).await.expect("prune");
    assert_eq!(removed, 3);

    let remaining = db
        .recent_policy_decisions_for_canvas("canvas-test", 10)
        .await
        .expect("read remaining");
    let mut survivors: Vec<String> = remaining
        .iter()
        .map(|record| record.recorded_at.clone())
        .collect();
    survivors.sort();
    assert_eq!(
        survivors,
        vec![
            "2026-06-20T10:00:03Z".to_owned(),
            "2026-06-20T10:00:04Z".to_owned(),
        ]
    );
}

#[tokio::test]
async fn prune_with_a_high_keep_removes_nothing() {
    let (_dir, db) = connect().await;
    for revision in 0..3 {
        db.record_policy_decision_row(&sample_record(revision))
            .await
            .expect("record");
    }
    let removed = db.prune_policy_decisions(100).await.expect("prune");
    assert_eq!(removed, 0);
    assert_eq!(
        db.recent_policy_decisions_for_canvas("canvas-test", 10)
            .await
            .expect("read")
            .len(),
        3
    );
}
