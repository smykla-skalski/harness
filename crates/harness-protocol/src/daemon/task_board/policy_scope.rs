//! The durable admission policy's declarative shape, relocated here from
//! `harness-task-board::automation::policy_compiler`
//! (`TaskBoardPolicyLimit::scope`) and `automation::policy_compiler_windows`
//! (`TaskBoardPolicyWeekday::matches`, using `chrono::Weekday`, already a
//! `harness-protocol` dependency). Both moved because a new inherent method
//! can only be added to a type in its defining crate. The compiler that
//! turns these types into admission requirements
//! (`validate_task_board_policy`, `compile_task_board_policy`,
//! `TaskBoardPolicyCompilationError`, and the private `ResolvedScope`/
//! `ResolvedContext`/`PolicyRule*`/window-resolution machinery) stays in
//! `harness-task-board`, since it reaches `chrono_tz`,
//! `normalize_repository_slug`, and the admission requirement types this
//! move has no need for. `harness-task-board` re-exports every name below at
//! the same path.

use chrono::Weekday;
use serde::{Deserialize, Serialize};

use super::item_intent::TaskBoardWorkflowKind;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum TaskBoardPolicyScope {
    Global,
    Workflow(TaskBoardWorkflowKind),
    Repository(String),
}

/// Quantitative policy limits compile into durable admission requirements.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
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

impl TaskBoardPolicyLimit {
    #[must_use]
    pub const fn scope(&self) -> &TaskBoardPolicyScope {
        match self {
            Self::Concurrency { scope, .. }
            | Self::Rate { scope, .. }
            | Self::TokenBudget { scope, .. }
            | Self::MonetaryBudget { scope, .. } => scope,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum TaskBoardPolicyWeekday {
    Monday,
    Tuesday,
    Wednesday,
    Thursday,
    Friday,
    Saturday,
    Sunday,
}

impl TaskBoardPolicyWeekday {
    #[must_use]
    pub const fn matches(self, weekday: Weekday) -> bool {
        matches!(
            (self, weekday),
            (Self::Monday, Weekday::Mon)
                | (Self::Tuesday, Weekday::Tue)
                | (Self::Wednesday, Weekday::Wed)
                | (Self::Thursday, Weekday::Thu)
                | (Self::Friday, Weekday::Fri)
                | (Self::Saturday, Weekday::Sat)
                | (Self::Sunday, Weekday::Sun)
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum TaskBoardOutsideWindowAction {
    Defer,
    Deny,
}

/// Recurring local-time window using 24-hour `HH:MM` and an IANA timezone.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardPolicyWindow {
    pub scope: TaskBoardPolicyScope,
    pub timezone: String,
    pub weekdays: Vec<TaskBoardPolicyWeekday>,
    pub start_time: String,
    pub end_time: String,
    pub outside_action: TaskBoardOutsideWindowAction,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardAutomationPolicy {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub limits: Vec<TaskBoardPolicyLimit>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub windows: Vec<TaskBoardPolicyWindow>,
}

// Existing coverage for these types stays in
// `harness-task-board::automation::policy_compiler`'s own test module,
// exercised through the re-export below.
