use serde::{Deserialize, Serialize};

// `AgentMode`/`TaskBoardItemKind`/`TaskBoardPriority`/`TaskBoardStatus`/
// `TaskBoardWorkflowStatus` relocated to
// `harness_protocol::daemon::task_board::types` (#1145): pure data with only
// self-contained inherent methods, needed there because
// `TaskBoardOrchestratorSettings`'s closure and the dispatch/summary wire
// types embed them directly. `TaskBoardItem` and `TaskBoardWorkflowState`
// stay here: they carry real domain state
// (`TaskBoardItem::new`/`is_deleted`, workflow trace-id bookkeeping) that no
// relocated wire type embeds.
pub use harness_protocol::daemon::task_board::types::{
    AgentMode, TaskBoardItemKind, TaskBoardPriority, TaskBoardStatus, TaskBoardWorkflowStatus,
};

pub use super::item_fields::{
    ExternalRef, ExternalRefProvider, ExternalRefSyncState, PlanningState, TaskUsage,
};
pub use super::item_intent::{PrIntentSet, TaskBoardWorkflowKind};
use super::lane::TaskBoardLaneOrigin;

pub const CURRENT_TASK_BOARD_ITEM_VERSION: u32 = 1;
pub const MAX_TASK_BOARD_ESTIMATE: u64 = i64::MAX as u64;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, utoipa::ToSchema)]
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
    /// The registered project this item's work came from. Assigned by the
    /// write path from whichever origin the item carries, and stable across a
    /// rename of that project.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_project_id: Option<String>,
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
    /// Legacy owner. Set only on items dispatched before the workspace owners
    /// below existed; a fresh dispatch leaves it empty and fills those instead.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub work_item_id: Option<String>,
    /// Durable workspace the dispatched worker belongs to.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace_id: Option<String>,
    /// Checkout the daemon created for that workspace to run this item in.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub working_copy_id: Option<String>,
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
    /// Why a tombstoned item was deleted. `ProviderExclusion` is reversible by
    /// the sync layer when the triggering provider label is later removed;
    /// `Manual` never is.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tombstone_cause: Option<TaskBoardTombstoneCause>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum TaskBoardTombstoneCause {
    Manual,
    ProviderExclusion,
}

impl TaskBoardItem {
    /// The owner a dispatched item is linked to, most specific first.
    ///
    /// Same order as `DispatchAppliedTask::launch_owner_id`, because a frozen
    /// launch is validated by comparing the two; disagreeing would read an
    /// untouched launch as changed.
    #[must_use]
    pub fn owner_id(&self) -> Option<&str> {
        self.workspace_id
            .as_deref()
            .or(self.session_id.as_deref())
            .or(self.working_copy_id.as_deref())
    }

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
            source_project_id: None,
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
            workspace_id: None,
            working_copy_id: None,
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
            tombstone_cause: None,
        }
    }

    #[must_use]
    pub const fn is_deleted(&self) -> bool {
        self.deleted_at.is_some()
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
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
    /// The pull request head commit recorded at discovery, so later admission
    /// can bind execution to the exact revision the ticket was discovered at.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pr_head_revision: Option<String>,
    /// The pull request author recorded at discovery (e.g. `renovate[bot]`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pr_author: Option<String>,
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
    fn inbox_is_the_canonical_status_wire_value() {
        assert_eq!(
            serde_json::to_string(&TaskBoardStatus::Inbox).expect("serialize inbox"),
            "\"inbox\""
        );
        assert_eq!(
            serde_json::from_str::<TaskBoardStatus>("\"inbox\"").expect("deserialize inbox"),
            TaskBoardStatus::Inbox
        );
    }

    #[test]
    fn public_status_wire_rejects_legacy_lane_names() {
        assert!(
            serde_json::from_str::<TaskBoardStatus>("\"umbrella\"").is_err(),
            "legacy umbrella is accepted only at persisted-data migration boundaries"
        );
        assert!(
            serde_json::from_str::<TaskBoardStatus>("\"backlog\"").is_err(),
            "legacy backlog is accepted only at persisted-data migration boundaries"
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
