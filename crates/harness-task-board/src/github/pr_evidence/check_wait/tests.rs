use std::sync::atomic::AtomicBool;
use std::time::Duration;

use super::super::gates::{
    CheckGate, CheckState, Mergeability, PullRequestMergeGates, ReviewDecision, ReviewGate,
};
use super::super::{
    InMemoryPullRequestEvidenceSource, PullRequestEvidence, PullRequestEvidenceRead,
    PullRequestIdentity, PullRequestLifecycle,
};
use super::{CheckWait, CheckWaitControls, CheckWaitOutcome, CheckWaitProgress, poll_check_wait};

fn identity() -> PullRequestIdentity {
    PullRequestIdentity::new("octo", "harness", 7)
}

fn evidence(head: &str, checks: &[(&str, CheckState)], required: &[&str]) -> PullRequestEvidence {
    PullRequestEvidence {
        identity: identity(),
        head_revision: head.to_string(),
        author: Some("octocat".to_string()),
        viewer_login: None,
        viewer_has_approved: false,
        lifecycle: PullRequestLifecycle::Open,
        is_draft: false,
        gates: PullRequestMergeGates {
            mergeability: Mergeability::Mergeable,
            viewer_can_update: true,
            viewer_can_merge_as_admin: false,
            checks: checks
                .iter()
                .map(|(name, state)| CheckGate {
                    name: (*name).to_string(),
                    state: *state,
                    details_url: None,
                })
                .collect(),
            required_check_names: required.iter().map(|name| (*name).to_string()).collect(),
            review: ReviewGate {
                decision: ReviewDecision::Approved,
                current_approvals: 1,
                required_approvals: 1,
            },
        },
        observed_at: "2026-07-29T00:00:00Z".to_string(),
    }
}

fn no_cancel() -> AtomicBool {
    AtomicBool::new(false)
}

fn controls(max_polls: u32, cancel: &AtomicBool) -> CheckWaitControls<'_> {
    CheckWaitControls {
        max_polls,
        poll_interval: Duration::ZERO,
        cancel,
    }
}

#[test]
fn a_wait_records_its_pull_request_head_and_required_checks() {
    let wait = CheckWait::for_head(&evidence("aaa", &[], &["build", "lint"]));
    assert_eq!(wait.identity, identity());
    assert_eq!(wait.head_revision, "aaa");
    assert_eq!(wait.required_checks, vec!["build", "lint"]);
}

#[test]
fn every_required_check_terminal_completes_the_wait() {
    let wait = CheckWait::for_head(&evidence("aaa", &[], &["build"]));
    let read = PullRequestEvidenceRead::found(evidence(
        "aaa",
        &[("build", CheckState::Failure)],
        &["build"],
    ));
    // Terminal, not passing: completion means every required check concluded,
    // and the caller reads pass/fail off the returned evidence.
    assert!(matches!(
        wait.assess(&read),
        CheckWaitProgress::Completed(_)
    ));
}

#[test]
fn a_pending_required_check_keeps_waiting() {
    let wait = CheckWait::for_head(&evidence("aaa", &[], &["build"]));
    let read = PullRequestEvidenceRead::found(evidence(
        "aaa",
        &[("build", CheckState::Pending)],
        &["build"],
    ));
    assert_eq!(wait.assess(&read), CheckWaitProgress::Pending);
}

#[test]
fn a_required_check_with_no_run_keeps_waiting() {
    let wait = CheckWait::for_head(&evidence("aaa", &[], &["build", "deploy"]));
    let read =
        PullRequestEvidenceRead::found(evidence("aaa", &[("build", CheckState::Success)], &[]));
    assert_eq!(wait.assess(&read), CheckWaitProgress::Pending);
}

#[test]
fn a_new_head_supersedes_the_wait() {
    let wait = CheckWait::for_head(&evidence("aaa", &[], &["build"]));
    let read = PullRequestEvidenceRead::found(evidence(
        "bbb",
        &[("build", CheckState::Success)],
        &["build"],
    ));
    assert_eq!(
        wait.assess(&read),
        CheckWaitProgress::Superseded {
            observed_head: "bbb".to_string()
        }
    );
}

#[test]
fn a_missing_pull_request_vanishes() {
    let wait = CheckWait::for_head(&evidence("aaa", &[], &["build"]));
    let read = PullRequestEvidenceRead::missing(identity(), "2026-07-29T00:00:00Z".to_string());
    assert_eq!(wait.assess(&read), CheckWaitProgress::Vanished);
}

