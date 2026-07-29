use super::super::gates::{Mergeability, PullRequestMergeGates, ReviewDecision, ReviewGate};
use super::super::{PullRequestEvidence, PullRequestIdentity, PullRequestLifecycle};
use super::{
    ActionAdmission, ActionOutcome, ActionState, InMemoryPullRequestActionStore, PullRequestAction,
    PullRequestActionFailureClass, PullRequestActionKind, PullRequestActionStore,
    action_effect_observed, begin_action, finish_action, reconcile_action,
};

fn action() -> PullRequestAction {
    PullRequestAction {
        id: "octo/harness#7:merge:aaa".to_string(),
        kind: PullRequestActionKind::Merge,
        identity: PullRequestIdentity::new("octo", "harness", 7),
        head_revision: "aaa".to_string(),
    }
}

async fn state_of(store: &InMemoryPullRequestActionStore, id: &str) -> ActionState {
    store.load(id).await.expect("load").expect("recorded").state
}

#[tokio::test]
async fn a_fresh_action_records_pending_and_proceeds() {
    let store = InMemoryPullRequestActionStore::new();
    let admission = begin_action(&store, action()).await.expect("begin");
    assert_eq!(admission, ActionAdmission::Proceed);
    assert_eq!(state_of(&store, &action().id).await, ActionState::Pending);
}

#[tokio::test]
async fn a_succeeded_action_is_never_reissued() {
    let store = InMemoryPullRequestActionStore::new();
    begin_action(&store, action()).await.expect("begin");
    finish_action(&store, &action().id, ActionOutcome::Succeeded)
        .await
        .expect("finish");
    // The same intent again must not become a second visible action.
    let admission = begin_action(&store, action()).await.expect("begin again");
    assert_eq!(admission, ActionAdmission::AlreadyApplied);
    assert_eq!(state_of(&store, &action().id).await, ActionState::Succeeded);
}

#[tokio::test]
async fn a_permanent_failure_is_abandoned() {
    let store = InMemoryPullRequestActionStore::new();
    begin_action(&store, action()).await.expect("begin");
    finish_action(
        &store,
        &action().id,
        ActionOutcome::Failed {
            class: PullRequestActionFailureClass::Permanent,
            detail: "422 unmergeable".to_string(),
        },
    )
    .await
    .expect("finish");
    let admission = begin_action(&store, action()).await.expect("begin again");
    assert_eq!(admission, ActionAdmission::Abandoned);
}

#[tokio::test]
async fn a_transient_failure_retries() {
    let store = InMemoryPullRequestActionStore::new();
    begin_action(&store, action()).await.expect("begin");
    finish_action(
        &store,
        &action().id,
        ActionOutcome::Failed {
            class: PullRequestActionFailureClass::Transient,
            detail: "502".to_string(),
        },
    )
    .await
    .expect("finish");
    let admission = begin_action(&store, action()).await.expect("begin again");
    assert_eq!(admission, ActionAdmission::Proceed);
    assert_eq!(state_of(&store, &action().id).await, ActionState::Pending);
}

#[tokio::test]
async fn a_pending_record_on_restart_needs_reconcile() {
    let store = InMemoryPullRequestActionStore::new();
    // First attempt records Pending, then the process dies before finishing.
    begin_action(&store, action()).await.expect("begin");
    // Restart: the same intent is now uncertain, not blindly retried.
    let admission = begin_action(&store, action()).await.expect("restart");
    assert_eq!(admission, ActionAdmission::NeedsReconcile);
    assert_eq!(state_of(&store, &action().id).await, ActionState::Uncertain);
}

#[tokio::test]
async fn reconciling_an_applied_effect_marks_it_succeeded() {
    let store = InMemoryPullRequestActionStore::new();
    begin_action(&store, action()).await.expect("begin");
    begin_action(&store, action())
        .await
        .expect("restart -> uncertain");
    let admission = reconcile_action(&store, action(), true)
        .await
        .expect("reconcile");
    assert_eq!(admission, ActionAdmission::AlreadyApplied);
    assert_eq!(state_of(&store, &action().id).await, ActionState::Succeeded);
}

