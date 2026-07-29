use super::super::gates::{
    CheckGate, CheckState, Mergeability, PullRequestMergeGates, ReviewDecision, ReviewGate,
};
use super::super::{
    InMemoryPullRequestEvidenceSource, PullRequestEvidence, PullRequestEvidenceRead,
    PullRequestIdentity, PullRequestLifecycle,
};
use super::{
    ActionGateBlock, ActionGateDecision, ActionGateRequirement, evaluate_action_gates,
    verify_action_gates,
};

const HEAD: &str = "aaa";

fn identity() -> PullRequestIdentity {
    PullRequestIdentity::new("octo", "harness", 7)
}

fn mergeable_evidence() -> PullRequestEvidence {
    PullRequestEvidence {
        identity: identity(),
        head_revision: HEAD.to_string(),
        author: Some("octocat".to_string()),
        lifecycle: PullRequestLifecycle::Open,
        is_draft: false,
        gates: PullRequestMergeGates {
            mergeability: Mergeability::Mergeable,
            viewer_can_update: true,
            viewer_can_merge_as_admin: true,
            checks: vec![CheckGate {
                name: "build".to_string(),
                state: CheckState::Success,
                details_url: None,
            }],
            required_check_names: vec!["build".to_string()],
            review: ReviewGate {
                decision: ReviewDecision::Approved,
                current_approvals: 2,
                required_approvals: 2,
            },
        },
        observed_at: "2026-07-29T00:00:00Z".to_string(),
    }
}

fn merge(read: &PullRequestEvidenceRead) -> ActionGateDecision {
    evaluate_action_gates(read, HEAD, ActionGateRequirement::for_merge())
}

fn found(evidence: PullRequestEvidence) -> PullRequestEvidenceRead {
    PullRequestEvidenceRead::found(evidence)
}

#[test]
fn a_fully_satisfied_pull_request_proceeds() {
    let decision = merge(&found(mergeable_evidence()));
    assert!(decision.is_clear());
    assert!(decision.blocks().is_empty());
}

#[test]
fn a_missing_pull_request_blocks() {
    let decision = merge(&PullRequestEvidenceRead::missing(
        identity(),
        "2026-07-29T00:00:00Z".to_string(),
    ));
    assert_eq!(decision.blocks(), &[ActionGateBlock::PullRequestMissing]);
}

#[test]
fn a_moved_head_blocks_before_any_other_gate() {
    let mut evidence = mergeable_evidence();
    evidence.head_revision = "bbb".to_string();
    // Even though every gate passes, the verified head no longer matches.
    let decision = merge(&found(evidence));
    assert_eq!(
        decision.blocks(),
        &[ActionGateBlock::HeadMoved {
            expected: HEAD.to_string(),
            observed: "bbb".to_string(),
        }]
    );
}

#[test]
fn a_draft_blocks() {
    let mut evidence = mergeable_evidence();
    evidence.is_draft = true;
    assert!(
        merge(&found(evidence))
            .blocks()
            .contains(&ActionGateBlock::Draft)
    );
}

#[test]
fn a_closed_pull_request_blocks_as_not_open() {
    let mut evidence = mergeable_evidence();
    evidence.lifecycle = PullRequestLifecycle::Closed;
    assert!(
        merge(&found(evidence))
            .blocks()
            .contains(&ActionGateBlock::NotOpen(PullRequestLifecycle::Closed))
    );
}

#[test]
fn a_conflict_blocks() {
    let mut evidence = mergeable_evidence();
    evidence.gates.mergeability = Mergeability::Conflicting;
    assert!(
        merge(&found(evidence))
            .blocks()
            .contains(&ActionGateBlock::Conflicts)
    );
}

#[test]
fn an_unknown_mergeability_blocks() {
    let mut evidence = mergeable_evidence();
    evidence.gates.mergeability = Mergeability::Unknown;
    assert!(
        merge(&found(evidence))
            .blocks()
            .contains(&ActionGateBlock::MergeabilityUnknown)
    );
}

