use super::*;
use crate::github::{CheckGate, Mergeability, PullRequestIdentity, ReviewDecision, ReviewGate};
use crate::{
    TaskBoardDependencyApprovalEvidence, TaskBoardDependencyCheck, TaskBoardDependencyCheckState,
    TaskBoardDependencyConflictEvidence, TaskBoardDependencyConflictState,
    TaskBoardDependencyIdentity, TaskBoardDependencyTriageDisposition,
    TaskBoardDependencyTriageStep, TaskBoardDependencyUpdateClass,
};

const ORIGINAL_HEAD: &str = "0123456789abcdef0123456789abcdef01234567";
const FIXER_HEAD: &str = "123456789abcdef0123456789abcdef012345678";
const REMOTE_HEAD: &str = "23456789abcdef0123456789abcdef0123456789";
const LATER_HEAD: &str = "3456789abcdef0123456789abcdef0123456789a";

#[test]
fn request_binds_original_context_fix_ci_diff_and_current_gates() {
    let request = request().expect("valid reverification request");

    assert_eq!(request.original_turn_id, "deepseek-turn-1");
    assert_eq!(request.original_triage.exact_head_revision, ORIGINAL_HEAD);
    assert_eq!(request.fixer_result.head_revision, FIXER_HEAD);
    assert_eq!(request.exact_head_revision, REMOTE_HEAD);
    assert!(request.diff.contains("+fixed"));
    assert_eq!(
        request.verification_id,
        format!("route-1:verify:{REMOTE_HEAD}")
    );
    let prompt =
        render_task_board_dependency_reverification_prompt(&request).expect("rendered prompt");
    for expected in [
        "Resume dependency review context deepseek-turn-1",
        ORIGINAL_HEAD,
        FIXER_HEAD,
        REMOTE_HEAD,
        "\"latest_ci\"",
        "\"current_gates\"",
        "repair_instructions",
    ] {
        assert!(prompt.contains(expected), "missing {expected}");
    }
}

#[test]
fn request_rejects_failed_ci_stale_identity_and_inconsistent_gates() {
    let fixer_request = fixer_request();
    let fixer_result = fixer_result();
    let mut ci = passed_ci();
    ci.status = TaskBoardDependencyCheckResumeStatus::ChecksFailed {
        checks: settled_checks(),
    };
    assert!(
        task_board_dependency_reverification_request(
            "deepseek-turn-1",
            &fixer_request,
            &fixer_result,
            &ci,
            &gates(),
            "diff --git a/Cargo.lock b/Cargo.lock",
        )
        .is_err()
    );

    ci = passed_ci();
    ci.identity = PullRequestIdentity::from_slug("acme/other", 17);
    assert!(
        task_board_dependency_reverification_request(
            "deepseek-turn-1",
            &fixer_request,
            &fixer_result,
            &ci,
            &gates(),
            "diff --git a/Cargo.lock b/Cargo.lock",
        )
        .is_err()
    );

    let mut inconsistent = gates();
    inconsistent.checks[0].state = CheckState::Failure;
    assert!(
        task_board_dependency_reverification_request(
            "deepseek-turn-1",
            &fixer_request,
            &fixer_result,
            &passed_ci(),
            &inconsistent,
            "diff --git a/Cargo.lock b/Cargo.lock",
        )
        .is_err()
    );

    let mut duplicate_ci = request().expect("valid request");
    let TaskBoardDependencyCheckResumeStatus::ChecksPassed { checks } =
        &mut duplicate_ci.latest_ci.status
    else {
        panic!("expected passed checks");
    };
    checks.push(checks[0].clone());
    assert!(validate_task_board_dependency_reverification_request(&duplicate_ci).is_err());

    let mut duplicate_required = request().expect("valid request");
    duplicate_required
        .current_gates
        .required_check_names
        .push("build".into());
    assert!(validate_task_board_dependency_reverification_request(&duplicate_required).is_err());

    let mut invalid_diff = request().expect("valid request");
    invalid_diff.diff = "Cargo.lock changed".into();
    assert!(validate_task_board_dependency_reverification_request(&invalid_diff).is_err());

    let mut partial_diff = request().expect("valid request");
    partial_diff
        .fixer_result
        .changed_paths
        .push("Cargo.toml".into());
    assert!(validate_task_board_dependency_reverification_request(&partial_diff).is_err());
}