#[tokio::test]
async fn reconciling_an_unapplied_effect_resets_to_pending() {
    let store = InMemoryPullRequestActionStore::new();
    begin_action(&store, action()).await.expect("begin");
    begin_action(&store, action())
        .await
        .expect("restart -> uncertain");
    let admission = reconcile_action(&store, action(), false)
        .await
        .expect("reconcile");
    assert_eq!(admission, ActionAdmission::Proceed);
    assert_eq!(state_of(&store, &action().id).await, ActionState::Pending);
}

#[tokio::test]
async fn finishing_records_the_failure_class_and_detail() {
    let store = InMemoryPullRequestActionStore::new();
    begin_action(&store, action()).await.expect("begin");
    finish_action(
        &store,
        &action().id,
        ActionOutcome::Failed {
            class: PullRequestActionFailureClass::Transient,
            detail: "rate limited".to_string(),
        },
    )
    .await
    .expect("finish");
    let record = store
        .load(&action().id)
        .await
        .expect("load")
        .expect("recorded");
    assert_eq!(
        record.state,
        ActionState::Failed(PullRequestActionFailureClass::Transient)
    );
    assert_eq!(record.detail.as_deref(), Some("rate limited"));
}

#[tokio::test]
async fn finishing_an_unrecorded_action_errors() {
    let store = InMemoryPullRequestActionStore::new();
    let error = finish_action(&store, "never-recorded", ActionOutcome::Succeeded)
        .await
        .expect_err("unrecorded action errors");
    assert!(error.to_string().contains("never-recorded"));
}

#[tokio::test]
async fn reusing_an_id_for_a_different_action_errors() {
    let store = InMemoryPullRequestActionStore::new();
    begin_action(&store, action()).await.expect("begin");
    let mut other = action();
    other.head_revision = "bbb".to_string();
    let error = begin_action(&store, other)
        .await
        .expect_err("an id reused for a different intent errors");
    assert!(error.to_string().contains("reused"));
}

#[tokio::test]
async fn a_url_only_difference_is_the_same_intent() {
    let store = InMemoryPullRequestActionStore::new();
    begin_action(&store, action()).await.expect("begin");
    // Same kind/repo/number/head; only the optional url differs on retry.
    let mut same = action();
    same.identity.url = Some("https://github.com/octo/harness/pull/7".to_string());
    let admission = begin_action(&store, same).await.expect("retry with url");
    assert_eq!(admission, ActionAdmission::NeedsReconcile);
}

#[tokio::test]
async fn a_retry_that_omits_the_url_keeps_the_recorded_one() {
    let store = InMemoryPullRequestActionStore::new();
    let mut first = action();
    first.identity.url = Some("https://github.com/octo/harness/pull/7".to_string());
    begin_action(&store, first).await.expect("begin with url");
    // A retry without the url must not erase the stored metadata.
    begin_action(&store, action())
        .await
        .expect("retry without url");
    let record = store
        .load(&action().id)
        .await
        .expect("load")
        .expect("recorded");
    assert_eq!(
        record.action.identity.url.as_deref(),
        Some("https://github.com/octo/harness/pull/7")
    );
}

#[tokio::test]
async fn reconciling_an_unrecorded_action_errors() {
    let store = InMemoryPullRequestActionStore::new();
    let error = reconcile_action(&store, action(), true)
        .await
        .expect_err("reconciling an unrecorded action errors");
    assert!(error.to_string().contains("unrecorded"));
}

#[tokio::test]
async fn reconciling_an_action_not_awaiting_reconciliation_errors() {
    let store = InMemoryPullRequestActionStore::new();
    // One begin leaves it Pending, not Uncertain.
    begin_action(&store, action()).await.expect("begin");
    let error = reconcile_action(&store, action(), true)
        .await
        .expect_err("reconciling a non-uncertain action errors");
    assert!(error.to_string().contains("not awaiting reconciliation"));
}

