use serde::{Deserialize, Serialize};

use crate::task_board::{
    AgentMode, ExternalRef, PlanningState, TASK_BOARD_LIST_MAX_QUERY_CHARS,
    TASK_BOARD_LIST_MAX_TAGS, TaskBoardItemQuery, TaskBoardListCursor, TaskBoardPriority,
    TaskBoardStatus, TaskBoardWorkflowKind, normalize_query_text,
    types::{TaskBoardItemKind, TaskBoardWorkflowState},
    validated_limit,
};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct TaskBoardCreateItemRequest {
    pub title: String,
    #[serde(default)]
    pub body: String,
    /// Starting lane. Omitted leaves the placement to the default status and
    /// automatic triage; naming one makes the caller own it, and automatic
    /// triage records its decision without moving the item back out.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<TaskBoardStatus>,
    #[serde(default)]
    pub priority: TaskBoardPriority,
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
    pub tags: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub target_project_types: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub external_refs: Vec<ExternalRef>,
    #[serde(default)]
    pub planning: PlanningState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow: Option<TaskBoardWorkflowState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub work_item_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
}

pub const TASK_BOARD_LIST_INVALID_PARAMS: &str = "invalid task-board list params";

/// Selection for one task-board list read: facets, free text, and one page.
///
/// Every facet names a field the remote-viewer projection keeps, so the same
/// request means the same thing whoever sends it.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TaskBoardListItemsRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<TaskBoardStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub priority: Option<TaskBoardPriority>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_mode: Option<AgentMode>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    /// An item must carry every one of these tags to match.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tags: Vec<String>,
    /// Substring matched case-insensitively against title, body, and tags.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub query: Option<String>,
    /// Page size. Absent takes [`TASK_BOARD_LIST_DEFAULT_LIMIT`]; anything
    /// outside `1..=TASK_BOARD_LIST_MAX_LIMIT` is refused rather than clamped,
    /// so a caller never silently reads a different page than it asked for.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
    /// Opaque `next_cursor` from the previous page.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
}

/// A list request checked against its bounds and reduced to what a read needs.
pub struct TaskBoardListItemsSelection {
    pub query: TaskBoardItemQuery,
    pub limit: u32,
    pub cursor: Option<TaskBoardListCursor>,
}

