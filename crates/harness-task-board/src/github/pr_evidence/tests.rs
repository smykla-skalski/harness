use serde_json::{Value, json};

use crate::external::{ExternalProvider, ExternalTask, ExternalTaskRef};
use crate::types::{TaskBoardStatus, TaskBoardWorkflowKind};

use super::github_source::{PullRequestEvidenceResponse, pull_request_evidence_from_response};
use super::{
    CheckState, InMemoryPullRequestEvidenceSource, Mergeability, PullRequestEvidence,
    PullRequestEvidenceRead, PullRequestEvidenceSource, PullRequestIdentity, PullRequestLifecycle,
    PullRequestMergeGates, ReviewDecision, ReviewGate,
};

fn identity() -> PullRequestIdentity {
    PullRequestIdentity::new("octo", "harness", 7)
        .with_url(Some("https://github.com/octo/harness/pull/7".to_string()))
}

fn default_gates() -> PullRequestMergeGates {
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

fn evidence(lifecycle: PullRequestLifecycle, is_draft: bool) -> PullRequestEvidence {
    PullRequestEvidence {
        identity: identity(),
        head_revision: "deadbeef".to_string(),
        author: Some("octocat".to_string()),
        lifecycle,
        is_draft,
        gates: default_gates(),
        observed_at: "2026-07-29T00:00:00Z".to_string(),
    }
}

fn project(response: Value) -> PullRequestEvidenceRead {
    let decoded: PullRequestEvidenceResponse = serde_json::from_value(response).expect("decode");
    pull_request_evidence_from_response(&identity(), decoded, "2026-07-29T00:00:00Z".to_string())
        .expect("project")
}

#[test]
fn identity_splits_owner_and_repo() {
    let identity = identity();
    assert_eq!(identity.owner(), "octo");
    assert_eq!(identity.repo(), "harness");
    assert_eq!(identity.external_id(), "octo/harness#7");
}

#[test]
fn identity_canonicalizes_repository_casing_and_whitespace() {
    // GitHub slugs are case-insensitive, so mixed casing must not split the
    // external id a decision keys on.
    let mixed = PullRequestIdentity::new(" Octo ", " Harness ", 7);
    assert_eq!(mixed.external_id(), "octo/harness#7");
    assert_eq!(PullRequestIdentity::from_slug("Octo/Harness", 7), mixed);
}

#[test]
fn an_unparseable_slug_is_kept_verbatim_not_fabricated() {
    // A value that is not owner/repo cannot be canonicalized, so it is preserved
    // as-is rather than lowercased into a slug that looks real - it then reads as
    // an explicit miss instead of masquerading as a repository.
    let identity = PullRequestIdentity::from_slug("NotASlug", 7);
    assert_eq!(identity.repository, "NotASlug");
}

#[tokio::test]
async fn a_seeded_pull_request_reads_back_its_evidence() {
    for lifecycle in [
        PullRequestLifecycle::Open,
        PullRequestLifecycle::Closed,
        PullRequestLifecycle::Merged,
    ] {
        for is_draft in [false, true] {
            let source = InMemoryPullRequestEvidenceSource::new()
                .with_evidence(evidence(lifecycle, is_draft));
            let read = source
                .read_pull_request_evidence(&identity())
                .await
                .expect("read");
            let found = read.evidence().expect("found");
            assert_eq!(found.lifecycle, lifecycle);
            assert_eq!(found.is_draft, is_draft);
            assert_eq!(found.head_revision, "deadbeef");
        }
    }
}

#[tokio::test]
async fn an_unseeded_pull_request_reads_as_missing() {
    let source = InMemoryPullRequestEvidenceSource::new();
    let read = source
        .read_pull_request_evidence(&identity())
        .await
        .expect("read");
    assert!(read.is_missing());
    assert!(read.evidence().is_none());
}

#[tokio::test]
async fn a_provider_failure_stays_distinct_from_a_missing_pull_request() {
    let source = InMemoryPullRequestEvidenceSource::new().with_failure(&identity(), "graphql 502");
    let error = source
        .read_pull_request_evidence(&identity())
        .await
        .expect_err("provider failure surfaces as Err, never a Missing read");
    assert!(error.to_string().contains("graphql 502"));
}

#[test]
fn the_projection_reads_a_found_pull_request() {
    let read = project(json!({
        "repository": {
            "pullRequest": {
                "number": 7,
                "url": "https://github.com/octo/harness/pull/7",
                "headRefOid": "cafef00d",
                "isDraft": false,
                "state": "OPEN",
                "author": { "login": "octocat" }
            }
        }
    }));
    let found = read.evidence().expect("found");
    assert_eq!(found.identity.external_id(), "octo/harness#7");
    assert_eq!(found.head_revision, "cafef00d");
    assert_eq!(found.author.as_deref(), Some("octocat"));
    assert_eq!(found.lifecycle, PullRequestLifecycle::Open);
    assert!(found.is_open());
}

#[test]
fn a_null_repository_node_is_a_missing_read() {
    let read = project(json!({ "repository": Value::Null }));
    assert!(read.is_missing());
}

#[test]
fn a_null_pull_request_node_is_a_missing_read() {
    let read = project(json!({ "repository": { "pullRequest": Value::Null } }));
    assert!(read.is_missing());
}

#[test]
fn an_omitted_pull_request_field_is_a_missing_read() {
    // GitHub returning the field as absent rather than null must still project
    // to Missing, not a deserialization error.
    let read = project(json!({ "repository": {} }));
    assert!(read.is_missing());
}

#[test]
fn a_mismatched_pull_request_number_is_a_parse_error() {
    let decoded: PullRequestEvidenceResponse = serde_json::from_value(json!({
        "repository": {
            "pullRequest": {
                "number": 99,
                "headRefOid": "cafef00d",
                "isDraft": false,
                "state": "OPEN",
                "author": Value::Null
            }
        }
    }))
    .expect("decode");
    // identity() asks for #7; a response for #99 must never silently rebind.
    let error = pull_request_evidence_from_response(&identity(), decoded, "t".to_string())
        .expect_err("mismatched number errors");
    assert!(error.to_string().contains("#99"));
}

#[test]
fn a_missing_node_url_falls_back_to_the_requested_url() {
    let read = project(json!({
        "repository": {
            "pullRequest": {
                "number": 7,
                "headRefOid": "cafef00d",
                "isDraft": true,
                "state": "MERGED",
                "author": Value::Null
            }
        }
    }));
    let found = read.evidence().expect("found");
    assert_eq!(
        found.identity.url.as_deref(),
        Some("https://github.com/octo/harness/pull/7")
    );
    assert_eq!(found.author, None);
    assert_eq!(found.lifecycle, PullRequestLifecycle::Merged);
}

#[test]
fn an_unrecognized_state_is_a_parse_error() {
    let decoded: PullRequestEvidenceResponse = serde_json::from_value(json!({
        "repository": {
            "pullRequest": {
                "number": 7,
                "headRefOid": "cafef00d",
                "isDraft": false,
                "state": "LIMBO",
                "author": Value::Null
            }
        }
    }))
    .expect("decode");
    let error = pull_request_evidence_from_response(&identity(), decoded, "t".to_string())
        .expect_err("err");
    assert!(error.to_string().contains("LIMBO"));
}

// Discovery represents a pull request as an `ExternalTask`; execution reads it
// as `PullRequestEvidence`. This pins the shared identity contract: for one
// observed revision the two representations agree on external id, url, head, and
// author. It asserts the format contract with representative values, not the
// discovery code path itself.
#[test]
fn external_task_and_evidence_share_identity_facts() {
    let discovered = ExternalTask {
        reference: ExternalTaskRef::new(ExternalProvider::GitHub, "octo/harness#7")
            .with_url("https://github.com/octo/harness/pull/7"),
        status: TaskBoardStatus::Inbox,
        workflow_kind: TaskBoardWorkflowKind::PrReview,
        pr_head_revision: Some("cafef00d".to_string()),
        pr_author: Some("octocat".to_string()),
        ..ExternalTask::default()
    };

    let read = project(json!({
        "repository": {
            "pullRequest": {
                "number": 7,
                "url": "https://github.com/octo/harness/pull/7",
                "headRefOid": "cafef00d",
                "isDraft": false,
                "state": "OPEN",
                "author": { "login": "octocat" }
            }
        }
    }));
    let executed = read.evidence().expect("found");

    assert_eq!(
        executed.identity.external_id(),
        discovered.reference.external_id
    );
    assert_eq!(executed.identity.url, discovered.reference.url);
    assert_eq!(
        Some(executed.head_revision.clone()),
        discovered.pr_head_revision
    );
    assert_eq!(executed.author, discovered.pr_author);
}

fn gated_response(overrides: Value) -> Value {
    let mut pull_request = json!({
        "number": 7,
        "url": "https://github.com/octo/harness/pull/7",
        "headRefOid": "cafef00d",
        "isDraft": false,
        "state": "OPEN",
        "author": { "login": "octocat" }
    });
    let (Value::Object(target), Value::Object(extra)) = (&mut pull_request, overrides) else {
        panic!("overrides must be an object");
    };
    target.extend(extra);
    json!({ "repository": { "pullRequest": pull_request } })
}

#[test]
fn the_projection_captures_the_merge_and_review_gates() {
    let read = project(gated_response(json!({
        "mergeable": "CONFLICTING",
        "viewerCanUpdate": true,
        "viewerCanMergeAsAdmin": true,
        "reviewDecision": "CHANGES_REQUESTED"
    })));
    let gates = &read.evidence().expect("found").gates;

    assert_eq!(gates.mergeability, Mergeability::Conflicting);
    assert!(gates.viewer_can_update);
    assert!(gates.viewer_can_merge_as_admin);
    assert_eq!(gates.review.decision, ReviewDecision::ChangesRequested);
}

#[test]
fn the_projection_captures_each_check_state() {
    let read = project(gated_response(json!({
        "commits": { "nodes": [ { "commit": { "statusCheckRollup": { "contexts": { "nodes": [
            { "__typename": "CheckRun", "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS" },
            { "__typename": "CheckRun", "name": "lint", "status": "IN_PROGRESS", "conclusion": Value::Null },
            { "__typename": "CheckRun", "name": "flaky", "status": "COMPLETED", "conclusion": "FAILURE", "detailsUrl": "https://github.com/octo/harness/actions/runs/17" },
            { "__typename": "CheckRun", "name": "optional", "status": "COMPLETED", "conclusion": "SKIPPED" },
            { "__typename": "StatusContext", "context": "legacy-ci", "state": "PENDING" }
        ] } } } } ] }
    })));
    let gates = &read.evidence().expect("found").gates;

    assert_eq!(gates.check_state("build"), Some(CheckState::Success));
    assert_eq!(gates.check_state("lint"), Some(CheckState::Pending));
    assert_eq!(gates.check_state("flaky"), Some(CheckState::Failure));
    assert_eq!(
        gates
            .checks
            .iter()
            .find(|check| check.name == "flaky")
            .and_then(|check| check.details_url.as_deref()),
        Some("https://github.com/octo/harness/actions/runs/17")
    );
    assert_eq!(gates.check_state("optional"), Some(CheckState::Skipped));
    assert_eq!(gates.check_state("legacy-ci"), Some(CheckState::Pending));
}

#[test]
fn gate_predicates_reflect_conflict_and_changes_requested() {
    let mut gates = default_gates();
    gates.mergeability = Mergeability::Conflicting;
    gates.review.decision = ReviewDecision::ChangesRequested;
    assert!(gates.has_conflicts());
    assert!(!gates.is_mergeable());
    assert!(gates.review.changes_requested());
}

#[test]
fn an_unknown_mergeability_never_reads_as_mergeable() {
    let read = project(gated_response(json!({ "mergeable": "UNKNOWN" })));
    let gates = &read.evidence().expect("found").gates;
    assert_eq!(gates.mergeability, Mergeability::Unknown);
    assert!(!gates.is_mergeable());
    assert!(!gates.mergeability_known());
    assert!(!gates.has_conflicts());
}

#[test]
fn an_absent_mergeable_field_is_unknown_not_safe() {
    // A pull request GitHub is still computing reports no `mergeable` value.
    let read = project(gated_response(json!({})));
    let gates = &read.evidence().expect("found").gates;
    assert_eq!(gates.mergeability, Mergeability::Unknown);
    assert!(!gates.is_mergeable());
}

#[test]
fn a_missing_required_check_blocks_the_gate() {
    let read = project(gated_response(json!({
        "commits": { "nodes": [ { "commit": { "statusCheckRollup": { "contexts": { "nodes": [
            { "__typename": "CheckRun", "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS" }
        ] } } } } ] },
        "baseRef": { "branchProtectionRule": {
            "requiredStatusCheckContexts": ["build", "deploy"],
            "requiredStatusChecks": []
        } }
    })));
    let gates = &read.evidence().expect("found").gates;
    assert!(!gates.required_checks_satisfied());
    assert_eq!(gates.missing_required_checks(), vec!["deploy"]);
    assert!(gates.unsatisfied_required_checks().is_empty());
}

#[test]
fn a_pending_required_check_is_unsatisfied_but_not_missing() {
    let read = project(gated_response(json!({
        "commits": { "nodes": [ { "commit": { "statusCheckRollup": { "contexts": { "nodes": [
            { "__typename": "CheckRun", "name": "build", "status": "IN_PROGRESS", "conclusion": Value::Null }
        ] } } } } ] },
        "baseRef": { "branchProtectionRule": { "requiredStatusCheckContexts": ["build"], "requiredStatusChecks": [] } }
    })));
    let gates = &read.evidence().expect("found").gates;
    assert!(!gates.required_checks_satisfied());
    assert!(gates.missing_required_checks().is_empty());
    assert_eq!(gates.unsatisfied_required_checks(), vec!["build"]);
}

#[test]
fn current_approvals_counts_the_latest_decisive_review_per_author() {
    let read = project(gated_response(json!({
        "reviews": { "nodes": [
            { "state": "APPROVED", "submittedAt": "2026-07-01T00:00:00Z", "author": { "login": "ann" } },
            { "state": "CHANGES_REQUESTED", "submittedAt": "2026-07-02T00:00:00Z", "author": { "login": "ann" } },
            { "state": "COMMENTED", "submittedAt": "2026-07-03T00:00:00Z", "author": { "login": "ann" } },
            { "state": "APPROVED", "submittedAt": "2026-07-01T00:00:00Z", "author": { "login": "bob" } }
        ] }
    })));
    let gates = &read.evidence().expect("found").gates;
    // Ann's approval was superseded by a later change request; Bob still approves.
    assert_eq!(gates.review.current_approvals, 1);
}

#[test]
fn a_review_gate_needs_enough_current_approvals() {
    let satisfied = ReviewGate {
        decision: ReviewDecision::Approved,
        current_approvals: 2,
        required_approvals: 2,
    };
    assert!(satisfied.is_satisfied());

    let short = ReviewGate {
        decision: ReviewDecision::Approved,
        current_approvals: 1,
        required_approvals: 2,
    };
    assert!(!short.is_satisfied());

    let unknown = ReviewGate {
        decision: ReviewDecision::Unknown,
        current_approvals: 5,
        required_approvals: 1,
    };
    assert!(!unknown.is_satisfied());
}
