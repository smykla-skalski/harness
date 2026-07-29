use std::collections::BTreeSet;

use async_trait::async_trait;
use harness_kernel::errors::{CliError, CliErrorKind};
use serde::{Deserialize, Serialize};

use super::{
    TaskBoardDependencyTriageDisposition, TaskBoardDependencyTriageError,
    TaskBoardDependencyTriageResult, validate_task_board_dependency_triage_evidence,
};

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, utoipa::ToSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardDependencyActionKind {
    RecordResult,
    CompleteReport,
    RequireHuman,
    WaitForChecks,
    DispatchFixer,
    ContinueWorkflow,
}

impl TaskBoardDependencyActionKind {
    const fn capability(self) -> TaskBoardDependencyActionCapability {
        match self {
            Self::RecordResult | Self::CompleteReport | Self::RequireHuman => {
                TaskBoardDependencyActionCapability::TaskBoardAudit
            }
            Self::WaitForChecks => TaskBoardDependencyActionCapability::GitHubRead,
            Self::DispatchFixer => TaskBoardDependencyActionCapability::CodexDispatch,
            Self::ContinueWorkflow => TaskBoardDependencyActionCapability::TaskBoardAdvance,
        }
    }

    const fn label(self) -> &'static str {
        match self {
            Self::RecordResult => "record_result",
            Self::CompleteReport => "complete_report",
            Self::RequireHuman => "require_human",
            Self::WaitForChecks => "wait_for_checks",
            Self::DispatchFixer => "dispatch_fixer",
            Self::ContinueWorkflow => "continue_workflow",
        }
    }
}

impl TryFrom<&str> for TaskBoardDependencyActionKind {
    type Error = TaskBoardDependencyTriageError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        match value {
            "record_result" => Ok(Self::RecordResult),
            "complete_report" => Ok(Self::CompleteReport),
            "require_human" => Ok(Self::RequireHuman),
            "wait_for_checks" => Ok(Self::WaitForChecks),
            "dispatch_fixer" => Ok(Self::DispatchFixer),
            "continue_workflow" => Ok(Self::ContinueWorkflow),
            _ => Err(TaskBoardDependencyTriageError::UnsupportedAction),
        }
    }
}

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, utoipa::ToSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardDependencyActionCapability {
    TaskBoardAudit,
    GitHubRead,
    CodexDispatch,
    TaskBoardAdvance,
}

impl TaskBoardDependencyActionCapability {
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::TaskBoardAudit => "task_board.audit",
            Self::GitHubRead => "github.read",
            Self::CodexDispatch => "codex.dispatch",
            Self::TaskBoardAdvance => "task_board.advance",
        }
    }

    const fn is_mutating(self) -> bool {
        matches!(self, Self::CodexDispatch | Self::TaskBoardAdvance)
    }
}