#[test]
fn green_light_is_exact_head_and_head_change_requires_reverification() {
    let request = request().expect("request");
    let result = result(
        &request,
        TaskBoardDependencyReverificationDecision::GreenLight,
        Vec::new(),
    );
    let report = serde_json::to_string(&result).expect("report");
    let parsed =
        parse_task_board_dependency_reverification_result(&report, &request).expect("parsed");

    assert_eq!(
        task_board_dependency_reverification_authorization(&parsed, REMOTE_HEAD)
            .expect("authorization"),
        TaskBoardDependencyReverificationAuthorization::GreenLight {
            exact_head_revision: REMOTE_HEAD.into()
        }
    );
    assert_eq!(
        task_board_dependency_reverification_authorization(&parsed, LATER_HEAD)
            .expect("stale result"),
        TaskBoardDependencyReverificationAuthorization::ReverificationRequired {
            verified_revision: REMOTE_HEAD.into(),
            current_revision: LATER_HEAD.into(),
        }
    );
}

#[test]
fn rejection_returns_concrete_fixer_instructions() {
    let request = request().expect("request");
    let result = result(
        &request,
        TaskBoardDependencyReverificationDecision::RepairRequired,
        vec![
            "Update the lockfile checksum".into(),
            "Run the focused package test".into(),
        ],
    );
    let report = serde_json::to_string(&result).expect("report");
    let parsed =
        parse_task_board_dependency_reverification_result(&report, &request).expect("parsed");

    assert_eq!(
        task_board_dependency_reverification_authorization(&parsed, REMOTE_HEAD)
            .expect("authorization"),
        TaskBoardDependencyReverificationAuthorization::RepairRequired {
            exact_head_revision: REMOTE_HEAD.into(),
            instructions: result.repair_instructions,
        }
    );
}

#[test]
fn stale_or_contradictory_results_fail_closed() {
    let request = request().expect("request");
    let mut result = result(
        &request,
        TaskBoardDependencyReverificationDecision::GreenLight,
        Vec::new(),
    );
    result.exact_head_revision = LATER_HEAD.into();
    let report = serde_json::to_string(&result).expect("report");
    assert!(parse_task_board_dependency_reverification_result(&report, &request).is_err());

    result.exact_head_revision = REMOTE_HEAD.into();
    result.repair_instructions = vec!["unexpected repair".into()];
    let report = serde_json::to_string(&result).expect("report");
    assert!(parse_task_board_dependency_reverification_result(&report, &request).is_err());

    result.repair_instructions.clear();
    result.repository = " acme/widgets".into();
    assert!(task_board_dependency_reverification_authorization(&result, REMOTE_HEAD).is_err());

    result.repository = request.repository;
    result.verification_id.push(' ');
    assert!(task_board_dependency_reverification_authorization(&result, REMOTE_HEAD).is_err());
}

fn request() -> Result<TaskBoardDependencyReverificationRequest, CliError> {
    task_board_dependency_reverification_request(
        "deepseek-turn-1",
        &fixer_request(),
        &fixer_result(),
        &passed_ci(),
        &gates(),
        "diff --git a/Cargo.lock b/Cargo.lock\n+fixed",
    )
}

fn result(
    request: &TaskBoardDependencyReverificationRequest,
    decision: TaskBoardDependencyReverificationDecision,
    repair_instructions: Vec<String>,
) -> TaskBoardDependencyReverificationResult {
    TaskBoardDependencyReverificationResult {
        schema_version: TASK_BOARD_DEPENDENCY_REVERIFICATION_SCHEMA_VERSION,
        verification_id: request.verification_id.clone(),
        repository: request.repository.clone(),
        pull_request_number: request.pull_request_number,
        exact_head_revision: request.exact_head_revision.clone(),
        decision,
        reasoning: "reviewed the exact changed head".into(),
        repair_instructions,
    }
}

