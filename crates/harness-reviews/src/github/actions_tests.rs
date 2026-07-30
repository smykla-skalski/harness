use super::*;
use crate::{
    ReviewCheckStatus, ReviewMergeableState, ReviewPullRequestState, ReviewReviewStatus,
    ReviewTargetFlags,
};
use harness_task_board::github::{
    CheckGate, CheckState, InMemoryPullRequestEvidenceSource, Mergeability, PullRequestEvidence,
    PullRequestLifecycle, PullRequestMergeGates, ReviewDecision, ReviewGate,
};

const HEAD: &str = "0123456789abcdef";

#[tokio::test]
async fn an_approval_proceeds_when_the_head_still_matches() {
    let source = InMemoryPullRequestEvidenceSource::new().with_evidence(evidence(
        HEAD,
        PullRequestLifecycle::Open,
        false,
        minimal_gates(),
    ));

    verify_target_gate(
        &source,
        &review_target(),
        ActionGateRequirement::for_approval(),
    )
    .await
    .expect("open pull request on the verified head clears the approval gate");
}

#[tokio::test]
async fn an_approval_is_refused_when_the_head_moved() {
    let source = InMemoryPullRequestEvidenceSource::new().with_evidence(evidence(
        "feeddeadbeef",
        PullRequestLifecycle::Open,
        false,
        minimal_gates(),
    ));

    let error = verify_target_gate(
        &source,
        &review_target(),
        ActionGateRequirement::for_approval(),
    )
    .await
    .expect_err("a moved head must refuse the approval");
    assert!(error.to_string().contains("head moved"));
}

#[tokio::test]
async fn an_action_is_refused_when_the_pull_request_is_missing() {
    let source = InMemoryPullRequestEvidenceSource::new();

    let error = verify_target_gate(
        &source,
        &review_target(),
        ActionGateRequirement::for_approval(),
    )
    .await
    .expect_err("a vanished pull request must refuse the action");
    assert!(error.to_string().contains("no longer present"));
}

#[tokio::test]
async fn an_action_is_refused_without_an_exact_head() {
    let source = InMemoryPullRequestEvidenceSource::new();
    let mut target = review_target();
    target.head_sha = "  ".to_owned();

    let error = verify_target_gate(&source, &target, ActionGateRequirement::for_comment())
        .await
        .expect_err("a blank head must refuse the action before any read");
    assert_eq!(error.code(), "WORKFLOW_PARSE");
}

#[tokio::test]
async fn a_merge_is_refused_when_the_gates_are_not_green() {
    let source = InMemoryPullRequestEvidenceSource::new().with_evidence(evidence(
        HEAD,
        PullRequestLifecycle::Open,
        false,
        minimal_gates(),
    ));

    let error = verify_target_gate(
        &source,
        &review_target(),
        ActionGateRequirement::for_merge(),
    )
    .await
    .expect_err("an unmergeable, unapproved pull request must refuse the merge");
    assert!(error.to_string().contains("refused"));
}

#[tokio::test]
async fn a_merge_proceeds_when_every_gate_is_green() {
    let source = InMemoryPullRequestEvidenceSource::new().with_evidence(evidence(
        HEAD,
        PullRequestLifecycle::Open,
        false,
        green_gates(),
    ));

    verify_target_gate(
        &source,
        &review_target(),
        ActionGateRequirement::for_merge(),
    )
    .await
    .expect("a green pull request clears the merge gate");
}

#[tokio::test]
async fn a_comment_proceeds_on_a_draft_as_long_as_the_head_holds() {
    let source = InMemoryPullRequestEvidenceSource::new().with_evidence(evidence(
        HEAD,
        PullRequestLifecycle::Open,
        true,
        minimal_gates(),
    ));

    verify_target_gate(
        &source,
        &review_target(),
        ActionGateRequirement::for_comment(),
    )
    .await
    .expect("a comment does not require a non-draft, mergeable pull request");
}

#[tokio::test]
async fn a_comment_is_refused_when_the_head_moved() {
    let source = InMemoryPullRequestEvidenceSource::new().with_evidence(evidence(
        "feeddeadbeef",
        PullRequestLifecycle::Open,
        false,
        minimal_gates(),
    ));

    verify_target_gate(
        &source,
        &review_target(),
        ActionGateRequirement::for_comment(),
    )
    .await
    .expect_err("a comment must not post onto a moved head");
}

