use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::task_board::{
    AgentMode, TaskBoardOrchestratorWorkflow, TaskBoardPhaseVerdict, TaskBoardResolvedReviewer,
    TaskBoardReviewResult, TaskBoardReviewerProfile, TaskBoardReviewerRule,
    TaskBoardReviewerSettings, TaskBoardWorkflowKind, normalize_repository_slug,
};

pub const MAX_TASK_BOARD_REVIEW_REVISION_CYCLES: u32 = 3;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardReviewerOutcome {
    pub profile_id: String,
    pub result: TaskBoardReviewResult,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardReviewRoundDecision {
    AwaitingReviewers,
    Approved,
    ChangesRequired,
    HumanRequired,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardReviewRoundEvaluation {
    pub decision: TaskBoardReviewRoundDecision,
    pub head_revision: String,
    pub revision_cycle: u32,
    pub approvals: u32,
    pub required_approvals: u32,
    pub completed_reviews: u32,
    pub reviewer_count: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum TaskBoardReviewerResolutionError {
    #[error("workflow kind is unknown")]
    UnknownWorkflow,
    #[error("repository '{repository}' is invalid, expected owner/repo")]
    InvalidRepository { repository: String },
    #[error("reviewer override for workflow '{workflow:?}' is ambiguous")]
    AmbiguousOverride {
        workflow: TaskBoardOrchestratorWorkflow,
    },
    #[error("reviewer count must be at least one")]
    ZeroReviewers,
    #[error("required approvals must be between one and reviewer count")]
    InvalidQuorum,
    #[error("revision cycle limit must be between one and three")]
    InvalidRevisionCycles,
    #[error("reviewer profile count is lower than reviewer count")]
    InsufficientProfiles,
    #[error("reviewer profile field '{field}' is empty")]
    EmptyProfileField { field: &'static str },
    #[error("reviewer profile id '{profile_id}' is duplicated")]
    DuplicateProfileId { profile_id: String },
    #[error("reviewer profile '{profile_id}' is not configured for read-only evaluation")]
    ReviewerNotReadOnly { profile_id: String },
    #[error("review head revision is empty")]
    EmptyHeadRevision,
    #[error("review revision cycle is outside the configured range")]
    InvalidRevisionCycle,
    #[error("review outcome profile '{profile_id}' is not part of the resolved reviewer set")]
    UnknownReviewer { profile_id: String },
    #[error("review outcome profile '{profile_id}' was submitted more than once")]
    DuplicateOutcome { profile_id: String },
    #[error("review outcome targets stale head '{actual}', expected '{expected}'")]
    HeadRevisionMismatch { expected: String, actual: String },
}

/// Resolve reviewer configuration with explicit precedence:
/// repository+workflow, workflow-only, then global defaults.
///
/// # Errors
///
/// Returns an error when the workflow, repository, matching override, or resolved reviewer
/// configuration is invalid.
pub fn resolve_task_board_reviewers(
    settings: &TaskBoardReviewerSettings,
    workflow_kind: TaskBoardWorkflowKind,
    repository: Option<&str>,
) -> Result<TaskBoardResolvedReviewer, TaskBoardReviewerResolutionError> {
    let workflow = orchestrator_workflow(workflow_kind)?;
    let repository = normalize_optional_repository(repository)?;
    let matching = matching_override(settings, workflow, repository.as_deref())?;
    let (reviewer_count, required_approvals, profiles) = matching.map_or_else(
        || {
            (
                settings.reviewer_count,
                settings.required_approvals,
                settings.profiles.clone(),
            )
        },
        |rule| (rule.reviewer_count, rule.required_approvals, rule.profiles),
    );
    build_resolved_reviewers(
        reviewer_count,
        required_approvals,
        settings.max_revision_cycles,
        profiles,
    )
}

/// Evaluate reviewer outcomes for one exact-head revision cycle.
///
/// # Errors
///
/// Returns an error when the resolved reviewers, revision cycle, head revision, or an outcome is
/// invalid.
pub fn evaluate_task_board_review_round(
    resolved: &TaskBoardResolvedReviewer,
    expected_head_revision: &str,
    revision_cycle: u32,
    outcomes: &[TaskBoardReviewerOutcome],
) -> Result<TaskBoardReviewRoundEvaluation, TaskBoardReviewerResolutionError> {
    validate_resolved_reviewers(resolved)?;
    let expected_head_revision = expected_head_revision.trim();
    if expected_head_revision.is_empty() {
        return Err(TaskBoardReviewerResolutionError::EmptyHeadRevision);
    }
    if revision_cycle == 0 || revision_cycle > resolved.max_revision_cycles {
        return Err(TaskBoardReviewerResolutionError::InvalidRevisionCycle);
    }
    let configured = resolved
        .profiles
        .iter()
        .map(|profile| profile.id.as_str())
        .collect::<BTreeSet<_>>();
    let mut submitted = BTreeSet::new();
    let mut approvals = 0_u32;
    let mut changes_required = 0_u32;
    let mut human_required = false;
    for outcome in outcomes {
        validate_outcome(outcome, expected_head_revision, &configured, &mut submitted)?;
        match outcome.result.verdict {
            TaskBoardPhaseVerdict::Pass => approvals += 1,
            TaskBoardPhaseVerdict::ChangesRequired => changes_required += 1,
            TaskBoardPhaseVerdict::HumanRequired => human_required = true,
        }
    }
    let completed_reviews = u32::try_from(outcomes.len()).unwrap_or(u32::MAX);
    let remaining = resolved.reviewer_count.saturating_sub(completed_reviews);
    let decision = review_round_decision(
        resolved,
        revision_cycle,
        approvals,
        changes_required,
        remaining,
        human_required,
    );
    Ok(TaskBoardReviewRoundEvaluation {
        decision,
        head_revision: expected_head_revision.to_owned(),
        revision_cycle,
        approvals,
        required_approvals: resolved.required_approvals,
        completed_reviews,
        reviewer_count: resolved.reviewer_count,
    })
}

/// Validate a fully resolved reviewer configuration.
///
/// # Errors
///
/// Returns an error when reviewer counts, quorum, revision limits, or profiles are invalid.
pub fn validate_task_board_resolved_reviewers(
    resolved: &TaskBoardResolvedReviewer,
) -> Result<(), TaskBoardReviewerResolutionError> {
    validate_resolved_reviewers(resolved)
}

fn matching_override(
    settings: &TaskBoardReviewerSettings,
    workflow: TaskBoardOrchestratorWorkflow,
    repository: Option<&str>,
) -> Result<Option<TaskBoardReviewerRule>, TaskBoardReviewerResolutionError> {
    let mut exact = Vec::new();
    let mut workflow_only = Vec::new();
    for rule in &settings.overrides {
        let rule_repository = normalize_optional_repository(rule.repository.as_deref())?;
        if rule.workflow != workflow {
            continue;
        }
        if rule_repository.is_none() {
            workflow_only.push(rule.clone());
        } else if rule_repository.as_deref() == repository {
            exact.push(rule.clone());
        }
    }
    select_single_override(exact, workflow)?.map_or_else(
        || select_single_override(workflow_only, workflow),
        |rule| Ok(Some(rule)),
    )
}

fn select_single_override(
    mut rules: Vec<TaskBoardReviewerRule>,
    workflow: TaskBoardOrchestratorWorkflow,
) -> Result<Option<TaskBoardReviewerRule>, TaskBoardReviewerResolutionError> {
    match rules.len() {
        0 => Ok(None),
        1 => Ok(rules.pop()),
        _ => Err(TaskBoardReviewerResolutionError::AmbiguousOverride { workflow }),
    }
}

fn build_resolved_reviewers(
    reviewer_count: u32,
    required_approvals: u32,
    max_revision_cycles: u32,
    profiles: Vec<TaskBoardReviewerProfile>,
) -> Result<TaskBoardResolvedReviewer, TaskBoardReviewerResolutionError> {
    let count = usize::try_from(reviewer_count).unwrap_or(usize::MAX);
    let mut resolved = TaskBoardResolvedReviewer {
        reviewer_count,
        required_approvals,
        max_revision_cycles,
        profiles: profiles.into_iter().take(count).collect(),
    };
    normalize_profiles(&mut resolved.profiles);
    validate_resolved_reviewers(&resolved)?;
    Ok(resolved)
}

fn validate_resolved_reviewers(
    resolved: &TaskBoardResolvedReviewer,
) -> Result<(), TaskBoardReviewerResolutionError> {
    if resolved.reviewer_count == 0 {
        return Err(TaskBoardReviewerResolutionError::ZeroReviewers);
    }
    if resolved.required_approvals == 0 || resolved.required_approvals > resolved.reviewer_count {
        return Err(TaskBoardReviewerResolutionError::InvalidQuorum);
    }
    if resolved.max_revision_cycles == 0
        || resolved.max_revision_cycles > MAX_TASK_BOARD_REVIEW_REVISION_CYCLES
    {
        return Err(TaskBoardReviewerResolutionError::InvalidRevisionCycles);
    }
    if resolved.profiles.len() < usize::try_from(resolved.reviewer_count).unwrap_or(usize::MAX) {
        return Err(TaskBoardReviewerResolutionError::InsufficientProfiles);
    }
    validate_profiles(&resolved.profiles)
}

fn validate_profiles(
    profiles: &[TaskBoardReviewerProfile],
) -> Result<(), TaskBoardReviewerResolutionError> {
    let mut ids = BTreeSet::new();
    for profile in profiles {
        require_profile_field(&profile.id, "id")?;
        require_profile_field(&profile.runtime, "runtime")?;
        require_profile_field(&profile.persona, "persona")?;
        if !ids.insert(profile.id.clone()) {
            return Err(TaskBoardReviewerResolutionError::DuplicateProfileId {
                profile_id: profile.id.clone(),
            });
        }
        if profile.agent_mode != AgentMode::Evaluate {
            return Err(TaskBoardReviewerResolutionError::ReviewerNotReadOnly {
                profile_id: profile.id.clone(),
            });
        }
    }
    Ok(())
}

fn validate_outcome<'a>(
    outcome: &'a TaskBoardReviewerOutcome,
    expected_head_revision: &str,
    configured: &BTreeSet<&str>,
    submitted: &mut BTreeSet<&'a str>,
) -> Result<(), TaskBoardReviewerResolutionError> {
    if !configured.contains(outcome.profile_id.as_str()) {
        return Err(TaskBoardReviewerResolutionError::UnknownReviewer {
            profile_id: outcome.profile_id.clone(),
        });
    }
    if !submitted.insert(outcome.profile_id.as_str()) {
        return Err(TaskBoardReviewerResolutionError::DuplicateOutcome {
            profile_id: outcome.profile_id.clone(),
        });
    }
    if outcome.result.head_revision.trim() != expected_head_revision {
        return Err(TaskBoardReviewerResolutionError::HeadRevisionMismatch {
            expected: expected_head_revision.to_owned(),
            actual: outcome.result.head_revision.clone(),
        });
    }
    Ok(())
}

fn review_round_decision(
    resolved: &TaskBoardResolvedReviewer,
    revision_cycle: u32,
    approvals: u32,
    changes_required: u32,
    remaining: u32,
    human_required: bool,
) -> TaskBoardReviewRoundDecision {
    if human_required {
        return TaskBoardReviewRoundDecision::HumanRequired;
    }
    if changes_required > 0 {
        return if revision_cycle < resolved.max_revision_cycles {
            TaskBoardReviewRoundDecision::ChangesRequired
        } else {
            TaskBoardReviewRoundDecision::HumanRequired
        };
    }
    if remaining > 0 && approvals.saturating_add(remaining) >= resolved.required_approvals {
        return TaskBoardReviewRoundDecision::AwaitingReviewers;
    }
    if approvals >= resolved.required_approvals {
        return TaskBoardReviewRoundDecision::Approved;
    }
    TaskBoardReviewRoundDecision::HumanRequired
}

fn normalize_profiles(profiles: &mut [TaskBoardReviewerProfile]) {
    for profile in profiles {
        profile.id = profile.id.trim().to_owned();
        profile.runtime = profile.runtime.trim().to_ascii_lowercase();
        profile.persona = profile.persona.trim().to_owned();
        profile.model = profile.model.as_deref().and_then(non_empty);
        profile.effort = profile.effort.as_deref().and_then(non_empty);
    }
}

fn normalize_optional_repository(
    repository: Option<&str>,
) -> Result<Option<String>, TaskBoardReviewerResolutionError> {
    let Some(repository) = repository else {
        return Ok(None);
    };
    normalize_repository_slug(Some(repository))
        .map(Some)
        .ok_or_else(|| TaskBoardReviewerResolutionError::InvalidRepository {
            repository: repository.to_owned(),
        })
}

const fn orchestrator_workflow(
    workflow_kind: TaskBoardWorkflowKind,
) -> Result<TaskBoardOrchestratorWorkflow, TaskBoardReviewerResolutionError> {
    match workflow_kind {
        TaskBoardWorkflowKind::DefaultTask => Ok(TaskBoardOrchestratorWorkflow::DefaultTask),
        TaskBoardWorkflowKind::PrFix => Ok(TaskBoardOrchestratorWorkflow::PrFix),
        TaskBoardWorkflowKind::PrReview => Ok(TaskBoardOrchestratorWorkflow::PrReview),
        TaskBoardWorkflowKind::Review => Ok(TaskBoardOrchestratorWorkflow::Review),
        TaskBoardWorkflowKind::Unknown => Err(TaskBoardReviewerResolutionError::UnknownWorkflow),
    }
}

fn require_profile_field(
    value: &str,
    field: &'static str,
) -> Result<(), TaskBoardReviewerResolutionError> {
    if value.is_empty() {
        Err(TaskBoardReviewerResolutionError::EmptyProfileField { field })
    } else {
        Ok(())
    }
}

fn non_empty(value: &str) -> Option<String> {
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_owned())
}
