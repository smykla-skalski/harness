//! Task-board leaf enums, relocated here from `harness-task-board::types`.
//!
//! `TaskBoardItem` and `TaskBoardWorkflowState` stay behind: they carry real
//! domain state (`TaskBoardItem::new`/`is_deleted`, workflow trace-id
//! bookkeeping) and are never embedded by the wire types this move exists
//! for. These five names are pure data with only self-contained inherent
//! methods, so they moved; `harness-task-board::types` re-exports them
//! unchanged at the same path.

use std::borrow::Cow;

use clap::ValueEnum;
use clap::builder::PossibleValue;
use serde::{Deserialize, Serialize};
use utoipa::openapi::schema::{Schema, Type};
use utoipa::openapi::{ObjectBuilder, RefOr};
use utoipa::{PartialSchema, ToSchema};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, ValueEnum)]
#[value(rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum TaskBoardWorkflowStatus {
    #[default]
    Idle,
    /// A dispatch has been reserved for this ticket and one execution now owns
    /// it, but the worker has not started yet. The ticket stays in Todo through
    /// this window; the state records which execution admitted it so a repeated
    /// admission is visibly a no-op rather than a second competing run.
    Admitting,
    Running,
    Paused,
    Completed,
    Failed,
    Cancelled,
}

impl TaskBoardWorkflowStatus {
    /// Every workflow status, derived from the `ValueEnum` variants so code that
    /// aggregates across all statuses can never silently miss a newly added one.
    #[must_use]
    pub fn all() -> &'static [Self] {
        <Self as ValueEnum>::value_variants()
    }
}

#[derive(
    Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, ValueEnum,
)]
#[value(rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum TaskBoardStatus {
    Inbox,
    #[default]
    Todo,
    Planning,
    #[value(name = "in_progress", alias = "in-progress")]
    InProgress,
    #[value(name = "agentic_review", alias = "agentic-review")]
    AgenticReview,
    Testing,
    #[value(name = "in_review", alias = "in-review")]
    InReview,
    #[value(name = "to_review", alias = "to-review")]
    ToReview,
    #[value(name = "human_required", alias = "human-required")]
    HumanRequired,
    Failed,
    Done,
    // Legacy statuses stay decodable so existing persisted task-board data and
    // older clients can migrate into the current visible lane model.
    New,
    #[value(name = "plan_review")]
    PlanReview,
    #[value(name = "needs_you", alias = "needs-you")]
    NeedsYou,
    Blocked,
}

impl TaskBoardStatus {
    #[must_use]
    pub fn canonical_persisted_status(self) -> Self {
        match self {
            Self::New => Self::Todo,
            Self::PlanReview => Self::AgenticReview,
            Self::NeedsYou => Self::HumanRequired,
            Self::Blocked => Self::Failed,
            status => status,
        }
    }
}

/// What kind of item a task-board row is. Open by design: a future variant is
/// an additive change, and any wire value this binary does not recognize
/// (older reader against a newer writer, or the reverse) falls back to
/// `Unknown`, which keeps the original string so a later write-back (an
/// update to some unrelated field re-serializes every field, `kind`
/// included) round-trips it instead of silently downgrading it to the
/// literal string `"unknown"`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum TaskBoardItemKind {
    /// A leaf unit of work an agent can pick up and run.
    #[default]
    Task,
    /// A tracking item grouping other items; never a unit of work itself.
    Umbrella,
    /// A kind this binary does not recognize, carrying the original wire
    /// value verbatim.
    Unknown(String),
}

impl TaskBoardItemKind {
    /// Whether this kind can be dispatched to an agent as a unit of work.
    /// Anything other than `Task` (including `Unknown`, so a future kind
    /// defaults to non-dispatchable until code explicitly allows it) is
    /// refused.
    #[must_use]
    pub const fn is_dispatchable(&self) -> bool {
        matches!(self, Self::Task)
    }

    /// The `snake_case` wire/CLI value, for user-facing messages that must
    /// match `--kind` and JSON rather than the Rust variant name.
    #[must_use]
    pub fn as_wire_str(&self) -> &str {
        match self {
            Self::Task => "task",
            Self::Umbrella => "umbrella",
            Self::Unknown(raw) => raw,
        }
    }
}

impl Serialize for TaskBoardItemKind {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_wire_str())
    }
}

impl<'de> Deserialize<'de> for TaskBoardItemKind {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = String::deserialize(deserializer)?;
        Ok(match raw.as_str() {
            "task" => Self::Task,
            "umbrella" => Self::Umbrella,
            _ => Self::Unknown(raw),
        })
    }
}

// utoipa cannot derive a schema for the hand-written serde above (it emits a
// bare string, not a tagged enum), and a `value_type` override is rejected on
// an enum-variant field such as `DispatchBlockReason::Kind`, so the type owns a
// manual `{type: string}` component that references cleanly from every use.
impl PartialSchema for TaskBoardItemKind {
    fn schema() -> RefOr<Schema> {
        ObjectBuilder::new()
            .schema_type(Type::String)
            .description(Some(
                "Open string enum: `task`, `umbrella`, or a forward-compatible unknown value.",
            ))
            .into()
    }
}

impl ToSchema for TaskBoardItemKind {
    fn name() -> Cow<'static, str> {
        Cow::Borrowed("TaskBoardItemKind")
    }
}

impl ValueEnum for TaskBoardItemKind {
    fn value_variants<'a>() -> &'a [Self] {
        &[Self::Task, Self::Umbrella]
    }

    fn to_possible_value(&self) -> Option<PossibleValue> {
        match self {
            Self::Task => Some(PossibleValue::new("task")),
            Self::Umbrella => Some(PossibleValue::new("umbrella")),
            Self::Unknown(_) => None,
        }
    }
}

#[derive(
    Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, ValueEnum,
)]
#[value(rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum TaskBoardPriority {
    Low,
    #[default]
    Medium,
    High,
    Critical,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, ValueEnum)]
#[value(rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum AgentMode {
    #[default]
    Headless,
    Interactive,
    Planning,
    Evaluate,
}

// Existing coverage for these types stays in `harness-task-board::types`'s own
// test module, exercised through the re-export below; duplicating it here
// would diverge from the "pure relocation" contract this move keeps.