fn evidence(
    head: &str,
    lifecycle: PullRequestLifecycle,
    is_draft: bool,
    gates: PullRequestMergeGates,
) -> PullRequestEvidence {
    PullRequestEvidence {
        identity: PullRequestIdentity::from_slug("example/widgets", 42),
        head_revision: head.to_owned(),
        author: None,
        viewer_login: None,
        viewer_has_approved: false,
        lifecycle,
        is_draft,
        gates,
        observed_at: "2026-07-29T00:00:00Z".to_owned(),
    }
}

fn minimal_gates() -> PullRequestMergeGates {
    PullRequestMergeGates {
        mergeability: Mergeability::Unknown,
        viewer_can_update: false,
        viewer_can_merge_as_admin: false,
        checks: Vec::new(),
        required_check_names: Vec::new(),
        review: ReviewGate {
            decision: ReviewDecision::ReviewRequired,
            current_approvals: 0,
            required_approvals: 1,
        },
    }
}

fn green_gates() -> PullRequestMergeGates {
    PullRequestMergeGates {
        mergeability: Mergeability::Mergeable,
        viewer_can_update: true,
        viewer_can_merge_as_admin: false,
        checks: vec![CheckGate {
            name: "build".to_owned(),
            state: CheckState::Success,
            details_url: None,
        }],
        required_check_names: vec!["build".to_owned()],
        review: ReviewGate {
            decision: ReviewDecision::Approved,
            current_approvals: 1,
            required_approvals: 1,
        },
    }
}

#[test]
fn approval_mutation_requires_commit_oid() {
    assert!(APPROVE_MUTATION.contains("$commitOID: GitObjectID!"));
    assert!(APPROVE_MUTATION.contains("commitOID: $commitOID"));
}

#[test]
fn every_approval_path_binds_the_target_head_sha() {
    let target = review_target();

    for operation in [DIRECT_APPROVAL_OPERATION, POLICY_APPROVAL_OPERATION] {
        let (descriptor, body) =
            approval_request(&target, operation).expect("valid approval target");

        assert_eq!(descriptor.operation, operation);
        assert_eq!(
            body.pointer("/variables/commitOID")
                .and_then(serde_json::Value::as_str),
            Some(target.head_sha.as_str())
        );
        assert_eq!(
            body.pointer("/variables/id")
                .and_then(serde_json::Value::as_str),
            Some(target.pull_request_id.as_str())
        );
    }
}

#[test]
fn every_approval_path_rejects_a_blank_target_head_sha() {
    for head_sha in ["", " \t"] {
        let mut target = review_target();
        target.head_sha = head_sha.to_owned();

        for operation in [DIRECT_APPROVAL_OPERATION, POLICY_APPROVAL_OPERATION] {
            let error = approval_request(&target, operation)
                .expect_err("approval must require an exact target head");

            assert_eq!(error.code(), "WORKFLOW_PARSE");
            assert!(error.to_string().contains("exact head commit"));
        }
    }
}

fn review_target() -> ReviewTarget {
    ReviewTarget {
        pull_request_id: "PR_kwDOexample".to_owned(),
        repository_id: "R_kwDOexample".to_owned(),
        repository: "example/widgets".to_owned(),
        number: 42,
        url: "https://github.com/example/widgets/pull/42".to_owned(),
        state: ReviewPullRequestState::Open,
        head_sha: "0123456789abcdef".to_owned(),
        mergeable: ReviewMergeableState::Mergeable,
        review_status: ReviewReviewStatus::ReviewRequired,
        check_status: ReviewCheckStatus::Success,
        flags: ReviewTargetFlags::default(),
        viewer_can_merge_as_admin: false,
        required_failed_check_names: Vec::new(),
        check_suite_ids: Vec::new(),
        has_conflict_markers: None,
        viewer_has_active_approval: None,
        auto_merge_enabled: None,
        approval_requirement_satisfied_after_viewer_approval: None,
    }
}