impl TaskBoardListItemsRequest {
    /// Validate the request's bounds and resolve it into one selection.
    ///
    /// `None` means the caller sent a page size, cursor, or filter the daemon
    /// refuses; the transport turns that into an invalid-params error.
    #[must_use]
    pub fn validated_selection(&self) -> Option<TaskBoardListItemsSelection> {
        if self.tags.len() > TASK_BOARD_LIST_MAX_TAGS
            || self.tags.iter().any(|tag| tag.trim().is_empty())
        {
            return None;
        }
        let text = normalize_query_text(self.query.as_deref());
        if text
            .as_deref()
            .is_some_and(|text| text.chars().count() > TASK_BOARD_LIST_MAX_QUERY_CHARS)
        {
            return None;
        }
        let cursor = match self.cursor.as_deref() {
            Some(cursor) => Some(TaskBoardListCursor::decode(cursor)?),
            None => None,
        };
        Some(TaskBoardListItemsSelection {
            query: TaskBoardItemQuery {
                status: self.status,
                priority: self.priority,
                agent_mode: self.agent_mode,
                project_id: self.project_id.clone(),
                tags: self.tags.clone(),
                text,
            },
            limit: validated_limit(self.limit)?,
            cursor,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardGetItemRequest {
    pub id: String,
}

/// Request an explicit manual position in a canonical task-board lane.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct TaskBoardSetItemPositionRequest {
    pub status: TaskBoardStatus,
    pub lane_position: u32,
    pub expected_item_revision: i64,
    pub expected_items_change_seq: i64,
    /// Bound to the authenticated control-plane principal at the transport edge.
    #[serde(default)]
    pub actor: String,
}

/// Reset an item from an explicit position to its derived default placement.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct TaskBoardResetItemPositionRequest {
    pub expected_item_revision: i64,
    pub expected_items_change_seq: i64,
    /// Bound to the authenticated control-plane principal at the transport edge.
    #[serde(default)]
    pub actor: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct TaskBoardUpdateItemRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<TaskBoardStatus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub priority: Option<TaskBoardPriority>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_mode: Option<AgentMode>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow_kind: Option<TaskBoardWorkflowKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<TaskBoardItemKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub execution_repository: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub estimated_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub estimated_cost_microusd: Option<u64>,
    #[serde(default, flatten)]
    pub clear_estimates: TaskBoardUpdateEstimateClears,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tags: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_project_types: Option<Vec<String>>,
    #[serde(default, flatten)]
    pub clear_identity: TaskBoardUpdateIdentityClears,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub external_refs: Option<Vec<ExternalRef>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub planning: Option<PlanningState>,
    #[serde(default, flatten)]
    pub clear_state: TaskBoardUpdateStateClears,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow: Option<TaskBoardWorkflowState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub work_item_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_item_id: Option<String>,
}

#[expect(
    clippy::struct_excessive_bools,
    reason = "wire contract exposes independent identity-clear switches"
)]
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct TaskBoardUpdateIdentityClears {
    #[serde(default)]
    pub clear_project_id: bool,
    #[serde(default)]
    pub clear_execution_repository: bool,
    #[serde(default)]
    pub clear_session_id: bool,
    #[serde(default)]
    pub clear_work_item_id: bool,
    #[serde(default)]
    pub clear_parent_item_id: bool,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct TaskBoardUpdateEstimateClears {
    #[serde(default)]
    pub clear_estimated_tokens: bool,
    #[serde(default)]
    pub clear_estimated_cost_microusd: bool,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
#[derive(utoipa::ToSchema)]
pub struct TaskBoardUpdateStateClears {
    #[serde(default)]
    pub clear_planning: bool,
    #[serde(default)]
    pub clear_workflow: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskBoardDeleteItemRequest {
    pub id: String,
}

#[cfg(test)]
mod tests {
    use super::{TASK_BOARD_LIST_MAX_QUERY_CHARS, TASK_BOARD_LIST_MAX_TAGS,
        TaskBoardListItemsRequest};
    use crate::task_board::{TASK_BOARD_LIST_DEFAULT_LIMIT, TaskBoardListCursor};

    #[test]
    fn an_empty_request_selects_the_whole_board_at_the_default_page_size() {
        let selection = TaskBoardListItemsRequest::default()
            .validated_selection()
            .expect("an empty request is valid");

        assert_eq!(selection.limit, TASK_BOARD_LIST_DEFAULT_LIMIT);
        assert_eq!(selection.cursor, None);
        assert_eq!(selection.query, crate::task_board::TaskBoardItemQuery::default());
    }

    #[test]
    fn blank_query_text_is_dropped_rather_than_matched() {
        let request = TaskBoardListItemsRequest {
            query: Some("   ".to_string()),
            ..TaskBoardListItemsRequest::default()
        };

        let selection = request.validated_selection().expect("blank text is valid");
        assert_eq!(selection.query.text, None);
    }

    #[test]
    fn a_request_outside_its_bounds_is_refused() {
        let refused = [
            TaskBoardListItemsRequest {
                tags: vec!["tag".to_string(); TASK_BOARD_LIST_MAX_TAGS + 1],
                ..TaskBoardListItemsRequest::default()
            },
            TaskBoardListItemsRequest {
                tags: vec![" ".to_string()],
                ..TaskBoardListItemsRequest::default()
            },
            TaskBoardListItemsRequest {
                query: Some("x".repeat(TASK_BOARD_LIST_MAX_QUERY_CHARS + 1)),
                ..TaskBoardListItemsRequest::default()
            },
            TaskBoardListItemsRequest {
                limit: Some(0),
                ..TaskBoardListItemsRequest::default()
            },
            TaskBoardListItemsRequest {
                cursor: Some("not-a-cursor".to_string()),
                ..TaskBoardListItemsRequest::default()
            },
        ];

        for request in refused {
            assert!(
                request.validated_selection().is_none(),
                "accepted {request:?}"
            );
        }
    }

    #[test]
    fn a_cursor_from_a_previous_page_is_decoded_for_the_read() {
        let cursor = TaskBoardListCursor::for_page(3, 9);
        let request = TaskBoardListItemsRequest {
            cursor: Some(cursor.encode()),
            ..TaskBoardListItemsRequest::default()
        };

        let selection = request.validated_selection().expect("a valid cursor");
        assert_eq!(selection.cursor, Some(cursor));
    }
}
