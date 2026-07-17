use super::*;
use crate::task_board::{AgentMode, TaskBoardOrchestratorWorkflow};

fn profile(id: &str, runtime: &str) -> TaskBoardReviewerProfile {
    TaskBoardReviewerProfile {
        id: id.into(),
        runtime: runtime.into(),
        persona: "code-reviewer".into(),
        agent_mode: AgentMode::Evaluate,
        model: None,
        effort: None,
    }
}

fn rule(
    repository: Option<&str>,
    reviewer_count: u32,
    required_approvals: u32,
    profiles: Vec<TaskBoardReviewerProfile>,
) -> TaskBoardReviewerRule {
    TaskBoardReviewerRule {
        workflow: TaskBoardOrchestratorWorkflow::DefaultTask,
        repository: repository.map(str::to_owned),
        reviewer_count,
        required_approvals,
        profiles,
    }
}

fn settings() -> TaskBoardReviewerSettings {
    TaskBoardReviewerSettings {
        reviewer_count: 1,
        required_approvals: 1,
        max_revision_cycles: 3,
        profiles: vec![profile("global", "runtime-alpha")],
        overrides: vec![
            rule(None, 1, 1, vec![profile("workflow", "runtime-beta")]),
            rule(
                Some("sample/widgets"),
                2,
                2,
                vec![
                    profile("exact-a", "runtime-alpha"),
                    profile("exact-b", "runtime-beta"),
                ],
            ),
        ],
    }
}

fn outcome(
    profile_id: &str,
    verdict: TaskBoardPhaseVerdict,
    head_revision: &str,
) -> TaskBoardReviewerOutcome {
    TaskBoardReviewerOutcome {
        profile_id: profile_id.into(),
        result: TaskBoardReviewResult {
            verdict,
            head_revision: head_revision.into(),
            summary: "review complete".into(),
            findings: Vec::new(),
        },
    }
}

#[test]
fn reviewer_resolution_uses_repository_then_workflow_then_global_precedence() {
    let settings = settings();

    let exact = resolve_task_board_reviewers(
        &settings,
        TaskBoardWorkflowKind::DefaultTask,
        Some("sample/widgets"),
    )
    .expect("resolve exact");
    let workflow = resolve_task_board_reviewers(
        &settings,
        TaskBoardWorkflowKind::DefaultTask,
        Some("sample/other"),
    )
    .expect("resolve workflow");
    let global = resolve_task_board_reviewers(
        &settings,
        TaskBoardWorkflowKind::PrFix,
        Some("sample/widgets"),
    )
    .expect("resolve global");

    assert_eq!(exact.profiles[0].id, "exact-a");
    assert_eq!(exact.reviewer_count, 2);
    assert_eq!(workflow.profiles[0].id, "workflow");
    assert_eq!(global.profiles[0].id, "global");
}

#[test]
fn duplicate_override_at_same_precedence_is_rejected() {
    let mut settings = settings();
    settings.overrides.push(rule(
        Some("sample/widgets"),
        1,
        1,
        vec![profile("extra", "runtime-gamma")],
    ));

    assert!(matches!(
        resolve_task_board_reviewers(
            &settings,
            TaskBoardWorkflowKind::DefaultTask,
            Some("sample/widgets"),
        ),
        Err(TaskBoardReviewerResolutionError::AmbiguousOverride { .. })
    ));
}

#[test]
fn invalid_count_quorum_cycle_and_profile_configuration_fail_closed() {
    let mut settings = settings();
    settings.overrides.clear();
    settings.reviewer_count = 2;
    settings.required_approvals = 3;
    assert_eq!(
        resolve_task_board_reviewers(&settings, TaskBoardWorkflowKind::DefaultTask, None),
        Err(TaskBoardReviewerResolutionError::InvalidQuorum)
    );

    settings.required_approvals = 1;
    settings.max_revision_cycles = 4;
    assert_eq!(
        resolve_task_board_reviewers(&settings, TaskBoardWorkflowKind::DefaultTask, None),
        Err(TaskBoardReviewerResolutionError::InvalidRevisionCycles)
    );

    settings.max_revision_cycles = 3;
    settings.profiles = vec![
        profile("same-profile", "runtime-alpha"),
        profile("same-profile", "runtime-beta"),
    ];
    assert_eq!(
        resolve_task_board_reviewers(&settings, TaskBoardWorkflowKind::DefaultTask, None),
        Err(TaskBoardReviewerResolutionError::DuplicateProfileId {
            profile_id: "same-profile".into(),
        })
    );
}

#[test]
fn distinct_profiles_may_share_one_runtime() {
    let mut settings = settings();
    settings.overrides.clear();
    settings.reviewer_count = 2;
    let mut second = profile("reviewer-indigo", "runtime-shared");
    second.persona = "risk-reviewer".into();
    second.model = Some("model-indigo".into());
    second.effort = Some("high".into());
    settings.profiles = vec![profile("reviewer-amber", "runtime-shared"), second];

    let resolved =
        resolve_task_board_reviewers(&settings, TaskBoardWorkflowKind::DefaultTask, None)
            .expect("resolve shared runtime");

    assert_eq!(resolved.profiles.len(), 2);
    assert_eq!(resolved.profiles[0].runtime, resolved.profiles[1].runtime);
}

