use std::future::{self, Ready};
use std::sync::atomic::{AtomicUsize, Ordering};

use harness_kernel::errors::{CliError, CliErrorKind};

use super::super::{
    ActionGateRequirement, ActionState, InMemoryPullRequestActionStore,
    InMemoryPullRequestEvidenceSource, Mergeability, PullRequestAction,
    PullRequestActionFailureClass, PullRequestActionKind, PullRequestActionStore,
    PullRequestEvidence, PullRequestIdentity, PullRequestLifecycle, PullRequestMergeGates,
    ReviewDecision, ReviewGate,
};
use super::{MergeLedgerOutcome, merge_with_ledger};

const HEAD: &str = "0123456789abcdef";

#[tokio::test]
async fn a_fresh_merge_issues_once_and_never_repeats() {
    let store = InMemoryPullRequestActionStore::new();
    let source = green_source(HEAD);
    let calls = AtomicUsize::new(0);

    let first = merge(&store, &source, &calls, Ok(())).await.expect("a cleared merge proceeds");
    assert_eq!(first, MergeLedgerOutcome::Merged);
    assert_eq!(calls.load(Ordering::SeqCst), 1);

    let second = merge(&store, &source, &calls, Ok(()))
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
    let source = green_source(HEAD);
    let calls = AtomicUsize::new(0);

    let error = merge(&store, &source, &calls, Err(boom()))
        .await
        .expect_err("a merge that errors surfaces the error");
    assert!(error.to_string().contains("boom"));
    assert_eq!(calls.load(Ordering::SeqCst), 1);

    let retry = merge(&store, &source, &calls, Ok(()))
        .await
        .expect("an uncertain, not-applied merge retries");
    assert_eq!(retry, MergeLedgerOutcome::Merged);
    assert_eq!(calls.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn an_errored_merge_that_actually_applied_is_never_reissued() {
    let store = InMemoryPullRequestActionStore::new();
    let calls = AtomicUsize::new(0);

    let before = green_source(HEAD);
    merge(&store, &before, &calls, Err(boom()))
        .await
        .expect_err("the uncertain merge surfaces its error");
    assert_eq!(calls.load(Ordering::SeqCst), 1);

    // Fresh evidence now shows the pull request merged - the errored request had
    // in fact applied. The retry adopts that and never issues a second merge.
    let after = InMemoryPullRequestEvidenceSource::new().with_evidence(merged_evidence());
    let outcome = merge(&store, &after, &calls, Ok(()))
        .await
        .expect("an uncertain merge observed as applied reconciles");
    assert_eq!(outcome, MergeLedgerOutcome::AlreadyApplied);
    assert_eq!(
        calls.load(Ordering::SeqCst),
        1,
        "a merge already applied must never be issued again"
    );
}

#[tokio::test]
async fn a_refused_gate_blocks_without_issuing_or_recording_uncertainty() {
    let store = InMemoryPullRequestActionStore::new();
    // The pull request's head has moved off the verified revision, so the gate
    // refuses the merge before any request is issued.
    let source = green_source("feeddeadbeef");
    let calls = AtomicUsize::new(0);

    let outcome = merge(&store, &source, &calls, Ok(()))
        .await
        .expect("a refused gate is not an error");
    assert!(matches!(outcome, MergeLedgerOutcome::Blocked(_)));
    assert_eq!(calls.load(Ordering::SeqCst), 0, "a refused merge issues no request");

    // The refusal is a transient failure, not an uncertain record, so a later
    // attempt re-admits cleanly rather than being forced to reconcile.
    let record = store
        .load(&merge_action().id)
        .await
        .expect("load")
        .expect("the refused intent is recorded");
    assert_eq!(
        record.state,
        ActionState::Failed(PullRequestActionFailureClass::Transient)
    );
}

async fn merge(
    store: &InMemoryPullRequestActionStore,
    source: &InMemoryPullRequestEvidenceSource,
    calls: &AtomicUsize,
    result: Result<(), CliError>,
) -> Result<MergeLedgerOutcome, CliError> {
    merge_with_ledger(
        store,
        source,
        merge_action(),
        ActionGateRequirement::for_merge(),
        || counting_merge(calls, result),
    )
    .await
}

fn counting_merge(
    calls: &AtomicUsize,
    result: Result<(), CliError>,
) -> Ready<Result<(), CliError>> {
    calls.fetch_add(1, Ordering::SeqCst);
    future::ready(result)
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

fn green_source(head: &str) -> InMemoryPullRequestEvidenceSource {
    InMemoryPullRequestEvidenceSource::new().with_evidence(PullRequestEvidence {
        identity: PullRequestIdentity::from_slug("example/widgets", 42),
        head_revision: head.to_owned(),
        author: None,
        lifecycle: PullRequestLifecycle::Open,
        is_draft: false,
        gates: green_gates(),
        observed_at: "2026-07-29T00:00:00Z".to_owned(),
    })
}

fn merged_evidence() -> PullRequestEvidence {
    PullRequestEvidence {
        identity: PullRequestIdentity::from_slug("example/widgets", 42),
        head_revision: HEAD.to_owned(),
        author: None,
        lifecycle: PullRequestLifecycle::Merged,
        is_draft: false,
        gates: green_gates(),
        observed_at: "2026-07-29T00:00:00Z".to_owned(),
    }
}

fn green_gates() -> PullRequestMergeGates {
    PullRequestMergeGates {
        mergeability: Mergeability::Mergeable,
        viewer_can_update: true,
        viewer_can_merge_as_admin: false,
        checks: Vec::new(),
        required_check_names: Vec::new(),
        review: ReviewGate {
            decision: ReviewDecision::Approved,
            current_approvals: 1,
            required_approvals: 1,
        },
    }
}
