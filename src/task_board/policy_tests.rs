//! Unit tests for the built-in policy gate and additive wire types.

use super::*;
use crate::task_board::types::{AgentMode, TaskBoardPriority};

fn gate() -> BuiltInPolicyGate {
    BuiltInPolicyGate::new(40)
}

fn merge_input(evidence: PolicyEvidence) -> PolicyInput {
    PolicyInput::new(PolicyAction::MergePr).with_evidence(evidence)
}

fn green_merge_evidence() -> PolicyEvidence {
    PolicyEvidence {
        checks_green: Some(true),
        branch_protection_allows_merge: Some(true),
        reviewer_verdict_approved: Some(true),
        unresolved_requested_changes: Some(0),
        protected_path_touched: Some(false),
        risk_score: Some(20),
        ..PolicyEvidence::default()
    }
}

#[test]
fn subject_and_input_enrichment_fields_are_present_and_optional() {
    let subject = PolicySubject {
        task_board_item_id: Some("task-1".to_owned()),
        tags: vec!["cli".to_owned(), "board".to_owned()],
        priority: Some(TaskBoardPriority::High),
        agent_mode: Some(AgentMode::Headless),
        target_project_types: vec!["kuma".to_owned()],
        ..PolicySubject::default()
    };
    let input = PolicyInput {
        evaluated_at: Some("2026-07-13T00:00:00Z".to_owned()),
        ..PolicyInput::new(PolicyAction::SpawnAgent)
    }
    .with_subject(subject);
    assert_eq!(input.subject.tags, ["cli", "board"]);
    assert_eq!(input.subject.priority, Some(TaskBoardPriority::High));
    assert_eq!(input.subject.agent_mode, Some(AgentMode::Headless));
    assert_eq!(input.subject.target_project_types, ["kuma"]);
    assert_eq!(input.evaluated_at.as_deref(), Some("2026-07-13T00:00:00Z"));
}

#[test]
fn old_recorded_input_without_enrichment_still_deserializes() {
    // A decision recorded before WP3 enrichment: no tags/priority/agent_mode/
    // target_project_types on the subject and no evaluated_at on the input.
    let legacy = serde_json::json!({
        "action": "spawn_agent",
        "subject": { "task_board_item_id": "task-legacy" },
        "evidence": {}
    });
    let input: PolicyInput =
        serde_json::from_value(legacy).expect("legacy policy input deserializes");
    assert_eq!(input.action, PolicyAction::SpawnAgent);
    assert_eq!(
        input.subject.task_board_item_id.as_deref(),
        Some("task-legacy")
    );
    assert!(input.subject.tags.is_empty());
    assert!(input.subject.priority.is_none());
    assert!(input.subject.agent_mode.is_none());
    assert!(input.subject.target_project_types.is_empty());
    assert!(input.evaluated_at.is_none());
}

#[test]
fn default_policy_allows_push_open_pr_and_spawn_agent() {
    for action in [
        PolicyAction::PushBranch,
        PolicyAction::OpenPr,
        PolicyAction::SpawnAgent,
    ] {
        let input = PolicyInput::new(action);

        assert_eq!(
            gate().evaluate(&input),
            allow(PolicyReasonCode::DefaultAllow)
        );
    }
}

#[test]
fn auto_merge_allows_when_all_evidence_is_green() {
    let input = merge_input(green_merge_evidence());

    assert_eq!(
        gate().evaluate(&input),
        allow(PolicyReasonCode::AutoMergeAllowed)
    );
}

#[test]
fn secrets_and_destructive_fs_require_human() {
    for action in [PolicyAction::AccessSecret, PolicyAction::DestructiveFs] {
        let input = PolicyInput::new(action);

        assert_eq!(
            gate().evaluate(&input),
            require_human(PolicyReasonCode::HumanRequired)
        );
    }
}

#[test]
fn protected_merge_paths_require_consensus() {
    let mut evidence = green_merge_evidence();
    evidence.protected_path_touched = Some(true);
    let input = merge_input(evidence);

    assert_eq!(
        gate().evaluate(&input),
        require_consensus(PolicyReasonCode::ProtectedPathTouched)
    );
}

#[test]
fn repo_mutation_is_dry_run_only_by_default() {
    let input = PolicyInput::new(PolicyAction::MutateRepo);

    assert_eq!(
        gate().evaluate(&input),
        dry_run_only(PolicyReasonCode::DryRunRequired)
    );
}

#[test]
fn incomplete_merge_evidence_requires_human() {
    let input = merge_input(PolicyEvidence::default());

    assert_eq!(
        gate().evaluate(&input),
        require_human(PolicyReasonCode::MissingMergeEvidence)
    );
}

#[test]
fn auto_merge_blocks_when_checks_are_not_green() {
    let mut evidence = green_merge_evidence();
    evidence.checks_green = Some(false);
    let input = merge_input(evidence);

    assert_eq!(
        gate().evaluate(&input),
        deny(PolicyReasonCode::ChecksNotGreen)
    );
}

#[test]
fn auto_merge_blocks_when_branch_protection_rejects_merge() {
    let mut evidence = green_merge_evidence();
    evidence.branch_protection_allows_merge = Some(false);
    let input = merge_input(evidence);

    assert_eq!(
        gate().evaluate(&input),
        deny(PolicyReasonCode::BranchProtectionBlocked)
    );
}

#[test]
fn auto_merge_blocks_without_approved_review_verdict() {
    let mut evidence = green_merge_evidence();
    evidence.reviewer_verdict_approved = Some(false);
    let input = merge_input(evidence);

    assert_eq!(
        gate().evaluate(&input),
        deny(PolicyReasonCode::ReviewerNotApproved)
    );
}

#[test]
fn auto_merge_blocks_unresolved_requested_changes() {
    let mut evidence = green_merge_evidence();
    evidence.unresolved_requested_changes = Some(1);
    let input = merge_input(evidence);

    assert_eq!(
        gate().evaluate(&input),
        deny(PolicyReasonCode::UnresolvedRequestedChanges)
    );
}

#[test]
fn auto_merge_blocks_high_risk_as_dry_run_only() {
    let mut evidence = green_merge_evidence();
    evidence.risk_score = Some(41);
    let input = merge_input(evidence);

    assert_eq!(
        gate().evaluate(&input),
        dry_run_only(PolicyReasonCode::RiskAboveThreshold)
    );
}
