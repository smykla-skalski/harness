use clap::ValueEnum;
use clap::builder::PossibleValue;
use serde::{Deserialize, Serialize};

use super::automation::TaskBoardWorkflowKind;
use super::lane::TaskBoardLaneOrigin;

pub const CURRENT_TASK_BOARD_ITEM_VERSION: u32 = 1;
pub const MAX_TASK_BOARD_ESTIMATE: u64 = i64::MAX as u64;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TaskBoardItem {
    pub schema_version: u32,
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub body: String,
    #[serde(default)]
    pub status: TaskBoardStatus,
    #[serde(default)]
    pub priority: TaskBoardPriority,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tags: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub target_project_types: Vec<String>,
    #[serde(default)]
    pub agent_mode: AgentMode,
    #[serde(default)]
    pub workflow_kind: TaskBoardWorkflowKind,
    #[serde(default)]
    pub kind: TaskBoardItemKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub execution_repository: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub estimated_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub estimated_cost_microusd: Option<u64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub external_refs: Vec<ExternalRef>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub imported_from_provider: Option<ExternalRefProvider>,
    #[serde(default)]
    pub planning: PlanningState,
    #[serde(default, skip_serializing_if = "TaskBoardWorkflowState::is_default")]
    pub workflow: TaskBoardWorkflowState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub work_item_id: Option<String>,
    #[serde(default)]
    pub usage: TaskUsage,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_item_id: Option<String>,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub child_order: u32,
    /// An explicit zero-based lane slot. `None` uses derived default ordering.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lane_position: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lane_origin: Option<TaskBoardLaneOrigin>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lane_set_at: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deleted_at: Option<String>,
}

impl TaskBoardItem {
    #[must_use]
    pub fn new(id: String, title: String, body: String, now: String) -> Self {
        Self {
            schema_version: CURRENT_TASK_BOARD_ITEM_VERSION,
            id,
            title,
            body,
            status: TaskBoardStatus::Todo,
            priority: TaskBoardPriority::Medium,
            tags: Vec::new(),
            project_id: None,
            target_project_types: Vec::new(),
            agent_mode: AgentMode::Headless,
            workflow_kind: TaskBoardWorkflowKind::DefaultTask,
            kind: TaskBoardItemKind::default(),
            execution_repository: None,
            estimated_tokens: None,
            estimated_cost_microusd: None,
            external_refs: Vec::new(),
            imported_from_provider: None,
            planning: PlanningState::default(),
            workflow: TaskBoardWorkflowState::default(),
            session_id: None,
            work_item_id: None,
            usage: TaskUsage::default(),
            parent_item_id: None,
            child_order: 0,
            lane_position: None,
            lane_origin: None,
            lane_set_at: None,
            created_at: now.clone(),
            updated_at: now,
            deleted_at: None,
        }
    }

    #[must_use]
    pub const fn is_deleted(&self) -> bool {
        self.deleted_at.is_some()
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardWorkflowState {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub execution_id: Option<String>,
    #[serde(default)]
    pub status: TaskBoardWorkflowStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current_step_id: Option<String>,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub attempts: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pr_number: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pr_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_error: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub policy_trace_ids: Vec<String>,
}

/// Maximum number of policy trace ids retained per item. Oldest entries are
/// dropped when the cap is reached so an item that re-dispatches indefinitely
/// cannot grow unbounded on disk.
pub const MAX_POLICY_TRACE_IDS: usize = 32;

impl TaskBoardWorkflowState {
    #[must_use]
    pub fn is_default(&self) -> bool {
        self == &Self::default()
    }

    /// Append a policy trace id, capping growth at `MAX_POLICY_TRACE_IDS` by
    /// dropping the oldest ids first.
    pub fn push_policy_trace_id(&mut self, trace_id: String) {
        self.policy_trace_ids.push(trace_id);
        let len = self.policy_trace_ids.len();
        if len > MAX_POLICY_TRACE_IDS {
            self.policy_trace_ids.drain(0..len - MAX_POLICY_TRACE_IDS);
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, ValueEnum)]
#[value(rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardWorkflowStatus {
    #[default]
    Idle,
    Running,
    Paused,
    Completed,
    Failed,
    Cancelled,
}

#[derive(
    Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, ValueEnum,
)]
#[value(rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardStatus {
    Backlog,
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

