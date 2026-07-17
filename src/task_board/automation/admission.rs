use std::cmp::Ordering;

use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};

use crate::task_board::{TaskBoardAdmissionRequirement, TaskBoardAdmissionRequirementKind};

/// Authoritative consumption for one admission scope at a frozen instant.
/// Monetary values use integer USD millionths.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardAdmissionUsage {
    pub kind: TaskBoardAdmissionRequirementKind,
    pub scope: String,
    pub consumed: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_seconds: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub available_at: Option<String>,
}

/// Canonical identity for one independently-accounted admission scope.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardAdmissionRequirementKey {
    pub kind: TaskBoardAdmissionRequirementKind,
    pub scope: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_seconds: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_starts_at: Option<String>,
}

impl TaskBoardAdmissionRequirementKey {
    /// Collision-free, versioned representation suitable for durable keys.
    #[must_use]
    pub fn stable_id(&self) -> String {
        let seconds = self
            .window_seconds
            .map_or_else(|| "-".to_owned(), |value| value.to_string());
        let starts_at = self.window_starts_at.as_deref().map_or_else(
            || "-".to_owned(),
            |value| format!("{}:{value}", value.len()),
        );
        format!(
            "admission:v1:{}:{}:{}:{seconds}:{starts_at}",
            kind_name(self.kind),
            self.scope.len(),
            self.scope
        )
    }
}