#[test]
fn an_incomplete_required_check_blocks() {
    let mut evidence = mergeable_evidence();
    evidence.gates.checks[0].state = CheckState::Pending;
    let decision = merge(&found(evidence));
    assert!(decision.blocks().iter().any(|block| matches!(
        block,
        ActionGateBlock::RequiredChecksIncomplete { unsatisfied, .. } if unsatisfied == &["build"]
    )));
}

#[test]
fn missing_approvals_block() {
    let mut evidence = mergeable_evidence();
    evidence.gates.review.current_approvals = 1;
    let decision = merge(&found(evidence));
    assert!(decision.blocks().iter().any(|block| matches!(
        block,
        ActionGateBlock::ApprovalsMissing {
            current: 1,
            required: 2,
            ..
        }
    )));
}

#[test]
fn no_edit_or_admin_merge_blocks_on_permission() {
    let mut evidence = mergeable_evidence();
    evidence.gates.viewer_can_update = false;
    evidence.gates.viewer_can_merge_as_admin = false;
    assert!(
        merge(&found(evidence))
            .blocks()
            .contains(&ActionGateBlock::WritePermissionMissing)
    );
}

#[test]
fn an_admin_merger_without_edit_access_still_proceeds() {
    // A fork pull request: the viewer cannot push to the head branch but can
    // merge as an admin, so the permission gate must not block.
    let mut evidence = mergeable_evidence();
    evidence.gates.viewer_can_update = false;
    evidence.gates.viewer_can_merge_as_admin = true;
    assert!(merge(&found(evidence)).is_clear());
}

#[test]
fn every_failing_gate_is_reported_together() {
    let mut evidence = mergeable_evidence();
    evidence.is_draft = true;
    evidence.gates.mergeability = Mergeability::Conflicting;
    evidence.gates.review.current_approvals = 0;
    let decision = merge(&found(evidence));
    // A caller sees all reasons at once, not just the first.
    assert!(decision.blocks().len() >= 3);
    assert!(!decision.is_clear());
}

#[test]
fn an_approval_ignores_merge_only_gates() {
    let mut evidence = mergeable_evidence();
    // Failing checks and missing approvals must not block an approval action,
    // only a merge.
    evidence.gates.checks[0].state = CheckState::Failure;
    evidence.gates.review.current_approvals = 0;
    let decision = evaluate_action_gates(
        &found(evidence),
        HEAD,
        ActionGateRequirement::for_approval(),
    );
    assert!(decision.is_clear());
}

#[test]
fn an_approval_still_blocks_a_draft() {
    let mut evidence = mergeable_evidence();
    evidence.is_draft = true;
    let decision = evaluate_action_gates(
        &found(evidence),
        HEAD,
        ActionGateRequirement::for_approval(),
    );
    assert!(decision.blocks().contains(&ActionGateBlock::Draft));
}

#[tokio::test]
async fn the_driver_reads_fresh_and_proceeds() {
    let source = InMemoryPullRequestEvidenceSource::new().with_evidence(mergeable_evidence());
    let decision = verify_action_gates(
        &source,
        &identity(),
        HEAD,
        ActionGateRequirement::for_merge(),
    )
    .await
    .expect("verify");
    assert!(decision.is_clear());
}

#[tokio::test]
async fn the_driver_blocks_a_vanished_pull_request_without_erroring() {
    let source = InMemoryPullRequestEvidenceSource::new();
    let decision = verify_action_gates(
        &source,
        &identity(),
        HEAD,
        ActionGateRequirement::for_merge(),
    )
    .await
    .expect("verify");
    assert_eq!(decision.blocks(), &[ActionGateBlock::PullRequestMissing]);
}

#[tokio::test]
async fn the_driver_propagates_a_provider_failure() {
    let source = InMemoryPullRequestEvidenceSource::new().with_failure(&identity(), "graphql 502");
    let error = verify_action_gates(
        &source,
        &identity(),
        HEAD,
        ActionGateRequirement::for_merge(),
    )
    .await
    .expect_err("provider failure surfaces as Err");
    assert!(error.to_string().contains("graphql 502"));
}
