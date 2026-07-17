use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};

use super::policy_compiler_windows::{compile_policy_window, policy_window_rule};
use crate::task_board::{
    TaskBoardAdmissionError, TaskBoardAdmissionEvaluation, TaskBoardAdmissionRequirement,
    TaskBoardAdmissionRequirementKind, TaskBoardAdmissionUsage, TaskBoardWorkflowKind,
    collect_admission_requirements, evaluate_admission_requirements, normalize_repository_slug,
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum TaskBoardPolicyScope {
    Global,
    Workflow(TaskBoardWorkflowKind),
    Repository(String),
}

/// Quantitative policy limits compile into durable admission requirements.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum TaskBoardPolicyLimit {
    Concurrency {
        scope: TaskBoardPolicyScope,
        limit: u64,
        reservation: u64,
    },
    Rate {
        scope: TaskBoardPolicyScope,
        limit: u64,
        window_seconds: u64,
        reservation: u64,
    },
    TokenBudget {
        scope: TaskBoardPolicyScope,
        limit: u64,
        window_seconds: u64,
    },
    MonetaryBudget {
        scope: TaskBoardPolicyScope,
        limit_microusd: u64,
        window_seconds: u64,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardPolicyWeekday {
    Monday,
    Tuesday,
    Wednesday,
    Thursday,
    Friday,
    Saturday,
    Sunday,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardOutsideWindowAction {
    Defer,
    Deny,
}

/// Recurring local-time window using 24-hour `HH:MM` and an IANA timezone.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardPolicyWindow {
    pub scope: TaskBoardPolicyScope,
    pub timezone: String,
    pub weekdays: Vec<TaskBoardPolicyWeekday>,
    pub start_time: String,
    pub end_time: String,
    pub outside_action: TaskBoardOutsideWindowAction,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardAutomationPolicy {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub limits: Vec<TaskBoardPolicyLimit>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub windows: Vec<TaskBoardPolicyWindow>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardPolicyCompilationContext {
    pub workflow_kind: TaskBoardWorkflowKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository: Option<String>,
    pub evaluated_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub estimated_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub estimated_cost_microusd: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardCompiledPolicy {
    pub evaluated_at: String,
    pub requirements: Vec<TaskBoardAdmissionRequirement>,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum TaskBoardPolicyCompilationError {
    #[error("unknown workflow cannot compile an automation policy")]
    UnknownWorkflow,
    #[error("policy repository '{repository}' is invalid, expected owner/repo")]
    InvalidRepository { repository: String },
    #[error("policy scope '{scope}' has an invalid positive limit, window, or reservation")]
    InvalidLimit { scope: String },
    #[error("policy scope '{scope}' requires token estimate evidence")]
    MissingTokenEvidence { scope: String },
    #[error("policy scope '{scope}' requires a positive token estimate")]
    InvalidTokenEvidence { scope: String },
    #[error("policy scope '{scope}' requires monetary cost evidence")]
    MissingCostEvidence { scope: String },
    #[error("policy scope '{scope}' requires a positive microusd cost estimate")]
    InvalidCostEvidence { scope: String },
    #[error("policy rules conflict at canonical key '{key}'")]
    ConflictingRule { key: String },
    #[error("policy scope '{scope}' has invalid IANA timezone '{timezone}'")]
    InvalidTimezone { scope: String, timezone: String },
    #[error("policy scope '{scope}' has no weekdays")]
    EmptyWeekdays { scope: String },
    #[error("policy scope '{scope}' has invalid local window time '{value}'")]
    InvalidLocalTime { scope: String, value: String },
    #[error("policy scope '{scope}' has a zero-length local window")]
    ZeroLengthWindow { scope: String },
    #[error("policy scope '{scope}' has no resolvable local window occurrence")]
    UnresolvableWindow { scope: String },
    #[error("policy evaluation timestamp '{value}' is invalid")]
    InvalidEvaluationTime { value: String },
    #[error(transparent)]
    Admission(#[from] TaskBoardAdmissionError),
}

/// Validate every rule, including rules that do not match a later compilation
/// context, and reject conflicting canonical rules independent of input order.
///
/// # Errors
/// Returns an error for any invalid rule or canonical-key conflict.
pub fn validate_task_board_policy(
    policy: &TaskBoardAutomationPolicy,
) -> Result<(), TaskBoardPolicyCompilationError> {
    let mut rules = Vec::with_capacity(policy.limits.len() + policy.windows.len());
    for limit in &policy.limits {
        rules.push(policy_rule_for_limit(limit)?);
    }
    for window in &policy.windows {
        let scope = ResolvedScope::new(&window.scope)?;
        rules.push(policy_window_rule(window, scope)?);
    }
    rules.sort_by(|left, right| left.key.cmp(&right.key));
    for pair in rules.windows(2) {
        if pair[0].key == pair[1].key && pair[0].value != pair[1].value {
            return Err(TaskBoardPolicyCompilationError::ConflictingRule {
                key: pair[0].key.stable_id(),
            });
        }
    }
    Ok(())
}

/// Compile every matching rule against one frozen clock and evidence snapshot.
///
/// # Errors
/// Returns an error for invalid policy, context, evidence, or window data.
pub fn compile_task_board_policy(
    policy: &TaskBoardAutomationPolicy,
    context: &TaskBoardPolicyCompilationContext,
) -> Result<TaskBoardCompiledPolicy, TaskBoardPolicyCompilationError> {
    validate_task_board_policy(policy)?;
    let context = ResolvedContext::new(context)?;
    let mut requirements = Vec::new();
    for limit in &policy.limits {
        let scope = ResolvedScope::new(limit.scope())?;
        if scope.matches(&context) {
            requirements.push(compile_limit(limit, &scope, &context)?);
        }
    }
    for window in &policy.windows {
        let scope = ResolvedScope::new(&window.scope)?;
        let evaluated_at = scope.matches(&context).then_some(context.evaluated_at);
        if let Some(requirement) = compile_policy_window(window, scope, evaluated_at)? {
            requirements.push(requirement);
        }
    }
    Ok(TaskBoardCompiledPolicy {
        evaluated_at: canonical_time(context.evaluated_at),
        requirements: collect_admission_requirements(requirements)?,
    })
}

/// Compile then evaluate without introducing clocks or mutable storage.
///
/// # Errors
/// Returns an error when policy compilation or admission evaluation fails.
pub fn evaluate_task_board_policy(
    policy: &TaskBoardAutomationPolicy,
    context: &TaskBoardPolicyCompilationContext,
    usage: impl IntoIterator<Item = TaskBoardAdmissionUsage>,
) -> Result<TaskBoardAdmissionEvaluation, TaskBoardPolicyCompilationError> {
    let compiled = compile_task_board_policy(policy, context)?;
    evaluate_admission_requirements(compiled.requirements, usage, &compiled.evaluated_at)
        .map_err(Into::into)
}

impl TaskBoardPolicyLimit {
    const fn scope(&self) -> &TaskBoardPolicyScope {
        match self {
            Self::Concurrency { scope, .. }
            | Self::Rate { scope, .. }
            | Self::TokenBudget { scope, .. }
            | Self::MonetaryBudget { scope, .. } => scope,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum ResolvedScope {
    Global,
    Workflow(TaskBoardWorkflowKind),
    Repository(String),
}

impl ResolvedScope {
    fn new(scope: &TaskBoardPolicyScope) -> Result<Self, TaskBoardPolicyCompilationError> {
        match scope {
            TaskBoardPolicyScope::Global => Ok(Self::Global),
            TaskBoardPolicyScope::Workflow(TaskBoardWorkflowKind::Unknown) => {
                Err(TaskBoardPolicyCompilationError::UnknownWorkflow)
            }
            TaskBoardPolicyScope::Workflow(workflow) => Ok(Self::Workflow(*workflow)),
            TaskBoardPolicyScope::Repository(repository) => {
                normalize_repository_slug(Some(repository))
                    .map(Self::Repository)
                    .ok_or_else(|| TaskBoardPolicyCompilationError::InvalidRepository {
                        repository: repository.clone(),
                    })
            }
        }
    }

    fn matches(&self, context: &ResolvedContext) -> bool {
        match self {
            Self::Global => true,
            Self::Workflow(workflow) => *workflow == context.workflow_kind,
            Self::Repository(repository) => context.repository.as_ref() == Some(repository),
        }
    }

    pub(super) fn key(&self) -> String {
        match self {
            Self::Global => "global".into(),
            Self::Workflow(workflow) => format!("workflow:{}", workflow_name(*workflow)),
            Self::Repository(repository) => format!("repository:{repository}"),
        }
    }
}

struct ResolvedContext {
    workflow_kind: TaskBoardWorkflowKind,
    repository: Option<String>,
    evaluated_at: DateTime<Utc>,
    estimated_tokens: Option<u64>,
    estimated_cost_microusd: Option<u64>,
}

impl ResolvedContext {
    fn new(
        context: &TaskBoardPolicyCompilationContext,
    ) -> Result<Self, TaskBoardPolicyCompilationError> {
        if context.workflow_kind == TaskBoardWorkflowKind::Unknown {
            return Err(TaskBoardPolicyCompilationError::UnknownWorkflow);
        }
        let repository = context
            .repository
            .as_deref()
            .map(|repository| {
                normalize_repository_slug(Some(repository)).ok_or_else(|| {
                    TaskBoardPolicyCompilationError::InvalidRepository {
                        repository: repository.to_owned(),
                    }
                })
            })
            .transpose()?;
        let evaluated_at = DateTime::parse_from_rfc3339(context.evaluated_at.trim())
            .map(|value| value.with_timezone(&Utc))
            .map_err(|_| TaskBoardPolicyCompilationError::InvalidEvaluationTime {
                value: context.evaluated_at.clone(),
            })?;
        Ok(Self {
            workflow_kind: context.workflow_kind,
            repository,
            evaluated_at,
            estimated_tokens: context.estimated_tokens,
            estimated_cost_microusd: context.estimated_cost_microusd,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub(super) enum PolicyRuleKey {
    Limit {
        kind: u8,
        scope: String,
        window_seconds: Option<u64>,
    },
    Window {
        scope: String,
        signature: String,
    },
}

impl PolicyRuleKey {
    fn stable_id(&self) -> String {
        match self {
            Self::Limit {
                kind,
                scope,
                window_seconds,
            } => format!(
                "policy:v1:limit:{kind}:{}:{scope}:{}",
                scope.len(),
                window_seconds.map_or_else(|| "-".into(), |value| value.to_string())
            ),
            Self::Window { scope, signature } => format!(
                "policy:v1:window:{}:{scope}:{}:{signature}",
                scope.len(),
                signature.len()
            ),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum PolicyRuleValue {
    Limit {
        limit: u64,
        reservation: Option<u64>,
    },
    Window {
        outside_action: TaskBoardOutsideWindowAction,
    },
}

pub(super) struct PolicyRule {
    pub(super) key: PolicyRuleKey,
    pub(super) value: PolicyRuleValue,
}

fn policy_rule_for_limit(
    limit: &TaskBoardPolicyLimit,
) -> Result<PolicyRule, TaskBoardPolicyCompilationError> {
    let scope = ResolvedScope::new(limit.scope())?;
    validate_limit(limit, &scope)?;
    let (kind, amount, window_seconds, reservation) = match limit {
        TaskBoardPolicyLimit::Concurrency {
            limit, reservation, ..
        } => (0, *limit, None, Some(*reservation)),
        TaskBoardPolicyLimit::Rate {
            limit,
            window_seconds,
            reservation,
            ..
        } => (1, *limit, Some(*window_seconds), Some(*reservation)),
        TaskBoardPolicyLimit::TokenBudget {
            limit,
            window_seconds,
            ..
        } => (3, *limit, Some(*window_seconds), None),
        TaskBoardPolicyLimit::MonetaryBudget {
            limit_microusd,
            window_seconds,
            ..
        } => (4, *limit_microusd, Some(*window_seconds), None),
    };
    Ok(PolicyRule {
        key: PolicyRuleKey::Limit {
            kind,
            scope: scope.key(),
            window_seconds,
        },
        value: PolicyRuleValue::Limit {
            limit: amount,
            reservation,
        },
    })
}

fn validate_limit(
    limit: &TaskBoardPolicyLimit,
    scope: &ResolvedScope,
) -> Result<(), TaskBoardPolicyCompilationError> {
    let valid = match limit {
        TaskBoardPolicyLimit::Concurrency {
            limit, reservation, ..
        } => *limit > 0 && *reservation > 0,
        TaskBoardPolicyLimit::Rate {
            limit,
            window_seconds,
            reservation,
            ..
        } => *limit > 0 && *window_seconds > 0 && *reservation > 0,
        TaskBoardPolicyLimit::TokenBudget {
            limit,
            window_seconds,
            ..
        } => *limit > 0 && *window_seconds > 0,
        TaskBoardPolicyLimit::MonetaryBudget {
            limit_microusd,
            window_seconds,
            ..
        } => *limit_microusd > 0 && *window_seconds > 0,
    };
    valid
        .then_some(())
        .ok_or_else(|| TaskBoardPolicyCompilationError::InvalidLimit { scope: scope.key() })
}

fn compile_limit(
    limit: &TaskBoardPolicyLimit,
    scope: &ResolvedScope,
    context: &ResolvedContext,
) -> Result<TaskBoardAdmissionRequirement, TaskBoardPolicyCompilationError> {
    let scope_key = scope.key();
    let (kind, limit, window_seconds, reservation) = match limit {
        TaskBoardPolicyLimit::Concurrency {
            limit, reservation, ..
        } => (
            TaskBoardAdmissionRequirementKind::Concurrency,
            *limit,
            None,
            *reservation,
        ),
        TaskBoardPolicyLimit::Rate {
            limit,
            window_seconds,
            reservation,
            ..
        } => (
            TaskBoardAdmissionRequirementKind::Rate,
            *limit,
            Some(*window_seconds),
            *reservation,
        ),
        TaskBoardPolicyLimit::TokenBudget {
            limit,
            window_seconds,
            ..
        } => (
            TaskBoardAdmissionRequirementKind::TokenBudget,
            *limit,
            Some(*window_seconds),
            positive_token_evidence(context.estimated_tokens, &scope_key)?,
        ),
        TaskBoardPolicyLimit::MonetaryBudget {
            limit_microusd,
            window_seconds,
            ..
        } => (
            TaskBoardAdmissionRequirementKind::MonetaryBudget,
            *limit_microusd,
            Some(*window_seconds),
            positive_cost_evidence(context.estimated_cost_microusd, &scope_key)?,
        ),
    };
    Ok(TaskBoardAdmissionRequirement {
        kind,
        scope: scope_key,
        limit,
        window_seconds,
        reservation: Some(reservation),
        available_at: None,
    })
}

fn positive_token_evidence(
    evidence: Option<u64>,
    scope: &str,
) -> Result<u64, TaskBoardPolicyCompilationError> {
    match evidence {
        Some(value) if value > 0 => Ok(value),
        Some(_) => Err(TaskBoardPolicyCompilationError::InvalidTokenEvidence {
            scope: scope.to_owned(),
        }),
        None => Err(TaskBoardPolicyCompilationError::MissingTokenEvidence {
            scope: scope.to_owned(),
        }),
    }
}

fn positive_cost_evidence(
    evidence: Option<u64>,
    scope: &str,
) -> Result<u64, TaskBoardPolicyCompilationError> {
    match evidence {
        Some(value) if value > 0 => Ok(value),
        Some(_) => Err(TaskBoardPolicyCompilationError::InvalidCostEvidence {
            scope: scope.to_owned(),
        }),
        None => Err(TaskBoardPolicyCompilationError::MissingCostEvidence {
            scope: scope.to_owned(),
        }),
    }
}

const fn workflow_name(workflow: TaskBoardWorkflowKind) -> &'static str {
    match workflow {
        TaskBoardWorkflowKind::Unknown => "unknown",
        TaskBoardWorkflowKind::DefaultTask => "default_task",
        TaskBoardWorkflowKind::PrFix => "pr_fix",
        TaskBoardWorkflowKind::PrReview => "pr_review",
        TaskBoardWorkflowKind::Review => "review",
    }
}

fn canonical_time(value: DateTime<Utc>) -> String {
    value.to_rfc3339_opts(SecondsFormat::AutoSi, true)
}
