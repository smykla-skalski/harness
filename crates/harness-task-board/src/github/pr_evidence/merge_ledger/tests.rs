use std::sync::atomic::{AtomicUsize, Ordering};

use harness_kernel::errors::{CliError, CliErrorKind};

use super::super::{
    InMemoryPullRequestActionStore, InMemoryPullRequestEvidenceSource, Mergeability,
    PullRequestAction, PullRequestActionKind, PullRequestEvidence, PullRequestIdentity,
    PullRequestLifecycle, PullRequestMergeGates, ReviewDecision, ReviewGate,
};
use super::{MergeLedgerOutcome, merge_with_ledger};

const HEAD: &str = "0123456789abcdef";

#[tokio::test]
async fn a_fresh_merge_issues_once_and_never_repeats() {
    let store = InMemoryPullRequestActionStore::new();
    let source = InMemoryPullRequestEvidenceSource::new();
    let calls = AtomicUsize::new(0);

    let first = merge_with_ledger(&store, &source, merge_action(), || counting_merge(&calls, Ok(())))
        .await
        .expect("a fresh merge proceeds");
    assert_eq!(first, MergeLedgerOutcome::Merged);
    assert_eq!(calls.load(Ordering::SeqCst), 1);

    let second =
        merge_with_ledger(&store, &source, merge_action(), || counting_merge(&calls, Ok(())))
            .await
            .expect("a repeated succeeded intent is admitted as already applied");
    assert_eq!(second, MergeLedgerOutcome::AlreadyApplied);
    assert_eq!(
        calls.load(Ordering::SeqCst),
        1,
        "a succeeded merge must never be issued a second time"
    );
}

#[tokio::test]
async fn an_errored_merge_retries_only_after_reconciling_to_not_applied() {
    let store = InMemoryPullRequestActionStore::new();
    let source = InMemoryPullRequestEvidenceSource::new();
    let calls = AtomicUsize::new(0);

    let error = merge_with_ledger(&store, &source, merge_action(), || {
        counting_merge(&calls, Err(boom()))
    })
    .await
    .expect_err("a merge that errors surfaces the error");
    assert!(error.to_string().contains("boom"));
    assert_eq!(calls.load(Ordering::SeqCst), 1);

    // The prior attempt is uncertain and the pull request is not merged, so the
    // retry reconciles to not-applied and issues the merge again.
    let retry =
        merge_with_ledger(&store, &source, merge_action(), || counting_merge(&calls, Ok(())))
            .await
            .expect("an uncertain, not-applied merge retries");
    assert_eq!(retry, MergeLedgerOutcome::Merged);
    assert_eq!(calls.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn an_errored_merge_that_actually_applied_is_never_reissued() {
    let store = InMemoryPullRequestActionStore::new();
    let calls = AtomicUsize::new(0);

    // The first attempt errors after the request left, so its outcome is unknown.
    let before = InMemoryPullRequestEvidenceSource::new();
    merge_with_ledger(&store, &before, merge_action(), || {
        counting_merge(&calls, Err(boom()))
    })
    .await
    .expect_err("the uncertain merge surfaces its error");
    assert_eq!(calls.load(Ordering::SeqCst), 1);

    // Fresh evidence now shows the pull request merged - the errored request had
    // in fact applied. The retry must adopt that and never issue a second merge.
    let after = InMemoryPullRequestEvidenceSource::new().with_evidence(merged_evidence());
    let outcome =
        merge_with_ledger(&store, &after, merge_action(), || counting_merge(&calls, Ok(())))
            .await
            .expect("an uncertain merge observed as applied reconciles");
    assert_eq!(outcome, MergeLedgerOutcome::AlreadyApplied);
    assert_eq!(
        calls.load(Ordering::SeqCst),
        1,
        "a merge already applied must never be issued again"
    );
}

async fn counting_merge(calls: &AtomicUsize, result: Result<(), CliError>) -> Result<(), CliError> {
    calls.fetch_add(1, Ordering::SeqCst);
    result
}

fn boom() -> CliError {
    CliErrorKind::workflow_io("boom").into()
}

fn merge_action() -> PullRequestAction {
    PullRequestAction {
        id: "reviews.merge:example/widgets#42".to_owned(),
        kind: PullRequestActionKind::Merge,
        identity: PullRequestIdentity::from_slug("example/widgets", 42),
        head_revision: HEAD.to_owned(),
    }
}

fn merged_evidence() -> PullRequestEvidence {
    PullRequestEvidence {
        identity: PullRequestIdentity::from_slug("example/widgets", 42),
        head_revision: HEAD.to_owned(),
        author: None,
        lifecycle: PullRequestLifecycle::Merged,
        is_draft: false,
        gates: PullRequestMergeGates {
            mergeability: Mergeability::Unknown,
            viewer_can_update: false,
            viewer_can_merge_as_admin: false,
            checks: Vec::new(),
            required_check_names: Vec::new(),
            review: ReviewGate {
                decision: ReviewDecision::Approved,
                current_approvals: 1,
                required_approvals: 1,
            },
        },
        observed_at: "2026-07-29T00:00:00Z".to_owned(),
    }
}