#[test]
fn review_round_waits_until_quorum_then_approves_exact_head() {
    let resolved = resolve_task_board_reviewers(
        &settings(),
        TaskBoardWorkflowKind::DefaultTask,
        Some("sample/widgets"),
    )
    .expect("resolve reviewers");
    let first = outcome("exact-a", TaskBoardPhaseVerdict::Pass, "abcdef1");

    let pending =
        evaluate_task_board_review_round(&resolved, "abcdef1", 1, std::slice::from_ref(&first))
            .expect("evaluate pending");
    let approved = evaluate_task_board_review_round(
        &resolved,
        "abcdef1",
        1,
        &[
            first,
            outcome("exact-b", TaskBoardPhaseVerdict::Pass, "abcdef1"),
        ],
    )
    .expect("evaluate approved");

    assert_eq!(
        pending.decision,
        TaskBoardReviewRoundDecision::AwaitingReviewers
    );
    assert_eq!(approved.decision, TaskBoardReviewRoundDecision::Approved);
    assert_eq!(approved.approvals, 2);
}

#[test]
fn changes_return_to_implementation_until_third_cycle_then_require_human() {
    let resolved = resolve_task_board_reviewers(
        &settings(),
        TaskBoardWorkflowKind::DefaultTask,
        Some("sample/widgets"),
    )
    .expect("resolve reviewers");
    let outcomes = [
        outcome("exact-a", TaskBoardPhaseVerdict::ChangesRequired, "abcdef1"),
        outcome("exact-b", TaskBoardPhaseVerdict::ChangesRequired, "abcdef1"),
    ];

    let retry = evaluate_task_board_review_round(&resolved, "abcdef1", 2, &outcomes)
        .expect("evaluate retry");
    let exhausted = evaluate_task_board_review_round(&resolved, "abcdef1", 3, &outcomes)
        .expect("evaluate exhausted");

    assert_eq!(
        retry.decision,
        TaskBoardReviewRoundDecision::ChangesRequired
    );
    assert_eq!(
        exhausted.decision,
        TaskBoardReviewRoundDecision::HumanRequired
    );
}

#[test]
fn changes_required_vetoes_a_met_approval_quorum() {
    let mut settings = settings();
    settings.overrides.clear();
    settings.reviewer_count = 2;
    settings.required_approvals = 1;
    settings.profiles = vec![
        profile("reviewer-amber", "runtime-alpha"),
        profile("reviewer-indigo", "runtime-beta"),
    ];
    let resolved =
        resolve_task_board_reviewers(&settings, TaskBoardWorkflowKind::DefaultTask, None)
            .expect("resolve reviewers");
    let outcomes = [
        outcome("reviewer-amber", TaskBoardPhaseVerdict::Pass, "abcdef1"),
        outcome(
            "reviewer-indigo",
            TaskBoardPhaseVerdict::ChangesRequired,
            "abcdef1",
        ),
    ];

    let retry = evaluate_task_board_review_round(&resolved, "abcdef1", 1, &outcomes)
        .expect("evaluate retry");
    let exhausted = evaluate_task_board_review_round(&resolved, "abcdef1", 3, &outcomes)
        .expect("evaluate exhausted");

    assert_eq!(retry.approvals, 1);
    assert_eq!(
        retry.decision,
        TaskBoardReviewRoundDecision::ChangesRequired
    );
    assert_eq!(
        exhausted.decision,
        TaskBoardReviewRoundDecision::HumanRequired
    );
}

#[test]
fn met_quorum_waits_for_remaining_reviewer_vetoes() {
    let mut settings = settings();
    settings.overrides.clear();
    settings.reviewer_count = 2;
    settings.required_approvals = 1;
    settings.profiles = vec![
        profile("reviewer-amber", "runtime-alpha"),
        profile("reviewer-indigo", "runtime-beta"),
    ];
    let resolved =
        resolve_task_board_reviewers(&settings, TaskBoardWorkflowKind::DefaultTask, None)
            .expect("resolve reviewers");
    let outcomes = [outcome(
        "reviewer-amber",
        TaskBoardPhaseVerdict::Pass,
        "abcdef1",
    )];

    let evaluation = evaluate_task_board_review_round(&resolved, "abcdef1", 1, &outcomes)
        .expect("evaluate pending veto window");

    assert_eq!(
        evaluation.decision,
        TaskBoardReviewRoundDecision::AwaitingReviewers
    );
}

#[test]
fn stale_head_and_duplicate_reviewer_outcomes_are_rejected() {
    let resolved = resolve_task_board_reviewers(
        &settings(),
        TaskBoardWorkflowKind::DefaultTask,
        Some("sample/widgets"),
    )
    .expect("resolve reviewers");
    let stale = [outcome("exact-a", TaskBoardPhaseVerdict::Pass, "abcdef0")];
    assert!(matches!(
        evaluate_task_board_review_round(&resolved, "abcdef1", 1, &stale),
        Err(TaskBoardReviewerResolutionError::HeadRevisionMismatch { .. })
    ));

    let duplicate = [
        outcome("exact-a", TaskBoardPhaseVerdict::Pass, "abcdef1"),
        outcome("exact-a", TaskBoardPhaseVerdict::Pass, "abcdef1"),
    ];
    assert!(matches!(
        evaluate_task_board_review_round(&resolved, "abcdef1", 1, &duplicate),
        Err(TaskBoardReviewerResolutionError::DuplicateOutcome { .. })
    ));
}

#[test]
fn human_required_verdict_stops_review_immediately() {
    let resolved = TaskBoardResolvedReviewer {
        reviewer_count: 1,
        required_approvals: 1,
        max_revision_cycles: 3,
        profiles: vec![profile("global", "runtime-alpha")],
    };
    let outcomes = [outcome(
        "global",
        TaskBoardPhaseVerdict::HumanRequired,
        "abcdef1",
    )];

    let evaluation = evaluate_task_board_review_round(&resolved, "abcdef1", 1, &outcomes)
        .expect("evaluate human required");

    assert_eq!(
        evaluation.decision,
        TaskBoardReviewRoundDecision::HumanRequired
    );
}