#[derive(
    Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, ValueEnum,
)]
#[value(rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
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
pub enum AgentMode {
    #[default]
    Headless,
    Interactive,
    Planning,
    Evaluate,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExternalRef {
    pub provider: ExternalRefProvider,
    pub external_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sync_state: Option<ExternalRefSyncState>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, ValueEnum)]
#[value(rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum ExternalRefProvider {
    #[value(name = "github", alias = "git_hub")]
    #[serde(rename = "github", alias = "git_hub")]
    GitHub,
    Todoist,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExternalRefSyncState {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<TaskBoardStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub synced_at: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlanningState {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approved_by: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approved_at: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct TaskUsage {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost_usd: Option<f64>,
}

#[expect(
    clippy::trivially_copy_pass_by_ref,
    reason = "serde skip_serializing_if requires a function taking `&T`"
)]
fn is_zero(value: &u32) -> bool {
    *value == 0
}

#[cfg(test)]
mod tests {
    use super::{TaskBoardItem, TaskBoardItemKind, TaskBoardStatus};

    #[test]
    fn backlog_is_the_canonical_status_wire_value() {
        assert_eq!(
            serde_json::to_string(&TaskBoardStatus::Backlog).expect("serialize backlog"),
            "\"backlog\""
        );
        assert_eq!(
            serde_json::from_str::<TaskBoardStatus>("\"backlog\"").expect("deserialize backlog"),
            TaskBoardStatus::Backlog
        );
    }

    #[test]
    fn public_status_wire_rejects_legacy_umbrella() {
        assert!(
            serde_json::from_str::<TaskBoardStatus>("\"umbrella\"").is_err(),
            "legacy umbrella is accepted only at persisted-data migration boundaries"
        );
    }

    #[test]
    fn new_item_defaults_to_task_kind() {
        let item = TaskBoardItem::new(
            "item-1".into(),
            "title".into(),
            String::new(),
            "2026-07-21T00:00:00Z".into(),
        );
        assert_eq!(item.kind, TaskBoardItemKind::Task);
        assert!(item.kind.is_dispatchable());
    }

    #[test]
    fn missing_kind_on_the_wire_defaults_to_task() {
        let item: TaskBoardItem = serde_json::from_str(
            r#"{
                "schema_version": 1,
                "id": "item-1",
                "title": "title",
                "created_at": "2026-07-21T00:00:00Z",
                "updated_at": "2026-07-21T00:00:00Z"
            }"#,
        )
        .expect("deserialize item without a kind field");
        assert_eq!(item.kind, TaskBoardItemKind::Task);
    }

    #[test]
    fn kind_wire_values_round_trip() {
        assert_eq!(
            serde_json::to_string(&TaskBoardItemKind::Task).expect("serialize task"),
            "\"task\""
        );
        assert_eq!(
            serde_json::to_string(&TaskBoardItemKind::Umbrella).expect("serialize umbrella"),
            "\"umbrella\""
        );
        assert_eq!(
            serde_json::from_str::<TaskBoardItemKind>("\"umbrella\"").expect("deserialize"),
            TaskBoardItemKind::Umbrella
        );
    }

    #[test]
    fn a_future_kind_deserializes_safely_to_unknown() {
        assert_eq!(
            serde_json::from_str::<TaskBoardItemKind>("\"epic\"")
                .expect("an unrecognized kind must not fail to deserialize"),
            TaskBoardItemKind::Unknown("epic".into())
        );
    }

    #[test]
    fn an_unknown_kind_round_trips_its_original_wire_value() {
        // A newer writer's kind must survive an older reader's write-back
        // (e.g. an update to some unrelated field, which re-serializes every
        // field including kind) instead of being downgraded to the literal
        // string "unknown".
        let kind: TaskBoardItemKind =
            serde_json::from_str("\"epic\"").expect("deserialize a future kind");
        assert_eq!(serde_json::to_string(&kind).expect("serialize"), "\"epic\"");
    }

    #[test]
    fn only_task_kind_is_dispatchable() {
        assert!(TaskBoardItemKind::Task.is_dispatchable());
        assert!(!TaskBoardItemKind::Umbrella.is_dispatchable());
        assert!(!TaskBoardItemKind::Unknown("epic".into()).is_dispatchable());
    }

    #[test]
    fn as_wire_str_matches_the_serde_wire_value() {
        for kind in [
            TaskBoardItemKind::Task,
            TaskBoardItemKind::Umbrella,
            TaskBoardItemKind::Unknown("epic".into()),
        ] {
            assert_eq!(
                serde_json::to_value(&kind).expect("serialize kind"),
                kind.as_wire_str()
            );
        }
    }
}
