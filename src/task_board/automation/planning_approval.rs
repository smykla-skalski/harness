use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::task_board::{
    TaskBoardPlanningResult, TaskBoardWorkflowKind, TaskBoardWorkflowSnapshot,
};

const PLAN_HASH_DOMAIN: &[u8] = b"harness-task-board-plan-v1";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardPlanApprovalBinding {
    pub execution_id: String,
    pub workflow_kind: TaskBoardWorkflowKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub execution_repository: Option<String>,
    pub plan_hash: String,
    pub item_revision: i64,
    /// Frozen orchestrator-settings revision from the workflow snapshot.
    pub configuration_revision: u64,
    pub policy_version: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_revision: Option<String>,
    pub approved_by: String,
    pub approved_at: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardPlanApprovalInvalidation {
    ExecutionChanged,
    WorkflowChanged,
    RepositoryChanged,
    PlanChanged,
    ItemRevisionChanged,
    ConfigurationRevisionChanged,
    PolicyVersionChanged,
    ProviderRevisionChanged,
    ApprovalBindingInvalid,
    PlanningResultInvalid,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardPlanApprovalValidation {
    pub valid: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub invalidations: Vec<TaskBoardPlanApprovalInvalidation>,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum TaskBoardPlanningResultError {
    #[error("plan markdown is empty")]
    EmptyPlan,
    #[error("plan hash does not match plan contents")]
    InvalidPlanHash,
    #[error("stored plan markdown is not canonical")]
    NonCanonicalPlanMarkdown,
    #[error("stored acceptance criteria are not canonical")]
    NonCanonicalAcceptanceCriteria,
    #[error("planning result item revision does not match the workflow snapshot")]
    ItemRevisionMismatch,
    #[error("planning result configuration revision does not match the workflow snapshot")]
    ConfigurationRevisionMismatch,
    #[error("planning result provider revision does not match the workflow snapshot")]
    ProviderRevisionMismatch,
    #[error("workflow kind '{workflow_kind:?}' does not support planning approval")]
    UnsupportedWorkflowKind {
        workflow_kind: TaskBoardWorkflowKind,
    },
    #[error("item revision '{value}' is invalid")]
    InvalidItemRevision { value: i64 },
    #[error("configuration revision '{value}' is invalid")]
    InvalidConfigurationRevision { value: u64 },
    #[error("policy version is empty or non-canonical")]
    InvalidPolicyVersion,
    #[error("provider revision is empty or non-canonical")]
    InvalidProviderRevision,
    #[error("execution repository is empty or non-canonical")]
    InvalidExecutionRepository,
    #[error("plan approval execution id is empty")]
    EmptyExecutionId,
    #[error("plan approver is empty")]
    EmptyApprover,
    #[error("plan approval timestamp '{value}' is invalid")]
    InvalidApprovalTime { value: String },
}

/// Build a planning artifact with canonical line endings and no surrounding
/// blank lines while preserving Markdown-significant whitespace.
///
/// # Errors
///
/// Returns an error for empty content, execution identity, or malformed evidence.
pub fn build_planning_result(
    plan_markdown: &str,
    acceptance_criteria: impl IntoIterator<Item = String>,
    snapshot: &TaskBoardWorkflowSnapshot,
    execution_id: &str,
) -> Result<TaskBoardPlanningResult, TaskBoardPlanningResultError> {
    let plan_markdown = normalize_markdown(plan_markdown);
    if plan_markdown.is_empty() {
        return Err(TaskBoardPlanningResultError::EmptyPlan);
    }
    validate_snapshot_evidence(snapshot)?;
    let execution_id =
        required_trimmed(execution_id, TaskBoardPlanningResultError::EmptyExecutionId)?;
    let acceptance_criteria = normalize_acceptance_criteria(acceptance_criteria);
    let plan_hash = compute_plan_hash(
        &execution_id,
        snapshot,
        &plan_markdown,
        &acceptance_criteria,
    );
    Ok(TaskBoardPlanningResult {
        plan_markdown,
        acceptance_criteria,
        plan_hash,
        item_revision: snapshot.item_revision,
        configuration_revision: snapshot.configuration_revision,
        provider_revision: snapshot.provider_revision.clone(),
    })
}

/// Verify that a planning artifact still describes the exact execution,
/// workflow, repository, item, settings, policy, and provider evidence.
///
/// # Errors
///
/// Returns an error when content or evidence differs from the workflow snapshot.
pub fn validate_planning_result(
    result: &TaskBoardPlanningResult,
    snapshot: &TaskBoardWorkflowSnapshot,
    execution_id: &str,
) -> Result<(), TaskBoardPlanningResultError> {
    validate_snapshot_evidence(snapshot)?;
    let execution_id =
        required_trimmed(execution_id, TaskBoardPlanningResultError::EmptyExecutionId)?;
    validate_result_evidence(result)?;
    if result.item_revision != snapshot.item_revision {
        return Err(TaskBoardPlanningResultError::ItemRevisionMismatch);
    }
    if result.configuration_revision != snapshot.configuration_revision {
        return Err(TaskBoardPlanningResultError::ConfigurationRevisionMismatch);
    }
    if result.provider_revision != snapshot.provider_revision {
        return Err(TaskBoardPlanningResultError::ProviderRevisionMismatch);
    }
    validate_plan_content(
        result,
        &PlanHashEvidence::from_snapshot(&execution_id, snapshot),
    )?;
    Ok(())
}

/// Bind approval to one execution, workflow, repository, canonical plan
/// digest, frozen revisions, approver, and UTC timestamp.
///
/// # Errors
///
/// Returns [`TaskBoardPlanningResultError`] when the plan does not match the
/// snapshot, a required field is empty, or the timestamp is malformed.
pub fn bind_plan_approval(
    result: &TaskBoardPlanningResult,
    snapshot: &TaskBoardWorkflowSnapshot,
    execution_id: &str,
    approved_by: &str,
    approved_at: &str,
) -> Result<TaskBoardPlanApprovalBinding, TaskBoardPlanningResultError> {
    let execution_id =
        required_trimmed(execution_id, TaskBoardPlanningResultError::EmptyExecutionId)?;
    validate_planning_result(result, snapshot, &execution_id)?;
    let approved_by = required_trimmed(approved_by, TaskBoardPlanningResultError::EmptyApprover)?;
    let approved_at = canonical_approval_time(approved_at)?;
    Ok(TaskBoardPlanApprovalBinding {
        execution_id,
        workflow_kind: snapshot.workflow_kind,
        execution_repository: snapshot.execution_repository.clone(),
        plan_hash: result.plan_hash.clone(),
        item_revision: snapshot.item_revision,
        configuration_revision: snapshot.configuration_revision,
        policy_version: snapshot.policy_version.clone(),
        provider_revision: snapshot.provider_revision.clone(),
        approved_by,
        approved_at,
    })
}

/// Return every invalidation in stable domain order.
#[must_use]
pub fn validate_plan_approval(
    binding: &TaskBoardPlanApprovalBinding,
    result: &TaskBoardPlanningResult,
    snapshot: &TaskBoardWorkflowSnapshot,
    execution_id: &str,
) -> TaskBoardPlanApprovalValidation {
    let mut invalidations = Vec::new();
    push_invalidation(
        &mut invalidations,
        binding.execution_id != execution_id.trim(),
        TaskBoardPlanApprovalInvalidation::ExecutionChanged,
    );
    push_invalidation(
        &mut invalidations,
        binding.workflow_kind != snapshot.workflow_kind,
        TaskBoardPlanApprovalInvalidation::WorkflowChanged,
    );
    push_invalidation(
        &mut invalidations,
        binding.execution_repository != snapshot.execution_repository,
        TaskBoardPlanApprovalInvalidation::RepositoryChanged,
    );
    push_invalidation(
        &mut invalidations,
        binding.plan_hash != result.plan_hash,
        TaskBoardPlanApprovalInvalidation::PlanChanged,
    );
    push_invalidation(
        &mut invalidations,
        binding.item_revision != snapshot.item_revision
            || result.item_revision != snapshot.item_revision,
        TaskBoardPlanApprovalInvalidation::ItemRevisionChanged,
    );
    push_invalidation(
        &mut invalidations,
        binding.configuration_revision != snapshot.configuration_revision
            || result.configuration_revision != snapshot.configuration_revision,
        TaskBoardPlanApprovalInvalidation::ConfigurationRevisionChanged,
    );
    push_invalidation(
        &mut invalidations,
        binding.policy_version != snapshot.policy_version,
        TaskBoardPlanApprovalInvalidation::PolicyVersionChanged,
    );
    push_invalidation(
        &mut invalidations,
        binding.provider_revision != snapshot.provider_revision
            || result.provider_revision != snapshot.provider_revision,
        TaskBoardPlanApprovalInvalidation::ProviderRevisionChanged,
    );
    push_invalidation(
        &mut invalidations,
        !approval_binding_is_valid(binding),
        TaskBoardPlanApprovalInvalidation::ApprovalBindingInvalid,
    );
    push_invalidation(
        &mut invalidations,
        validate_plan_content(result, &PlanHashEvidence::from_binding(binding)).is_err()
            || validate_snapshot_evidence(snapshot).is_err()
            || validate_result_evidence(result).is_err(),
        TaskBoardPlanApprovalInvalidation::PlanningResultInvalid,
    );
    TaskBoardPlanApprovalValidation {
        valid: invalidations.is_empty(),
        invalidations,
    }
}

#[must_use]
pub fn compute_plan_hash(
    execution_id: &str,
    snapshot: &TaskBoardWorkflowSnapshot,
    plan_markdown: &str,
    acceptance_criteria: &[String],
) -> String {
    let evidence = PlanHashEvidence::from_snapshot(execution_id.trim(), snapshot);
    compute_plan_hash_with_evidence(&evidence, plan_markdown, acceptance_criteria)
}

fn compute_plan_hash_with_evidence(
    evidence: &PlanHashEvidence<'_>,
    plan_markdown: &str,
    acceptance_criteria: &[String],
) -> String {
    let plan_markdown = normalize_markdown(plan_markdown);
    let acceptance_criteria = normalize_acceptance_criteria(acceptance_criteria.iter().cloned());
    let mut digest = Sha256::new();
    append_hash_part(&mut digest, PLAN_HASH_DOMAIN);
    append_hash_part(&mut digest, evidence.execution_id.as_bytes());
    append_hash_part(&mut digest, workflow_kind_tag(evidence.workflow_kind));
    append_optional_hash_part(&mut digest, evidence.execution_repository);
    append_hash_part(&mut digest, &evidence.item_revision.to_be_bytes());
    append_hash_part(&mut digest, &evidence.configuration_revision.to_be_bytes());
    append_hash_part(&mut digest, evidence.policy_version.as_bytes());
    append_optional_hash_part(&mut digest, evidence.provider_revision);
    append_hash_part(&mut digest, plan_markdown.as_bytes());
    for criterion in acceptance_criteria {
        append_hash_part(&mut digest, criterion.as_bytes());
    }
    format!("sha256:{}", hex::encode(digest.finalize()))
}

fn validate_plan_content(
    result: &TaskBoardPlanningResult,
    evidence: &PlanHashEvidence<'_>,
) -> Result<(), TaskBoardPlanningResultError> {
    let plan_markdown = normalize_markdown(&result.plan_markdown);
    if plan_markdown.is_empty() {
        return Err(TaskBoardPlanningResultError::EmptyPlan);
    }
    if result.plan_markdown != plan_markdown {
        return Err(TaskBoardPlanningResultError::NonCanonicalPlanMarkdown);
    }
    let acceptance_criteria =
        normalize_acceptance_criteria(result.acceptance_criteria.iter().cloned());
    if result.acceptance_criteria != acceptance_criteria {
        return Err(TaskBoardPlanningResultError::NonCanonicalAcceptanceCriteria);
    }
    if result.plan_hash
        != compute_plan_hash_with_evidence(evidence, &plan_markdown, &acceptance_criteria)
    {
        return Err(TaskBoardPlanningResultError::InvalidPlanHash);
    }
    Ok(())
}

fn validate_snapshot_evidence(
    snapshot: &TaskBoardWorkflowSnapshot,
) -> Result<(), TaskBoardPlanningResultError> {
    if !supports_planning_approval(snapshot.workflow_kind) {
        return Err(TaskBoardPlanningResultError::UnsupportedWorkflowKind {
            workflow_kind: snapshot.workflow_kind,
        });
    }
    if !is_canonical_optional(snapshot.execution_repository.as_deref()) {
        return Err(TaskBoardPlanningResultError::InvalidExecutionRepository);
    }
    validate_revision_evidence(
        snapshot.item_revision,
        snapshot.configuration_revision,
        snapshot.provider_revision.as_deref(),
    )?;
    if !is_canonical_required(&snapshot.policy_version) {
        return Err(TaskBoardPlanningResultError::InvalidPolicyVersion);
    }
    Ok(())
}

fn validate_result_evidence(
    result: &TaskBoardPlanningResult,
) -> Result<(), TaskBoardPlanningResultError> {
    validate_revision_evidence(
        result.item_revision,
        result.configuration_revision,
        result.provider_revision.as_deref(),
    )
}

fn validate_revision_evidence(
    item_revision: i64,
    configuration_revision: u64,
    provider_revision: Option<&str>,
) -> Result<(), TaskBoardPlanningResultError> {
    if item_revision <= 0 {
        return Err(TaskBoardPlanningResultError::InvalidItemRevision {
            value: item_revision,
        });
    }
    if configuration_revision == 0 {
        return Err(TaskBoardPlanningResultError::InvalidConfigurationRevision {
            value: configuration_revision,
        });
    }
    if provider_revision.is_some_and(|value| !is_canonical_required(value)) {
        return Err(TaskBoardPlanningResultError::InvalidProviderRevision);
    }
    Ok(())
}

fn approval_binding_is_valid(binding: &TaskBoardPlanApprovalBinding) -> bool {
    is_canonical_required(&binding.execution_id)
        && supports_planning_approval(binding.workflow_kind)
        && is_canonical_optional(binding.execution_repository.as_deref())
        && is_canonical_plan_hash(&binding.plan_hash)
        && binding.item_revision > 0
        && binding.configuration_revision > 0
        && is_canonical_required(&binding.policy_version)
        && is_canonical_optional(binding.provider_revision.as_deref())
        && is_canonical_required(&binding.approved_by)
        && canonical_approval_time(&binding.approved_at)
            .is_ok_and(|value| value == binding.approved_at)
}

const fn supports_planning_approval(workflow_kind: TaskBoardWorkflowKind) -> bool {
    matches!(
        workflow_kind,
        TaskBoardWorkflowKind::DefaultTask | TaskBoardWorkflowKind::PrFix
    )
}

fn is_canonical_required(value: &str) -> bool {
    !value.is_empty() && value.trim() == value
}

fn is_canonical_optional(value: Option<&str>) -> bool {
    value.is_none_or(is_canonical_required)
}

fn is_canonical_plan_hash(value: &str) -> bool {
    value.strip_prefix("sha256:").is_some_and(|digest| {
        digest.len() == 64
            && digest
                .bytes()
                .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
    })
}

fn append_hash_part(digest: &mut Sha256, value: &[u8]) {
    digest.update(u64::try_from(value.len()).unwrap_or(u64::MAX).to_be_bytes());
    digest.update(value);
}

fn append_optional_hash_part(digest: &mut Sha256, value: Option<&str>) {
    digest.update([u8::from(value.is_some())]);
    if let Some(value) = value {
        append_hash_part(digest, value.as_bytes());
    }
}

const fn workflow_kind_tag(workflow_kind: TaskBoardWorkflowKind) -> &'static [u8] {
    match workflow_kind {
        TaskBoardWorkflowKind::Unknown => b"unknown",
        TaskBoardWorkflowKind::DefaultTask => b"default_task",
        TaskBoardWorkflowKind::PrFix => b"pr_fix",
        TaskBoardWorkflowKind::PrReview => b"pr_review",
        TaskBoardWorkflowKind::Review => b"review",
    }
}

struct PlanHashEvidence<'a> {
    execution_id: &'a str,
    workflow_kind: TaskBoardWorkflowKind,
    execution_repository: Option<&'a str>,
    item_revision: i64,
    configuration_revision: u64,
    policy_version: &'a str,
    provider_revision: Option<&'a str>,
}

impl<'a> PlanHashEvidence<'a> {
    fn from_snapshot(execution_id: &'a str, snapshot: &'a TaskBoardWorkflowSnapshot) -> Self {
        Self {
            execution_id,
            workflow_kind: snapshot.workflow_kind,
            execution_repository: snapshot.execution_repository.as_deref(),
            item_revision: snapshot.item_revision,
            configuration_revision: snapshot.configuration_revision,
            policy_version: &snapshot.policy_version,
            provider_revision: snapshot.provider_revision.as_deref(),
        }
    }

    fn from_binding(binding: &'a TaskBoardPlanApprovalBinding) -> Self {
        Self {
            execution_id: &binding.execution_id,
            workflow_kind: binding.workflow_kind,
            execution_repository: binding.execution_repository.as_deref(),
            item_revision: binding.item_revision,
            configuration_revision: binding.configuration_revision,
            policy_version: &binding.policy_version,
            provider_revision: binding.provider_revision.as_deref(),
        }
    }
}

fn normalize_markdown(value: &str) -> String {
    let normalized = value.replace("\r\n", "\n").replace('\r', "\n");
    let lines = normalized.split('\n').collect::<Vec<_>>();
    let Some(first) = lines.iter().position(|line| !line.trim().is_empty()) else {
        return String::new();
    };
    let last = lines
        .iter()
        .rposition(|line| !line.trim().is_empty())
        .unwrap_or(first);
    lines[first..=last].join("\n")
}

fn normalize_acceptance_criteria(criteria: impl IntoIterator<Item = String>) -> Vec<String> {
    criteria
        .into_iter()
        .map(|criterion| normalize_markdown(&criterion))
        .filter(|criterion| !criterion.is_empty())
        .collect()
}

fn push_invalidation(
    invalidations: &mut Vec<TaskBoardPlanApprovalInvalidation>,
    invalid: bool,
    reason: TaskBoardPlanApprovalInvalidation,
) {
    if invalid {
        invalidations.push(reason);
    }
}

fn required_trimmed(
    value: &str,
    error: TaskBoardPlanningResultError,
) -> Result<String, TaskBoardPlanningResultError> {
    let value = value.trim();
    if value.is_empty() {
        Err(error)
    } else {
        Ok(value.to_owned())
    }
}

fn canonical_approval_time(value: &str) -> Result<String, TaskBoardPlanningResultError> {
    DateTime::parse_from_rfc3339(value.trim())
        .map(|value| {
            value
                .with_timezone(&Utc)
                .to_rfc3339_opts(SecondsFormat::AutoSi, true)
        })
        .map_err(|_| TaskBoardPlanningResultError::InvalidApprovalTime {
            value: value.to_owned(),
        })
}