#[tokio::test]
async fn polling_completes_when_checks_conclude() {
    let wait = CheckWait::for_head(&evidence("aaa", &[], &["build"]));
    let source = InMemoryPullRequestEvidenceSource::new().with_evidence(evidence(
        "aaa",
        &[("build", CheckState::Success)],
        &["build"],
    ));
    let cancel = no_cancel();
    let outcome = poll_check_wait(&source, &wait, controls(3, &cancel))
        .await
        .expect("poll");
    let CheckWaitOutcome::Completed(evidence) = outcome else {
        panic!("expected completion, got {outcome:?}");
    };
    assert_eq!(evidence.head_revision, "aaa");
}

#[tokio::test]
async fn polling_a_pending_check_times_out() {
    let wait = CheckWait::for_head(&evidence("aaa", &[], &["build"]));
    let source = InMemoryPullRequestEvidenceSource::new().with_evidence(evidence(
        "aaa",
        &[("build", CheckState::Pending)],
        &["build"],
    ));
    let cancel = no_cancel();
    let outcome = poll_check_wait(&source, &wait, controls(3, &cancel))
        .await
        .expect("poll");
    assert_eq!(outcome, CheckWaitOutcome::TimedOut);
}

#[tokio::test]
async fn a_head_change_never_polls_as_a_completed_wait() {
    let wait = CheckWait::for_head(&evidence("aaa", &[], &["build"]));
    // The new head's check passes, but the wait was bound to the old head.
    let source = InMemoryPullRequestEvidenceSource::new().with_evidence(evidence(
        "bbb",
        &[("build", CheckState::Success)],
        &["build"],
    ));
    let cancel = no_cancel();
    let outcome = poll_check_wait(&source, &wait, controls(3, &cancel))
        .await
        .expect("poll");
    assert_eq!(
        outcome,
        CheckWaitOutcome::Superseded {
            observed_head: "bbb".to_string()
        }
    );
}

#[tokio::test]
async fn a_vanished_pull_request_polls_as_vanished() {
    let wait = CheckWait::for_head(&evidence("aaa", &[], &["build"]));
    let source = InMemoryPullRequestEvidenceSource::new();
    let cancel = no_cancel();
    let outcome = poll_check_wait(&source, &wait, controls(3, &cancel))
        .await
        .expect("poll");
    assert_eq!(outcome, CheckWaitOutcome::Vanished);
}

#[tokio::test]
async fn a_set_cancel_flag_ends_the_wait() {
    let wait = CheckWait::for_head(&evidence("aaa", &[], &["build"]));
    let source = InMemoryPullRequestEvidenceSource::new().with_evidence(evidence(
        "aaa",
        &[("build", CheckState::Pending)],
        &["build"],
    ));
    let cancel = AtomicBool::new(true);
    let outcome = poll_check_wait(&source, &wait, controls(3, &cancel))
        .await
        .expect("poll");
    assert_eq!(outcome, CheckWaitOutcome::Cancelled);
}

#[tokio::test]
async fn a_provider_failure_propagates_as_an_error() {
    let wait = CheckWait::for_head(&evidence("aaa", &[], &["build"]));
    let source = InMemoryPullRequestEvidenceSource::new().with_failure(&identity(), "graphql 502");
    let cancel = no_cancel();
    let error = poll_check_wait(&source, &wait, controls(3, &cancel))
        .await
        .expect_err("provider failure surfaces as Err");
    assert!(error.to_string().contains("graphql 502"));
}

#[tokio::test]
async fn a_zero_poll_budget_still_honors_a_set_cancel_flag() {
    let wait = CheckWait::for_head(&evidence("aaa", &[], &["build"]));
    let source = InMemoryPullRequestEvidenceSource::new();
    let cancel = AtomicBool::new(true);
    let outcome = poll_check_wait(&source, &wait, controls(0, &cancel))
        .await
        .expect("poll");
    assert_eq!(outcome, CheckWaitOutcome::Cancelled);
}

#[tokio::test]
async fn a_zero_poll_budget_times_out_when_not_cancelled() {
    let wait = CheckWait::for_head(&evidence("aaa", &[], &["build"]));
    let source = InMemoryPullRequestEvidenceSource::new();
    let cancel = no_cancel();
    let outcome = poll_check_wait(&source, &wait, controls(0, &cancel))
        .await
        .expect("poll");
    assert_eq!(outcome, CheckWaitOutcome::TimedOut);
}