impl PartialOrd for TaskBoardAdmissionRequirementKey {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for TaskBoardAdmissionRequirementKey {
    fn cmp(&self, other: &Self) -> Ordering {
        key_tuple(self).cmp(&key_tuple(other))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardAdmissionDecision {
    Allowed,
    Deferred,
    Rejected,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardAdmissionBlockReason {
    MissingUsage,
    LimitReached,
    WindowNotStarted,
    WindowClosed,
    MissingResetTime,
    ArithmeticOverflow,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardAdmissionBlocker {
    pub requirement: TaskBoardAdmissionRequirement,
    pub reason: TaskBoardAdmissionBlockReason,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub available_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardAdmissionEvaluation {
    pub decision: TaskBoardAdmissionDecision,
    pub evaluated_at: String,
    /// Canonical frozen inputs, not proof that durable reservations exist.
    pub requirements: Vec<TaskBoardAdmissionRequirement>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub blockers: Vec<TaskBoardAdmissionBlocker>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_available_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum TaskBoardAdmissionError {
    #[error("admission scope is empty")]
    EmptyScope,
    #[error("admission requirement for '{scope}' has a zero limit")]
    ZeroLimit { scope: String },
    #[error("admission requirement for '{scope}' has a zero reservation")]
    ZeroReservation { scope: String },
    #[error("admission requirement for '{scope}' has an invalid window")]
    InvalidWindow { scope: String },
    #[error("admission requirement for '{scope}' has invalid timestamp '{value}'")]
    InvalidTimestamp { scope: String, value: String },
    #[error("admission requirements conflict at canonical key '{key}'")]
    ConflictingRequirement { key: String },
    #[error("admission usage conflicts at canonical key '{key}'")]
    ConflictingUsage { key: String },
    #[error("time-window admission usage is invalid for '{scope}'")]
    InvalidUsageKind { scope: String },
    #[error("admission usage for '{scope}' has an invalid window")]
    InvalidUsageWindow { scope: String },
    #[error("admission evaluation timestamp '{value}' is invalid")]
    InvalidEvaluationTime { value: String },
}

/// Normalize and validate one requirement before deriving its durable key.
///
/// # Errors
/// Returns an error when any requirement field is invalid.
pub fn canonical_admission_requirement_key(
    requirement: &TaskBoardAdmissionRequirement,
) -> Result<TaskBoardAdmissionRequirementKey, TaskBoardAdmissionError> {
    normalize_requirement(requirement.clone()).map(|value| requirement_key(&value))
}

/// Normalize, sort, and deduplicate exact requirements. Non-identical values
/// sharing one canonical key are rejected independent of source order.
///
/// # Errors
/// Returns an error for an invalid requirement or canonical-key conflict.
pub fn collect_admission_requirements(
    requirements: impl IntoIterator<Item = TaskBoardAdmissionRequirement>,
) -> Result<Vec<TaskBoardAdmissionRequirement>, TaskBoardAdmissionError> {
    let mut collected = requirements
        .into_iter()
        .map(normalize_requirement)
        .collect::<Result<Vec<_>, _>>()?;
    collected.sort_by(compare_requirements);
    for pair in collected.windows(2) {
        let left_key = requirement_key(&pair[0]);
        if left_key == requirement_key(&pair[1]) && pair[0] != pair[1] {
            return Err(TaskBoardAdmissionError::ConflictingRequirement {
                key: left_key.stable_id(),
            });
        }
    }
    collected.dedup();
    Ok(collected)
}

/// Evaluate canonical requirements against a caller-frozen authoritative usage
/// snapshot and clock. Only the later transactional layer may reserve capacity.
///
/// # Errors
/// Returns an error for invalid, conflicting, or non-canonical input snapshots.
pub fn evaluate_admission_requirements(
    requirements: impl IntoIterator<Item = TaskBoardAdmissionRequirement>,
    usage: impl IntoIterator<Item = TaskBoardAdmissionUsage>,
    evaluated_at: &str,
) -> Result<TaskBoardAdmissionEvaluation, TaskBoardAdmissionError> {
    let evaluated_at = parse_evaluation_time(evaluated_at)?;
    let requirements = collect_admission_requirements(requirements)?;
    let usage = collect_usage(usage)?;
    let mut blockers = Vec::new();
    for requirement in &requirements {
        if requirement.kind == TaskBoardAdmissionRequirementKind::TimeWindow {
            evaluate_time_window(requirement, evaluated_at, &mut blockers);
        } else {
            evaluate_consumption(requirement, &usage, &mut blockers);
        }
    }
    Ok(TaskBoardAdmissionEvaluation {
        decision: admission_decision(&blockers),
        evaluated_at: canonical_time(evaluated_at),
        requirements,
        next_available_at: latest_available_at(&blockers),
        blockers,
    })
}

fn normalize_requirement(
    mut requirement: TaskBoardAdmissionRequirement,
) -> Result<TaskBoardAdmissionRequirement, TaskBoardAdmissionError> {
    requirement.scope = normalized_scope(&requirement.scope)?;
    if requirement.limit == 0 {
        return Err(TaskBoardAdmissionError::ZeroLimit {
            scope: requirement.scope,
        });
    }
    if requirement.reservation == Some(0) {
        return Err(TaskBoardAdmissionError::ZeroReservation {
            scope: requirement.scope,
        });
    }
    requirement.reservation.get_or_insert(1);
    normalize_requirement_window(&mut requirement)?;
    Ok(requirement)
}

fn normalize_requirement_window(
    requirement: &mut TaskBoardAdmissionRequirement,
) -> Result<(), TaskBoardAdmissionError> {
    match requirement.kind {
        TaskBoardAdmissionRequirementKind::Concurrency => {
            if requirement.window_seconds.is_some() || requirement.available_at.is_some() {
                return invalid_window(requirement);
            }
        }
        TaskBoardAdmissionRequirementKind::Rate
        | TaskBoardAdmissionRequirementKind::TokenBudget
        | TaskBoardAdmissionRequirementKind::MonetaryBudget => {
            if requirement
                .window_seconds
                .is_none_or(|seconds| seconds == 0)
                || requirement.available_at.is_some()
            {
                return invalid_window(requirement);
            }
        }
        TaskBoardAdmissionRequirementKind::TimeWindow => {
            if requirement
                .window_seconds
                .is_none_or(|seconds| seconds == 0)
            {
                return invalid_window(requirement);
            }
            let value = requirement.available_at.as_deref().ok_or_else(|| {
                TaskBoardAdmissionError::InvalidWindow {
                    scope: requirement.scope.clone(),
                }
            })?;
            let parsed =
                parse_time(value).ok_or_else(|| TaskBoardAdmissionError::InvalidTimestamp {
                    scope: requirement.scope.clone(),
                    value: value.to_owned(),
                })?;
            requirement.available_at = Some(canonical_time(parsed));
        }
    }
    Ok(())
}

fn invalid_window<T>(
    requirement: &TaskBoardAdmissionRequirement,
) -> Result<T, TaskBoardAdmissionError> {
    Err(TaskBoardAdmissionError::InvalidWindow {
        scope: requirement.scope.clone(),
    })
}

fn collect_usage(
    usage: impl IntoIterator<Item = TaskBoardAdmissionUsage>,
) -> Result<Vec<TaskBoardAdmissionUsage>, TaskBoardAdmissionError> {
    let mut usage = usage
        .into_iter()
        .map(normalize_usage)
        .collect::<Result<Vec<_>, _>>()?;
    usage.sort_by(compare_usage);
    for pair in usage.windows(2) {
        let key = usage_key(&pair[0]);
        if key == usage_key(&pair[1]) && pair[0] != pair[1] {
            return Err(TaskBoardAdmissionError::ConflictingUsage {
                key: key.stable_id(),
            });
        }
    }
    usage.dedup();
    Ok(usage)
}

fn normalize_usage(
    mut usage: TaskBoardAdmissionUsage,
) -> Result<TaskBoardAdmissionUsage, TaskBoardAdmissionError> {
    usage.scope = normalized_scope(&usage.scope)?;
    match usage.kind {
        TaskBoardAdmissionRequirementKind::Concurrency if usage.window_seconds.is_none() => {}
        TaskBoardAdmissionRequirementKind::Rate
        | TaskBoardAdmissionRequirementKind::TokenBudget
        | TaskBoardAdmissionRequirementKind::MonetaryBudget
            if usage.window_seconds.is_some_and(|seconds| seconds > 0) => {}
        TaskBoardAdmissionRequirementKind::TimeWindow => {
            return Err(TaskBoardAdmissionError::InvalidUsageKind { scope: usage.scope });
        }
        _ => {
            return Err(TaskBoardAdmissionError::InvalidUsageWindow { scope: usage.scope });
        }
    }
    if let Some(value) = usage.available_at.as_deref() {
        let parsed =
            parse_time(value).ok_or_else(|| TaskBoardAdmissionError::InvalidTimestamp {
                scope: usage.scope.clone(),
                value: value.to_owned(),
            })?;
        usage.available_at = Some(canonical_time(parsed));
    }
    Ok(usage)
}

fn evaluate_time_window(
    requirement: &TaskBoardAdmissionRequirement,
    evaluated_at: DateTime<Utc>,
    blockers: &mut Vec<TaskBoardAdmissionBlocker>,
) {
    let starts_at = requirement
        .available_at
        .as_deref()
        .and_then(parse_time)
        .expect("normalized time-window start");
    let duration = requirement
        .window_seconds
        .and_then(|seconds| i64::try_from(seconds).ok())
        .and_then(chrono::Duration::try_seconds);
    let Some(ends_at) = duration.and_then(|value| starts_at.checked_add_signed(value)) else {
        blockers.push(blocker(
            requirement,
            TaskBoardAdmissionBlockReason::ArithmeticOverflow,
            None,
        ));
        return;
    };
    if evaluated_at < starts_at {
        blockers.push(blocker(
            requirement,
            TaskBoardAdmissionBlockReason::WindowNotStarted,
            requirement.available_at.clone(),
        ));
    } else if evaluated_at >= ends_at {
        blockers.push(blocker(
            requirement,
            TaskBoardAdmissionBlockReason::WindowClosed,
            None,
        ));
    }
}

fn evaluate_consumption(
    requirement: &TaskBoardAdmissionRequirement,
    usage: &[TaskBoardAdmissionUsage],
    blockers: &mut Vec<TaskBoardAdmissionBlocker>,
) {
    let key = requirement_key(requirement);
    let Some(observation) = usage.iter().find(|value| usage_key(value) == key) else {
        blockers.push(blocker(
            requirement,
            TaskBoardAdmissionBlockReason::MissingUsage,
            None,
        ));
        return;
    };
    let Some(projected) = observation
        .consumed
        .checked_add(requirement.reservation.expect("normalized reservation"))
    else {
        blockers.push(blocker(
            requirement,
            TaskBoardAdmissionBlockReason::ArithmeticOverflow,
            None,
        ));
        return;
    };
    if projected <= requirement.limit {
        return;
    }
    let missing_reset = requirement.kind != TaskBoardAdmissionRequirementKind::Concurrency
        && observation.available_at.is_none();
    let reason = if missing_reset {
        TaskBoardAdmissionBlockReason::MissingResetTime
    } else {
        TaskBoardAdmissionBlockReason::LimitReached
    };
    blockers.push(blocker(
        requirement,
        reason,
        observation.available_at.clone(),
    ));
}

fn blocker(
    requirement: &TaskBoardAdmissionRequirement,
    reason: TaskBoardAdmissionBlockReason,
    available_at: Option<String>,
) -> TaskBoardAdmissionBlocker {
    TaskBoardAdmissionBlocker {
        requirement: requirement.clone(),
        reason,
        available_at,
    }
}

fn admission_decision(blockers: &[TaskBoardAdmissionBlocker]) -> TaskBoardAdmissionDecision {
    if blockers.iter().any(|blocker| {
        matches!(
            blocker.reason,
            TaskBoardAdmissionBlockReason::MissingUsage
                | TaskBoardAdmissionBlockReason::WindowClosed
                | TaskBoardAdmissionBlockReason::MissingResetTime
                | TaskBoardAdmissionBlockReason::ArithmeticOverflow
        )
    }) {
        TaskBoardAdmissionDecision::Rejected
    } else if blockers.is_empty() {
        TaskBoardAdmissionDecision::Allowed
    } else {
        TaskBoardAdmissionDecision::Deferred
    }
}

fn latest_available_at(blockers: &[TaskBoardAdmissionBlocker]) -> Option<String> {
    blockers
        .iter()
        .filter_map(|blocker| blocker.available_at.as_deref())
        .filter_map(parse_time)
        .max()
        .map(canonical_time)
}

fn compare_requirements(
    left: &TaskBoardAdmissionRequirement,
    right: &TaskBoardAdmissionRequirement,
) -> Ordering {
    requirement_key(left)
        .cmp(&requirement_key(right))
        .then_with(|| left.limit.cmp(&right.limit))
        .then_with(|| left.reservation.cmp(&right.reservation))
}

fn compare_usage(left: &TaskBoardAdmissionUsage, right: &TaskBoardAdmissionUsage) -> Ordering {
    usage_key(left)
        .cmp(&usage_key(right))
        .then_with(|| left.consumed.cmp(&right.consumed))
        .then_with(|| left.available_at.cmp(&right.available_at))
}

fn requirement_key(
    requirement: &TaskBoardAdmissionRequirement,
) -> TaskBoardAdmissionRequirementKey {
    TaskBoardAdmissionRequirementKey {
        kind: requirement.kind,
        scope: requirement.scope.clone(),
        window_seconds: requirement.window_seconds,
        window_starts_at: (requirement.kind == TaskBoardAdmissionRequirementKind::TimeWindow)
            .then(|| requirement.available_at.clone())
            .flatten(),
    }
}

fn usage_key(usage: &TaskBoardAdmissionUsage) -> TaskBoardAdmissionRequirementKey {
    TaskBoardAdmissionRequirementKey {
        kind: usage.kind,
        scope: usage.scope.clone(),
        window_seconds: usage.window_seconds,
        window_starts_at: None,
    }
}

fn key_tuple(key: &TaskBoardAdmissionRequirementKey) -> (u8, &str, Option<u64>, Option<&str>) {
    (
        kind_rank(key.kind),
        key.scope.as_str(),
        key.window_seconds,
        key.window_starts_at.as_deref(),
    )
}

fn normalized_scope(scope: &str) -> Result<String, TaskBoardAdmissionError> {
    let scope = scope.trim();
    if scope.is_empty() {
        Err(TaskBoardAdmissionError::EmptyScope)
    } else {
        Ok(scope.to_owned())
    }
}

const fn kind_rank(kind: TaskBoardAdmissionRequirementKind) -> u8 {
    match kind {
        TaskBoardAdmissionRequirementKind::Concurrency => 0,
        TaskBoardAdmissionRequirementKind::Rate => 1,
        TaskBoardAdmissionRequirementKind::TimeWindow => 2,
        TaskBoardAdmissionRequirementKind::TokenBudget => 3,
        TaskBoardAdmissionRequirementKind::MonetaryBudget => 4,
    }
}

const fn kind_name(kind: TaskBoardAdmissionRequirementKind) -> &'static str {
    match kind {
        TaskBoardAdmissionRequirementKind::Concurrency => "concurrency",
        TaskBoardAdmissionRequirementKind::Rate => "rate",
        TaskBoardAdmissionRequirementKind::TimeWindow => "time_window",
        TaskBoardAdmissionRequirementKind::TokenBudget => "token_budget",
        TaskBoardAdmissionRequirementKind::MonetaryBudget => "monetary_budget",
    }
}

fn parse_evaluation_time(value: &str) -> Result<DateTime<Utc>, TaskBoardAdmissionError> {
    parse_time(value.trim()).ok_or_else(|| TaskBoardAdmissionError::InvalidEvaluationTime {
        value: value.to_owned(),
    })
}

fn parse_time(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|parsed| parsed.with_timezone(&Utc))
}

fn canonical_time(value: DateTime<Utc>) -> String {
    value.to_rfc3339_opts(SecondsFormat::AutoSi, true)
}
