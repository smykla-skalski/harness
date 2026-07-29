use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use super::compile_task_board_dependency_action_plan;
use crate::normalize_repository_slug;

pub const TASK_BOARD_DEPENDENCY_TRIAGE_SCHEMA_VERSION: u32 = 1;
pub const TASK_BOARD_DEPENDENCY_TRIAGE_MODEL: &str = "deepseek/deepseek-v4-flash";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardDependencyUpdateClass {
    Patch,
    Minor,
    Major,
    Digest,
    Pin,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardDependencyCheckState {
    Pending,
    Passed,
    Failed,
    Cancelled,
    Skipped,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardDependencyConflictState {
    Clean,
    Conflicted,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardDependencyTriageDisposition {
    ReportOnly,
    HumanRequired,
    WaitForChecks,
    FixRequired,
    ContinueSafe,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardDependencyIdentity {
    pub name: String,
    pub ecosystem: String,
    pub current_version: String,
    pub target_version: String,
    pub update_class: TaskBoardDependencyUpdateClass,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardDependencyCheck {
    pub name: String,
    pub state: TaskBoardDependencyCheckState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardDependencyConflictEvidence {
    pub state: TaskBoardDependencyConflictState,
    pub summary: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardDependencyApprovalEvidence {
    pub current: u32,
    pub required: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardDependencyTriageStep {
    pub order: u32,
    pub action: String,
    pub reason: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardDependencyTriageResult {
    pub schema_version: u32,
    pub repository: String,
    pub pull_request_number: u64,
    pub exact_head_revision: String,
    pub dependency: TaskBoardDependencyIdentity,
    pub checks: Vec<TaskBoardDependencyCheck>,
    pub conflicts: TaskBoardDependencyConflictEvidence,
    pub approvals: TaskBoardDependencyApprovalEvidence,
    pub safety_assumption: String,
    pub disposition: TaskBoardDependencyTriageDisposition,
    pub required_tools: Vec<String>,
    pub next_steps: Vec<TaskBoardDependencyTriageStep>,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum TaskBoardDependencyTriageError {
    #[error("dependency triage result is not valid JSON for the required schema: {0}")]
    InvalidJson(String),
    #[error("dependency triage result uses an unsupported schema version")]
    UnsupportedSchemaVersion,
    #[error("dependency triage result does not match the selected pull request")]
    PullRequestMismatch,
    #[error("dependency triage result has an invalid exact head revision")]
    InvalidHeadRevision,
    #[error("dependency triage result is missing required dependency evidence")]
    IncompleteDependency,
    #[error("dependency triage result contains a duplicate or empty check")]
    InvalidChecks,
    #[error("dependency triage result has invalid conflict evidence")]
    InvalidConflicts,
    #[error("dependency triage result has no safety assumption")]
    MissingSafetyAssumption,
    #[error("dependency triage result contains an invalid required tool")]
    InvalidRequiredTool,
    #[error("dependency triage result selects unsupported action '{0}'")]
    UnsupportedAction(String),
    #[error("dependency triage result selects unsupported required tool '{0}'")]
    UnsupportedRequiredTool(String),
    #[error("dependency triage action plan contradicts its disposition")]
    ActionPlanContradictsDisposition,
    #[error("dependency triage actions and required tools do not match")]
    ActionCapabilityMismatch,
    #[error("dependency triage disposition cannot reach mutation capabilities")]
    MutationForbidden,
    #[error("dependency triage result has invalid ordered next steps")]
    InvalidNextSteps,
    #[error("dependency triage disposition contradicts its evidence")]
    DispositionContradictsEvidence,
}

/// Decode and validate one model-produced dependency triage result against its frozen PR identity.
///
/// # Errors
///
/// Returns a user-displayable, fail-closed reason for malformed JSON, incomplete evidence, identity
/// drift, or a disposition contradicted by the supplied checks, conflicts, or approvals.
pub fn parse_task_board_dependency_triage_result(
    report: &str,
    expected_repository: &str,
    expected_pull_request_number: u64,
    expected_head_revision: &str,
) -> Result<TaskBoardDependencyTriageResult, TaskBoardDependencyTriageError> {
    let result = serde_json::from_str::<TaskBoardDependencyTriageResult>(report)
        .map_err(|error| TaskBoardDependencyTriageError::InvalidJson(error.to_string()))?;
    validate_task_board_dependency_triage_result(
        &result,
        expected_repository,
        expected_pull_request_number,
        expected_head_revision,
    )?;
    Ok(result)
}

/// Validate one structured triage result against the exact pull request snapshot it describes.
///
/// # Errors
///
/// Returns the first stable validation failure after compiling model-provided actions into the
/// documented typed plan. Validation never executes an action.
pub fn validate_task_board_dependency_triage_result(
    result: &TaskBoardDependencyTriageResult,
    expected_repository: &str,
    expected_pull_request_number: u64,
    expected_head_revision: &str,
) -> Result<(), TaskBoardDependencyTriageError> {
    validate_task_board_dependency_triage_evidence(
        result,
        expected_repository,
        expected_pull_request_number,
        expected_head_revision,
    )?;
    compile_task_board_dependency_action_plan(result).map(|_| ())
}

pub(super) fn validate_task_board_dependency_triage_evidence(
    result: &TaskBoardDependencyTriageResult,
    expected_repository: &str,
    expected_pull_request_number: u64,
    expected_head_revision: &str,
) -> Result<(), TaskBoardDependencyTriageError> {
    if result.schema_version != TASK_BOARD_DEPENDENCY_TRIAGE_SCHEMA_VERSION {
        return Err(TaskBoardDependencyTriageError::UnsupportedSchemaVersion);
    }
    validate_pull_request_identity(
        result,
        expected_repository,
        expected_pull_request_number,
        expected_head_revision,
    )?;
    validate_dependency(&result.dependency)?;
    validate_checks(&result.checks)?;
    if result.conflicts.summary.trim().is_empty() {
        return Err(TaskBoardDependencyTriageError::InvalidConflicts);
    }
    if result.safety_assumption.trim().is_empty() {
        return Err(TaskBoardDependencyTriageError::MissingSafetyAssumption);
    }
    validate_required_tools(&result.required_tools)?;
    validate_next_steps(&result.next_steps)?;
    validate_disposition(result)
}

fn validate_pull_request_identity(
    result: &TaskBoardDependencyTriageResult,
    repository: &str,
    number: u64,
    head: &str,
) -> Result<(), TaskBoardDependencyTriageError> {
    let expected_repository = normalize_repository_slug(Some(repository));
    let actual_repository = normalize_repository_slug(Some(&result.repository));
    if !valid_head_revision(head) || !valid_head_revision(&result.exact_head_revision) {
        return Err(TaskBoardDependencyTriageError::InvalidHeadRevision);
    }
    if expected_repository.is_none()
        || actual_repository != expected_repository
        || actual_repository.as_deref() != Some(result.repository.as_str())
        || number == 0
        || result.pull_request_number != number
        || result.exact_head_revision != head
    {
        return Err(TaskBoardDependencyTriageError::PullRequestMismatch);
    }
    Ok(())
}

fn validate_dependency(
    dependency: &TaskBoardDependencyIdentity,
) -> Result<(), TaskBoardDependencyTriageError> {
    if [
        dependency.name.as_str(),
        dependency.ecosystem.as_str(),
        dependency.current_version.as_str(),
        dependency.target_version.as_str(),
    ]
    .iter()
    .any(|value| value.trim().is_empty())
        || dependency.current_version.trim() == dependency.target_version.trim()
    {
        return Err(TaskBoardDependencyTriageError::IncompleteDependency);
    }
    Ok(())
}

fn validate_checks(
    checks: &[TaskBoardDependencyCheck],
) -> Result<(), TaskBoardDependencyTriageError> {
    let mut names = BTreeSet::new();
    for check in checks {
        let name = check.name.trim();
        if name.is_empty()
            || !names.insert(name)
            || check
                .details_url
                .as_deref()
                .is_some_and(|url| url.trim().is_empty())
        {
            return Err(TaskBoardDependencyTriageError::InvalidChecks);
        }
    }
    Ok(())
}

fn validate_required_tools(tools: &[String]) -> Result<(), TaskBoardDependencyTriageError> {
    let mut unique = BTreeSet::new();
    for tool in tools {
        let tool = tool.trim();
        if tool.is_empty()
            || !tool.bytes().all(|byte| {
                byte.is_ascii_lowercase()
                    || byte.is_ascii_digit()
                    || matches!(byte, b'-' | b'_' | b'.')
            })
            || !unique.insert(tool)
        {
            return Err(TaskBoardDependencyTriageError::InvalidRequiredTool);
        }
    }
    Ok(())
}

fn validate_next_steps(
    steps: &[TaskBoardDependencyTriageStep],
) -> Result<(), TaskBoardDependencyTriageError> {
    if steps.is_empty() {
        return Err(TaskBoardDependencyTriageError::InvalidNextSteps);
    }
    for (index, step) in steps.iter().enumerate() {
        let expected = expected_step_order(index)?;
        if step.order != expected || step.action.trim().is_empty() || step.reason.trim().is_empty()
        {
            return Err(TaskBoardDependencyTriageError::InvalidNextSteps);
        }
    }
    Ok(())
}

fn expected_step_order(index: usize) -> Result<u32, TaskBoardDependencyTriageError> {
    index
        .checked_add(1)
        .and_then(|order| u32::try_from(order).ok())
        .ok_or(TaskBoardDependencyTriageError::InvalidNextSteps)
}

fn validate_disposition(
    result: &TaskBoardDependencyTriageResult,
) -> Result<(), TaskBoardDependencyTriageError> {
    let pending = result
        .checks
        .iter()
        .any(|check| check.state == TaskBoardDependencyCheckState::Pending);
    let failing = result.checks.iter().any(|check| {
        matches!(
            check.state,
            TaskBoardDependencyCheckState::Failed | TaskBoardDependencyCheckState::Cancelled
        )
    });
    let approvals_met = result.approvals.current >= result.approvals.required;
    let clean = result.conflicts.state == TaskBoardDependencyConflictState::Clean;
    let valid = match result.disposition {
        TaskBoardDependencyTriageDisposition::WaitForChecks => pending && !failing && clean,
        TaskBoardDependencyTriageDisposition::ContinueSafe => {
            !result.checks.is_empty() && !pending && !failing && approvals_met && clean
        }
        TaskBoardDependencyTriageDisposition::ReportOnly
        | TaskBoardDependencyTriageDisposition::HumanRequired
        | TaskBoardDependencyTriageDisposition::FixRequired => true,
    };
    if valid {
        Ok(())
    } else {
        Err(TaskBoardDependencyTriageError::DispositionContradictsEvidence)
    }
}
fn valid_head_revision(revision: &str) -> bool {
    matches!(revision.len(), 40 | 64)
        && revision
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
#[cfg(test)]
mod tests {
    use super::*;
    const HEAD: &str = "0123456789abcdef0123456789abcdef01234567";
    #[test]
    fn strict_result_round_trip_accepts_safe_exact_head() {
        let result = result(TaskBoardDependencyTriageDisposition::ContinueSafe);
        let report = serde_json::to_string(&result).expect("serialize result");
        let parsed = parse_task_board_dependency_triage_result(&report, "acme/widgets", 17, HEAD)
            .expect("valid structured result");
        assert_eq!(parsed, result);
    }
    #[test]
    fn invalid_or_stale_results_fail_closed_with_visible_reasons() {
        let invalid_json =
            parse_task_board_dependency_triage_result("not-json", "acme/widgets", 17, HEAD)
                .expect_err("invalid JSON");
        assert!(
            invalid_json
                .to_string()
                .contains("not valid JSON for the required schema")
        );
        let mut malformed = result(TaskBoardDependencyTriageDisposition::ContinueSafe);
        malformed.exact_head_revision = "not-a-revision".into();
        assert_eq!(
            validate(&malformed),
            Err(TaskBoardDependencyTriageError::InvalidHeadRevision)
        );
        let mut noncanonical = result(TaskBoardDependencyTriageDisposition::ContinueSafe);
        noncanonical.repository = " Acme/Widgets ".into();
        assert_eq!(
            validate(&noncanonical),
            Err(TaskBoardDependencyTriageError::PullRequestMismatch)
        );
        let mut stale = result(TaskBoardDependencyTriageDisposition::ContinueSafe);
        stale.exact_head_revision = "abcdefabcdefabcdefabcdefabcdefabcdefabcd".into();
        let stale = serde_json::to_string(&stale).expect("serialize stale result");
        assert_eq!(
            parse_task_board_dependency_triage_result(&stale, "acme/widgets", 17, HEAD),
            Err(TaskBoardDependencyTriageError::PullRequestMismatch)
        );
    }

    #[test]
    fn safe_continuation_rejects_pending_checks_conflicts_and_missing_approvals() {
        let mut pending = result(TaskBoardDependencyTriageDisposition::ContinueSafe);
        pending.checks[0].state = TaskBoardDependencyCheckState::Pending;
        assert_contradiction(&pending);
        let mut conflicted = result(TaskBoardDependencyTriageDisposition::ContinueSafe);
        conflicted.conflicts.state = TaskBoardDependencyConflictState::Conflicted;
        assert_contradiction(&conflicted);
        let mut under_approved = result(TaskBoardDependencyTriageDisposition::ContinueSafe);
        under_approved.approvals.current = 0;
        assert_contradiction(&under_approved);
        let mut no_checks = result(TaskBoardDependencyTriageDisposition::ContinueSafe);
        no_checks.checks.clear();
        assert_contradiction(&no_checks);
    }

    #[test]
    fn wait_requires_pending_check_and_steps_are_strictly_ordered() {
        let wait = result(TaskBoardDependencyTriageDisposition::WaitForChecks);
        assert_contradiction(&wait);
        let mut pending = result(TaskBoardDependencyTriageDisposition::WaitForChecks);
        pending.checks[0].state = TaskBoardDependencyCheckState::Pending;
        assert_eq!(validate(&pending), Ok(()));
        let mut conflicted = pending.clone();
        conflicted.conflicts.state = TaskBoardDependencyConflictState::Conflicted;
        assert_contradiction(&conflicted);
        let mut failed_while_pending = result(TaskBoardDependencyTriageDisposition::WaitForChecks);
        failed_while_pending.checks[0].state = TaskBoardDependencyCheckState::Pending;
        failed_while_pending.checks.push(TaskBoardDependencyCheck {
            name: "lint".into(),
            state: TaskBoardDependencyCheckState::Failed,
            details_url: None,
        });
        assert_contradiction(&failed_while_pending);
        let mut unordered = result(TaskBoardDependencyTriageDisposition::ContinueSafe);
        unordered.next_steps[0].order = 2;
        assert_eq!(
            validate(&unordered),
            Err(TaskBoardDependencyTriageError::InvalidNextSteps)
        );
        assert_eq!(
            expected_step_order(usize::MAX),
            Err(TaskBoardDependencyTriageError::InvalidNextSteps)
        );
    }
    fn assert_contradiction(result: &TaskBoardDependencyTriageResult) {
        assert_eq!(
            validate(result),
            Err(TaskBoardDependencyTriageError::DispositionContradictsEvidence)
        );
    }
    fn validate(
        result: &TaskBoardDependencyTriageResult,
    ) -> Result<(), TaskBoardDependencyTriageError> {
        validate_task_board_dependency_triage_result(result, "acme/widgets", 17, HEAD)
    }
    fn result(
        disposition: TaskBoardDependencyTriageDisposition,
    ) -> TaskBoardDependencyTriageResult {
        let (tool, action) = match disposition {
            TaskBoardDependencyTriageDisposition::ReportOnly => {
                ("task_board.audit", "complete_report")
            }
            TaskBoardDependencyTriageDisposition::HumanRequired => {
                ("task_board.audit", "require_human")
            }
            TaskBoardDependencyTriageDisposition::WaitForChecks => {
                ("github.read", "wait_for_checks")
            }
            TaskBoardDependencyTriageDisposition::FixRequired => {
                ("codex.dispatch", "dispatch_fixer")
            }
            TaskBoardDependencyTriageDisposition::ContinueSafe => {
                ("task_board.advance", "continue_workflow")
            }
        };
        let mut required_tools = vec!["task_board.audit".into()];
        if tool != "task_board.audit" {
            required_tools.push(tool.into());
        }
        TaskBoardDependencyTriageResult {
            schema_version: TASK_BOARD_DEPENDENCY_TRIAGE_SCHEMA_VERSION,
            repository: "acme/widgets".into(),
            pull_request_number: 17,
            exact_head_revision: HEAD.into(),
            dependency: TaskBoardDependencyIdentity {
                name: "serde".into(),
                ecosystem: "cargo".into(),
                current_version: "1.0.200".into(),
                target_version: "1.0.201".into(),
                update_class: TaskBoardDependencyUpdateClass::Patch,
            },
            checks: vec![TaskBoardDependencyCheck {
                name: "test".into(),
                state: TaskBoardDependencyCheckState::Passed,
                details_url: Some("https://example.test/checks/1".into()),
            }],
            conflicts: TaskBoardDependencyConflictEvidence {
                state: TaskBoardDependencyConflictState::Clean,
                summary: "GitHub reports a clean merge state".into(),
            },
            approvals: TaskBoardDependencyApprovalEvidence {
                current: 1,
                required: 1,
            },
            safety_assumption: "Patch update with a green exact-head gate set".into(),
            disposition,
            required_tools,
            next_steps: vec![
                TaskBoardDependencyTriageStep {
                    order: 1,
                    action: "record_result".into(),
                    reason: "retain the exact-head decision".into(),
                },
                TaskBoardDependencyTriageStep {
                    order: 2,
                    action: action.into(),
                    reason: "apply the validated disposition".into(),
                },
            ],
        }
    }
}