fn fixer_request() -> TaskBoardDependencyFixRequest {
    TaskBoardDependencyFixRequest {
        dispatch_id: "route-1:fix".into(),
        route_id: "route-1".into(),
        session_id: "session-1".into(),
        board_item_id: "item-1".into(),
        workflow_execution_id: "execution-1".into(),
        attempt: 1,
        repository: "acme/widgets".into(),
        pull_request_number: 17,
        exact_head_revision: ORIGINAL_HEAD.into(),
        requested_repair: "repair the failing build".into(),
        triage_result: triage(),
        retry_evidence: None,
    }
}

fn fixer_result() -> TaskBoardDependencyFixResult {
    TaskBoardDependencyFixResult {
        schema_version: super::super::TASK_BOARD_DEPENDENCY_FIX_RESULT_SCHEMA_VERSION,
        dispatch_id: "route-1:fix".into(),
        route_id: "route-1".into(),
        base_head_revision: ORIGINAL_HEAD.into(),
        head_revision: FIXER_HEAD.into(),
        summary: "updated the lockfile".into(),
        changed_paths: vec!["Cargo.lock".into()],
        validation: vec!["mise run test:unit passed".into()],
        remaining_blockers: Vec::new(),
    }
}

fn passed_ci() -> TaskBoardDependencyCheckResumeRecord {
    TaskBoardDependencyCheckResumeRecord {
        resume_id: "route-1:checks".into(),
        route_id: "route-1".into(),
        identity: PullRequestIdentity::from_slug("acme/widgets", 17),
        exact_head_revision: REMOTE_HEAD.into(),
        status: TaskBoardDependencyCheckResumeStatus::ChecksPassed {
            checks: settled_checks(),
        },
    }
}

fn settled_checks() -> Vec<super::super::TaskBoardDependencySettledCheck> {
    vec![super::super::TaskBoardDependencySettledCheck {
        name: "build".into(),
        conclusion: TaskBoardDependencyCheckConclusion::Success,
        details_url: Some("https://ci.example.test/build/17".into()),
    }]
}

fn gates() -> PullRequestMergeGates {
    PullRequestMergeGates {
        mergeability: Mergeability::Mergeable,
        viewer_can_update: true,
        viewer_can_merge_as_admin: false,
        checks: vec![CheckGate {
            name: "build".into(),
            state: CheckState::Success,
            details_url: Some("https://ci.example.test/build/17".into()),
        }],
        required_check_names: vec!["build".into()],
        review: ReviewGate {
            decision: ReviewDecision::ReviewRequired,
            current_approvals: 0,
            required_approvals: 1,
        },
    }
}

fn triage() -> TaskBoardDependencyTriageResult {
    TaskBoardDependencyTriageResult {
        schema_version: super::super::TASK_BOARD_DEPENDENCY_TRIAGE_SCHEMA_VERSION,
        repository: "acme/widgets".into(),
        pull_request_number: 17,
        exact_head_revision: ORIGINAL_HEAD.into(),
        dependency: TaskBoardDependencyIdentity {
            name: "serde".into(),
            ecosystem: "cargo".into(),
            current_version: "1.0.200".into(),
            target_version: "1.0.201".into(),
            update_class: TaskBoardDependencyUpdateClass::Patch,
        },
        checks: vec![TaskBoardDependencyCheck {
            name: "build".into(),
            state: TaskBoardDependencyCheckState::Failed,
            details_url: Some("https://ci.example.test/build/16".into()),
        }],
        conflicts: TaskBoardDependencyConflictEvidence {
            state: TaskBoardDependencyConflictState::Clean,
            summary: "clean".into(),
        },
        approvals: TaskBoardDependencyApprovalEvidence {
            current: 0,
            required: 1,
        },
        safety_assumption: "repair must preserve the update".into(),
        disposition: TaskBoardDependencyTriageDisposition::FixRequired,
        required_tools: vec!["task_board.audit".into(), "codex.dispatch".into()],
        next_steps: vec![
            TaskBoardDependencyTriageStep {
                order: 1,
                action: "record_result".into(),
                reason: "retain the review".into(),
            },
            TaskBoardDependencyTriageStep {
                order: 2,
                action: "dispatch_fixer".into(),
                reason: "repair the build".into(),
            },
        ],
    }
}
