mod fixtures;

use std::sync::atomic::Ordering;

use super::*;
use crate::github::{InMemoryPullRequestActionStore, ReviewDecision};
use fixtures::*;

#[tokio::test]
async fn enough_existing_approvals_merge_once_on_the_verified_head() {
    let client = FakeClient::new([evidence(1, 1), evidence(1, 1)]);
    let store = InMemoryPullRequestActionStore::new();
    let sink = MemorySink::default();

    let first = run(&client, &store, &sink, request(), policy(true))
        .await
        .expect("merge");
    assert!(matches!(
        first,
        TaskBoardDependencyCompletionOutcome::Merged { created: true, .. }
    ));
    assert_eq!(client.approvals.load(Ordering::SeqCst), 0);
    assert_eq!(client.merges.load(Ordering::SeqCst), 1);
    assert_eq!(
        client.last_merge(),
        Some((GitHubMergeMethod::Squash, HEAD.to_owned()))
    );

    let retry = run(&client, &store, &sink, request(), policy(true))
        .await
        .expect("idempotent retry");
    assert!(matches!(
        retry,
        TaskBoardDependencyCompletionOutcome::Merged { created: false, .. }
    ));
    assert_eq!(client.merges.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn permitted_account_approval_is_submitted_once_before_merge() {
    let client = FakeClient::new([
        evidence(0, 1),
        approved_by_viewer(1, 1),
        approved_by_viewer(1, 1),
    ]);
    let store = InMemoryPullRequestActionStore::new();
    let sink = MemorySink::default();

    let outcome = run(&client, &store, &sink, request(), policy(true))
        .await
        .expect("approve and merge");
    assert!(matches!(
        outcome,
        TaskBoardDependencyCompletionOutcome::Merged { created: true, .. }
    ));
    assert_eq!(client.approvals.load(Ordering::SeqCst), 1);
    assert_eq!(client.merges.load(Ordering::SeqCst), 1);

    run(&client, &store, &sink, request(), policy(true))
        .await
        .expect("retry");
    assert_eq!(client.approvals.load(Ordering::SeqCst), 1);
    assert_eq!(client.merges.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn policy_or_account_refusal_pauses_with_the_unmet_human_requirement() {
    for (client, policy) in [
        (FakeClient::new([evidence(0, 2)]), policy(false)),
        (FakeClient::new([self_authored(0, 2)]), policy(true)),
    ] {
        let store = InMemoryPullRequestActionStore::new();
        let sink = MemorySink::default();
        let outcome = run(&client, &store, &sink, request(), policy)
            .await
            .expect("pause");
        let TaskBoardDependencyCompletionOutcome::Paused(record) = outcome else {
            panic!("expected a pause");
        };
        assert_eq!(
            record.status,
            TaskBoardDependencyCompletionStatus::HumanRequired
        );
        assert!(record.detail.contains("2 additional human approval(s)"));
        assert_eq!(client.approvals.load(Ordering::SeqCst), 0);
        assert_eq!(client.merges.load(Ordering::SeqCst), 0);
    }
}

#[tokio::test]
async fn remaining_human_approval_pauses_after_the_automated_approval() {
    let client = FakeClient::new([evidence(0, 2), approved_by_viewer(1, 2)]);
    let store = InMemoryPullRequestActionStore::new();
    let sink = MemorySink::default();

    let outcome = run(&client, &store, &sink, request(), policy(true))
        .await
        .expect("pause");
    let TaskBoardDependencyCompletionOutcome::Paused(record) = outcome else {
        panic!("expected a pause");
    };
    assert_eq!(
        record.status,
        TaskBoardDependencyCompletionStatus::HumanRequired
    );
    assert_eq!(record.current_approvals, 1);
    assert_eq!(record.required_approvals, 2);
    assert!(record.detail.contains("1 additional human approval(s)"));
    assert_eq!(client.approvals.load(Ordering::SeqCst), 1);
    assert_eq!(client.merges.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn unresolved_requested_changes_never_trigger_an_approval() {
    let client = FakeClient::new([changes_requested()]);
    let store = InMemoryPullRequestActionStore::new();
    let sink = MemorySink::default();

    let outcome = run(&client, &store, &sink, request(), policy(true))
        .await
        .expect("pause");
    let TaskBoardDependencyCompletionOutcome::Paused(record) = outcome else {
        panic!("expected a pause");
    };
    assert_eq!(
        record.status,
        TaskBoardDependencyCompletionStatus::HumanRequired
    );
    assert!(record.detail.contains("requested changes must be resolved"));
    assert_eq!(client.approvals.load(Ordering::SeqCst), 0);
    assert_eq!(client.merges.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn delayed_approval_projection_waits_without_resubmitting_or_escalating() {
    let client = FakeClient::new([evidence(0, 1), evidence(0, 1)]);
    let store = InMemoryPullRequestActionStore::new();
    let sink = MemorySink::default();

    let outcome = run(&client, &store, &sink, request(), policy(true))
        .await
        .expect("wait");
    let TaskBoardDependencyCompletionOutcome::Paused(record) = outcome else {
        panic!("expected a pause");
    };
    assert_eq!(
        record.status,
        TaskBoardDependencyCompletionStatus::ApprovalSubmitted
    );
    assert!(record.detail.contains("waiting for GitHub to reflect"));
    assert_eq!(client.approvals.load(Ordering::SeqCst), 1);
    assert_eq!(client.merges.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn a_head_change_after_approval_requires_reverification_without_merge() {
    let client = FakeClient::new([evidence(0, 1), moved_head()]);
    let store = InMemoryPullRequestActionStore::new();
    let sink = MemorySink::default();

    let outcome = run(&client, &store, &sink, request(), policy(true))
        .await
        .expect("pause");
    let TaskBoardDependencyCompletionOutcome::Paused(record) = outcome else {
        panic!("expected a pause");
    };
    assert_eq!(
        record.status,
        TaskBoardDependencyCompletionStatus::ReverificationRequired
    );
    assert_eq!(client.approvals.load(Ordering::SeqCst), 1);
    assert_eq!(client.merges.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn a_different_already_merged_head_is_not_attributed_to_the_verified_head() {
    let mut merged = moved_head();
    merged.lifecycle = PullRequestLifecycle::Merged;
    let client = FakeClient::new([merged]);
    let store = InMemoryPullRequestActionStore::new();
    let sink = MemorySink::default();

    let outcome = run(&client, &store, &sink, request(), policy(true))
        .await
        .expect("pause");
    let TaskBoardDependencyCompletionOutcome::Paused(record) = outcome else {
        panic!("expected a pause");
    };
    assert_eq!(
        record.status,
        TaskBoardDependencyCompletionStatus::ReverificationRequired
    );
    assert_eq!(client.approvals.load(Ordering::SeqCst), 0);
    assert_eq!(client.merges.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn a_regressed_gate_or_permission_blocks_without_a_merge_mutation() {
    for blocked in [conflicted(), without_permission()] {
        let client = FakeClient::new([evidence(1, 1), blocked]);
        let store = InMemoryPullRequestActionStore::new();
        let sink = MemorySink::default();

        let outcome = run(&client, &store, &sink, request(), policy(true))
            .await
            .expect("blocked");
        assert!(matches!(
            outcome,
            TaskBoardDependencyCompletionOutcome::Paused(_)
        ));
        assert_eq!(client.merges.load(Ordering::SeqCst), 0);
    }
}

#[tokio::test]
async fn an_uncertain_approval_is_reconciled_before_retry() {
    let client = FakeClient::new([
        evidence(0, 1),
        approved_by_viewer(1, 1),
        approved_by_viewer(1, 1),
    ])
    .with_approval_failure();
    let store = InMemoryPullRequestActionStore::new();
    let sink = MemorySink::default();

    run(&client, &store, &sink, request(), policy(true))
        .await
        .expect_err("lost approval response");
    assert_eq!(client.approvals.load(Ordering::SeqCst), 1);

    let outcome = run(&client, &store, &sink, request(), policy(true))
        .await
        .expect("reconcile and merge");
    assert!(matches!(
        outcome,
        TaskBoardDependencyCompletionOutcome::Merged { .. }
    ));
    assert_eq!(
        client.approvals.load(Ordering::SeqCst),
        1,
        "an observed approval must not be submitted twice"
    );
    assert_eq!(client.merges.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn a_disallowed_merge_method_fails_before_reads_or_mutations() {
    let client = FakeClient::new([evidence(1, 1)]);
    let store = InMemoryPullRequestActionStore::new();
    let sink = MemorySink::default();
    let mut request = request();
    request.merge_method = GitHubMergeMethod::Merge;

    let error = run(&client, &store, &sink, request, policy(true))
        .await
        .expect_err("method denied");
    assert!(error.to_string().contains("merge method"));
    assert_eq!(client.reads.load(Ordering::SeqCst), 0);
    assert_eq!(client.merges.load(Ordering::SeqCst), 0);
}

#[test]
fn zero_required_approvals_are_satisfied_without_a_review_decision() {
    let mut gates = green_gates(0, 0);
    gates.review.decision = ReviewDecision::NotRequired;
    assert!(gates.review.is_satisfied());

    for decision in [ReviewDecision::ReviewRequired, ReviewDecision::Unknown] {
        gates.review.decision = decision;
        assert!(!gates.review.is_satisfied());
    }
}
