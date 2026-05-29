use std::path::PathBuf;

use tempfile::tempdir;

use crate::daemon::protocol::{ReviewsPolicyHistoryRequest, ReviewsPolicySubject};
use crate::task_board::policy_graph::PolicyWaitCondition;
use crate::task_board::policy_runtime::models::{
    PolicyRunSubject, PolicyRunTrigger, PolicyWorkflowRun,
};
use crate::task_board::policy_runtime::repository::PolicyRuntimeRepository;

#[test]
fn history_aggregates_metrics_and_orders_timeline() {
    let root = test_runtime_root();
    let repository = PolicyRuntimeRepository::new(root.clone());

    let mut completed = run_fixture("head-1");
    completed.record_action("reviews.merge".to_owned(), 1);
    completed.mark_completed();
    repository.save(&completed).expect("save completed run");

    let mut waiting = run_fixture("head-2");
    waiting.record_action("reviews.approve".to_owned(), 1);
    waiting.mark_waiting(
        PolicyWaitCondition::Event {
            event_key: "reviews.checks_passed".to_owned(),
        },
        2,
    );
    repository.save(&waiting).expect("save waiting run");

    let history = super::super::reviews::policy_history::reviews_policy_history_with_root(
        root,
        &ReviewsPolicyHistoryRequest {
            workflow_id: "reviews_auto".to_owned(),
            subject: ReviewsPolicySubject {
                repository: "Kong/mink-vcp-manager".to_owned(),
                pull_request_number: 1272,
            },
        },
    )
    .expect("history response");

    assert_eq!(history.workflow_id, "reviews_auto");
    assert_eq!(history.metrics.total, 2);
    assert_eq!(history.metrics.completed, 1);
    assert_eq!(history.metrics.waiting, 1);
    assert_eq!(
        history.metrics.by_trigger.get("background").copied(),
        Some(2)
    );
    assert_eq!(history.runs.len(), 2);

    assert!(
        history
            .timeline
            .iter()
            .any(|entry| entry.event == "action:reviews.merge"),
        "timeline should record the completed merge action"
    );
    assert!(
        history.timeline.iter().any(|entry| entry.event == "wait"),
        "timeline should record the waiting step"
    );

    let recorded_times = history
        .timeline
        .iter()
        .map(|entry| entry.recorded_at.clone())
        .collect::<Vec<_>>();
    let mut sorted_times = recorded_times.clone();
    sorted_times.sort();
    assert_eq!(
        recorded_times, sorted_times,
        "timeline must be oldest-first"
    );
}

#[test]
fn history_for_unknown_subject_is_empty() {
    let root = test_runtime_root();
    let history = super::super::reviews::policy_history::reviews_policy_history_with_root(
        root,
        &ReviewsPolicyHistoryRequest {
            workflow_id: "reviews_auto".to_owned(),
            subject: ReviewsPolicySubject {
                repository: "Kong/mink-vcp-manager".to_owned(),
                pull_request_number: 99,
            },
        },
    )
    .expect("history response");

    assert_eq!(history.metrics.total, 0);
    assert!(history.runs.is_empty());
    assert!(history.timeline.is_empty());
    assert!(history.metrics.by_trigger.is_empty());
}

fn run_fixture(head_sha: &str) -> PolicyWorkflowRun {
    PolicyWorkflowRun::new(
        "reviews_auto",
        PolicyRunSubject::review_pr("Kong/mink-vcp-manager#1272"),
        Some(head_sha.to_owned()),
        PolicyRunTrigger::Background,
        Vec::new(),
    )
}

fn test_runtime_root() -> PathBuf {
    let temp = tempdir().expect("create tempdir");
    let root = temp.path().to_path_buf();
    std::mem::forget(temp);
    root
}