#[tokio::test]
async fn finishing_a_terminal_action_never_reopens_it() {
    let store = InMemoryPullRequestActionStore::new();
    begin_action(&store, action()).await.expect("begin");
    finish_action(&store, &action().id, ActionOutcome::Succeeded)
        .await
        .expect("finish");
    // A later finish with a failure must not re-open the succeeded action.
    finish_action(
        &store,
        &action().id,
        ActionOutcome::Failed {
            class: PullRequestActionFailureClass::Permanent,
            detail: "late".to_string(),
        },
    )
    .await
    .expect("terminal finish is a no-op");
    assert_eq!(state_of(&store, &action().id).await, ActionState::Succeeded);
}

#[tokio::test]
async fn an_uncertain_finish_forces_reconciliation_not_a_blind_retry() {
    let store = InMemoryPullRequestActionStore::new();
    begin_action(&store, action()).await.expect("begin");
    // A timeout: the request may have applied, so the outcome is unknown.
    finish_action(
        &store,
        &action().id,
        ActionOutcome::Uncertain {
            detail: "request timed out".to_string(),
        },
    )
    .await
    .expect("finish");
    assert_eq!(state_of(&store, &action().id).await, ActionState::Uncertain);
    // A retry must reconcile rather than blindly proceed and risk a duplicate.
    let admission = begin_action(&store, action()).await.expect("begin again");
    assert_eq!(admission, ActionAdmission::NeedsReconcile);
}

#[tokio::test]
async fn a_retry_after_an_uncertain_finish_keeps_the_reconcile_reason() {
    let store = InMemoryPullRequestActionStore::new();
    begin_action(&store, action()).await.expect("begin");
    finish_action(
        &store,
        &action().id,
        ActionOutcome::Uncertain {
            detail: "request timed out".to_string(),
        },
    )
    .await
    .expect("finish");
    // Re-admitting keeps it Uncertain but must not drop why reconciliation is due.
    begin_action(&store, action()).await.expect("retry");
    let record = store
        .load(&action().id)
        .await
        .expect("load")
        .expect("recorded");
    assert_eq!(record.state, ActionState::Uncertain);
    assert_eq!(record.detail.as_deref(), Some("request timed out"));
}

#[test]
fn a_merge_effect_is_observable_from_the_lifecycle() {
    assert_eq!(
        action_effect_observed(
            PullRequestActionKind::Merge,
            &evidence(PullRequestLifecycle::Merged)
        ),
        Some(true)
    );
    assert_eq!(
        action_effect_observed(
            PullRequestActionKind::Merge,
            &evidence(PullRequestLifecycle::Open)
        ),
        Some(false)
    );
}

#[test]
fn approve_and_comment_effects_are_not_observable_from_evidence() {
    assert_eq!(
        action_effect_observed(
            PullRequestActionKind::Approve,
            &evidence(PullRequestLifecycle::Open)
        ),
        None
    );
    assert_eq!(
        action_effect_observed(
            PullRequestActionKind::Comment,
            &evidence(PullRequestLifecycle::Open)
        ),
        None
    );
}

#[tokio::test]
async fn a_full_crash_and_recovery_never_duplicates() {
    let store = InMemoryPullRequestActionStore::new();
    // Attempt 1: admitted, request sent to GitHub, process crashes before finish.
    assert_eq!(
        begin_action(&store, action()).await.expect("a1"),
        ActionAdmission::Proceed
    );
    // Restart: uncertain, must reconcile.
    assert_eq!(
        begin_action(&store, action()).await.expect("a2"),
        ActionAdmission::NeedsReconcile
    );
    // Reconcile sees the merge already landed -> no second merge request.
    assert_eq!(
        reconcile_action(&store, action(), true).await.expect("rec"),
        ActionAdmission::AlreadyApplied
    );
    // A later retry of the same intent still refuses to reissue.
    assert_eq!(
        begin_action(&store, action()).await.expect("a3"),
        ActionAdmission::AlreadyApplied
    );
}

fn evidence(lifecycle: PullRequestLifecycle) -> PullRequestEvidence {
    PullRequestEvidence {
        identity: PullRequestIdentity::new("octo", "harness", 7),
        head_revision: "aaa".to_string(),
        author: None,
        lifecycle,
        is_draft: false,
        gates: PullRequestMergeGates {
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
        },
        observed_at: "2026-07-29T00:00:00Z".to_string(),
    }
}
