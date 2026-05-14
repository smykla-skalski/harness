use std::path::PathBuf;

use super::*;
use crate::task_board::policy::{BuiltInPolicyGate, PolicyDecision, PolicyGate, PolicyReasonCode};

fn config() -> GitHubProjectConfig {
    let mut config = GitHubProjectConfig::new("smykla-skalski", "harness", PathBuf::from("."));
    config.protected_paths = vec![
        ProtectedPathRule::new("Cargo.toml"),
        ProtectedPathRule::new("src/security"),
    ];
    config
}

fn green_evidence() -> GitHubMergeEvidence {
    GitHubMergeEvidence {
        pull_request: GitHubPullRequestEvidence {
            number: 42,
            html_url: Some("https://github.com/smykla-skalski/harness/pull/42".into()),
            base_branch: "main".into(),
            head_branch: "c/task-board-policy".into(),
            draft: false,
            changed_paths: vec!["src/task_board/github/mod.rs".into()],
        },
        checks: vec![GitHubCheckEvidence::success("test")],
        reviews: vec![GitHubReviewEvidence::approved("reviewer")],
        branch_protection: GitHubBranchProtectionEvidence {
            enabled: true,
            merge_allowed: true,
            required_checks: vec!["test".into()],
        },
    }
}

fn evaluate(evidence: &GitHubMergeEvidence) -> PolicyDecision {
    let input = build_auto_merge_policy_input(&config(), evidence);
    BuiltInPolicyGate::new(40).evaluate(&input)
}

fn assert_reason(decision: PolicyDecision, expected: PolicyReasonCode) {
    let reason_code = match decision {
        PolicyDecision::Allow { reason_code, .. }
        | PolicyDecision::Deny { reason_code, .. }
        | PolicyDecision::RequireHuman { reason_code, .. }
        | PolicyDecision::RequireConsensus { reason_code, .. }
        | PolicyDecision::DryRunOnly { reason_code, .. } => reason_code,
    };
    assert_eq!(reason_code, expected);
}

#[test]
fn auto_merge_allows_when_github_evidence_is_green() {
    let evidence = green_evidence();

    assert_reason(evaluate(&evidence), PolicyReasonCode::AutoMergeAllowed);
}

#[test]
fn auto_merge_blocks_failed_checks() {
    let mut evidence = green_evidence();
    evidence.checks = vec![GitHubCheckEvidence::failure("test")];

    assert_reason(evaluate(&evidence), PolicyReasonCode::ChecksNotGreen);
}

#[test]
fn auto_merge_blocks_branch_protection_rejection() {
    let mut evidence = green_evidence();
    evidence.branch_protection.merge_allowed = false;

    assert_reason(
        evaluate(&evidence),
        PolicyReasonCode::BranchProtectionBlocked,
    );
}

#[test]
fn auto_merge_blocks_unapproved_reviewer_verdict() {
    let mut evidence = green_evidence();
    evidence.reviews = vec![GitHubReviewEvidence {
        reviewer: "reviewer".into(),
        state: GitHubReviewState::Commented,
        unresolved_requested_changes: 0,
    }];

    assert_reason(evaluate(&evidence), PolicyReasonCode::ReviewerNotApproved);
}

#[test]
fn auto_merge_blocks_unresolved_requested_changes() {
    let mut evidence = green_evidence();
    evidence.reviews = vec![GitHubReviewEvidence {
        reviewer: "reviewer".into(),
        state: GitHubReviewState::Approved,
        unresolved_requested_changes: 1,
    }];

    assert_reason(
        evaluate(&evidence),
        PolicyReasonCode::UnresolvedRequestedChanges,
    );
}

#[test]
fn auto_merge_blocks_protected_paths_with_consensus() {
    let mut evidence = green_evidence();
    evidence.pull_request.changed_paths = vec!["src/security/secrets.rs".into()];

    assert_reason(evaluate(&evidence), PolicyReasonCode::ProtectedPathTouched);
}

#[test]
fn risk_classifier_blocks_auto_merge_above_threshold() {
    let mut evidence = green_evidence();
    evidence.pull_request.changed_paths = (0..51)
        .map(|index| format!("src/task_board/generated_{index}.rs"))
        .collect();

    assert_reason(evaluate(&evidence), PolicyReasonCode::RiskAboveThreshold);
}

#[test]
fn protected_path_rule_matches_files_and_directory_children() {
    let rule = ProtectedPathRule::new("src/security");

    assert!(rule.matches("src/security/secrets.rs"));
    assert!(ProtectedPathRule::new("Cargo.toml").matches("./Cargo.toml"));
    assert!(!rule.matches("src/security_notes.md"));
}