impl TryFrom<&str> for TaskBoardDependencyActionCapability {
    type Error = TaskBoardDependencyTriageError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        match value {
            "task_board.audit" => Ok(Self::TaskBoardAudit),
            "github.read" => Ok(Self::GitHubRead),
            "codex.dispatch" => Ok(Self::CodexDispatch),
            "task_board.advance" => Ok(Self::TaskBoardAdvance),
            _ => Err(TaskBoardDependencyTriageError::UnsupportedRequiredTool),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskBoardDependencyValidatedAction {
    pub order: u32,
    pub kind: TaskBoardDependencyActionKind,
    pub reason: String,
    pub repository: String,
    pub pull_request_number: u64,
    pub exact_head_revision: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskBoardDependencyActionPlan {
    pub disposition: TaskBoardDependencyTriageDisposition,
    pub capabilities: BTreeSet<TaskBoardDependencyActionCapability>,
    pub actions: Vec<TaskBoardDependencyValidatedAction>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardDependencyActionAuditDecision {
    Accepted,
    Rejected,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardDependencyActionAuditRecord {
    pub source_result: TaskBoardDependencyTriageResult,
    pub action: String,
    pub decision: TaskBoardDependencyActionAuditDecision,
    pub reason: String,
}

#[async_trait]
pub trait TaskBoardDependencyActionAuditSink: Send + Sync {
    /// Persist one action admission decision before that action's registered capability runs.
    ///
    /// # Errors
    ///
    /// Returns a storage error. Execution stops instead of running without an audit record.
    async fn record(&self, record: TaskBoardDependencyActionAuditRecord) -> Result<(), CliError>;
}

#[async_trait]
pub trait TaskBoardDependencyActionCapabilityRegistry: Send + Sync {
    fn supports(&self, capability: TaskBoardDependencyActionCapability) -> bool;

    /// Run the application-owned implementation for one typed action.
    ///
    /// # Errors
    ///
    /// Returns the registered capability's execution error.
    async fn execute(
        &self,
        capability: TaskBoardDependencyActionCapability,
        action: &TaskBoardDependencyValidatedAction,
    ) -> Result<(), CliError>;
}

/// Compile untrusted triage strings into one exact-head, application-owned action plan.
///
/// # Errors
///
/// Returns a fail-closed error for unknown actions or tools, a disposition-specific sequence
/// mismatch, or a capability list that does not exactly describe the selected actions.
pub fn compile_task_board_dependency_action_plan(
    result: &TaskBoardDependencyTriageResult,
) -> Result<TaskBoardDependencyActionPlan, TaskBoardDependencyTriageError> {
    let mut capabilities = BTreeSet::new();
    for tool in &result.required_tools {
        let capability = TaskBoardDependencyActionCapability::try_from(tool.as_str())?;
        if !capabilities.insert(capability) {
            return Err(TaskBoardDependencyTriageError::InvalidRequiredTool);
        }
    }
    let actions = result
        .next_steps
        .iter()
        .map(|step| {
            Ok(TaskBoardDependencyValidatedAction {
                order: step.order,
                kind: TaskBoardDependencyActionKind::try_from(step.action.as_str())?,
                reason: step.reason.clone(),
                repository: result.repository.clone(),
                pull_request_number: result.pull_request_number,
                exact_head_revision: result.exact_head_revision.clone(),
            })
        })
        .collect::<Result<Vec<_>, TaskBoardDependencyTriageError>>()?;

    validate_action_sequence(result.disposition, &actions)?;
    let required = actions
        .iter()
        .map(|action| action.kind.capability())
        .collect::<BTreeSet<_>>();
    if matches!(
        result.disposition,
        TaskBoardDependencyTriageDisposition::ReportOnly
            | TaskBoardDependencyTriageDisposition::HumanRequired
    ) && capabilities
        .iter()
        .any(|capability| capability.is_mutating())
    {
        return Err(TaskBoardDependencyTriageError::MutationForbidden);
    }
    if capabilities != required {
        return Err(TaskBoardDependencyTriageError::ActionCapabilityMismatch);
    }

    Ok(TaskBoardDependencyActionPlan {
        disposition: result.disposition,
        capabilities,
        actions,
    })
}

/// Execute a fully preflighted plan through typed application capabilities.
///
/// # Errors
///
/// Returns before side effects when plan validation, capability resolution, or audit persistence
/// fails. Registered capability failures are propagated after their accepted admission was recorded.
pub async fn execute_task_board_dependency_action_plan(
    result: &TaskBoardDependencyTriageResult,
    expected_repository: &str,
    expected_pull_request_number: u64,
    expected_head_revision: &str,
    registry: &dyn TaskBoardDependencyActionCapabilityRegistry,
    audit: &dyn TaskBoardDependencyActionAuditSink,
) -> Result<(), CliError> {
    let plan = validated_plan_or_audit(
        result,
        expected_repository,
        expected_pull_request_number,
        expected_head_revision,
        audit,
    )
    .await?;
    preflight_capabilities(result, &plan, registry, audit).await?;
    for action in &plan.actions {
        let capability = action.kind.capability();
        audit
            .record(TaskBoardDependencyActionAuditRecord {
                source_result: result.clone(),
                action: action.kind.label().into(),
                decision: TaskBoardDependencyActionAuditDecision::Accepted,
                reason: format!(
                    "validated exact-head action resolved to {}",
                    capability.label()
                ),
            })
            .await?;
        registry.execute(capability, action).await?;
    }
    Ok(())
}

async fn validated_plan_or_audit(
    result: &TaskBoardDependencyTriageResult,
    expected_repository: &str,
    expected_pull_request_number: u64,
    expected_head_revision: &str,
    audit: &dyn TaskBoardDependencyActionAuditSink,
) -> Result<TaskBoardDependencyActionPlan, CliError> {
    let plan = validate_task_board_dependency_triage_evidence(
        result,
        expected_repository,
        expected_pull_request_number,
        expected_head_revision,
    )
    .and_then(|()| compile_task_board_dependency_action_plan(result));
    match plan {
        Ok(plan) => Ok(plan),
        Err(error) => {
            audit
                .record(rejected_record(result, "<plan>", error.to_string()))
                .await?;
            Err(CliErrorKind::workflow_parse(error.to_string()).into())
        }
    }
}

async fn preflight_capabilities(
    result: &TaskBoardDependencyTriageResult,
    plan: &TaskBoardDependencyActionPlan,
    registry: &dyn TaskBoardDependencyActionCapabilityRegistry,
    audit: &dyn TaskBoardDependencyActionAuditSink,
) -> Result<(), CliError> {
    for action in &plan.actions {
        let capability = action.kind.capability();
        if !registry.supports(capability) {
            let reason = format!(
                "application capability is unavailable: {}",
                capability.label()
            );
            audit
                .record(rejected_record(result, action.kind.label(), &reason))
                .await?;
            return Err(CliErrorKind::workflow_io(reason).into());
        }
    }
    Ok(())
}

fn validate_action_sequence(
    disposition: TaskBoardDependencyTriageDisposition,
    actions: &[TaskBoardDependencyValidatedAction],
) -> Result<(), TaskBoardDependencyTriageError> {
    let terminal = match disposition {
        TaskBoardDependencyTriageDisposition::ReportOnly => {
            TaskBoardDependencyActionKind::CompleteReport
        }
        TaskBoardDependencyTriageDisposition::HumanRequired => {
            TaskBoardDependencyActionKind::RequireHuman
        }
        TaskBoardDependencyTriageDisposition::WaitForChecks => {
            TaskBoardDependencyActionKind::WaitForChecks
        }
        TaskBoardDependencyTriageDisposition::FixRequired => {
            TaskBoardDependencyActionKind::DispatchFixer
        }
        TaskBoardDependencyTriageDisposition::ContinueSafe => {
            TaskBoardDependencyActionKind::ContinueWorkflow
        }
    };
    let expected = [
        (1, TaskBoardDependencyActionKind::RecordResult),
        (2, terminal),
    ];
    if actions.len() != expected.len()
        || actions.iter().zip(expected).any(|(action, (order, kind))| {
            action.order != order || action.kind != kind || action.reason.trim().is_empty()
        })
    {
        return Err(TaskBoardDependencyTriageError::ActionPlanContradictsDisposition);
    }
    Ok(())
}

fn rejected_record(
    result: &TaskBoardDependencyTriageResult,
    action: impl Into<String>,
    reason: impl Into<String>,
) -> TaskBoardDependencyActionAuditRecord {
    TaskBoardDependencyActionAuditRecord {
        source_result: result.clone(),
        action: action.into(),
        decision: TaskBoardDependencyActionAuditDecision::Rejected,
        reason: reason.into(),
    }
}

#[cfg(test)]
mod tests;
