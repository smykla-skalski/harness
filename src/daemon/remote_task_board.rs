use serde::Serialize;

use crate::daemon::protocol::{TaskBoardItemPositionSnapshot, TaskBoardListItemsResponse};
use crate::task_board::{AgentMode, TaskBoardItem, TaskBoardPriority, TaskBoardStatus};

use super::remote_redaction::redact_known_secrets;

const BODY_PREVIEW_CHAR_LIMIT: usize = 180;
const BODY_PREVIEW_PREFIX_LIMIT: usize = BODY_PREVIEW_CHAR_LIMIT - 3;

#[derive(Serialize)]
#[serde(untagged)]
pub(crate) enum TaskBoardReadItemResponse {
    Full(Box<TaskBoardItem>),
    Viewer(Box<RemoteViewerTaskBoardItem>),
}

#[derive(Serialize)]
#[serde(untagged)]
pub(crate) enum TaskBoardReadListResponse {
    Full(TaskBoardListItemsResponse),
    Viewer(RemoteViewerTaskBoardListResponse),
}

#[derive(Serialize)]
#[serde(untagged)]
pub(crate) enum TaskBoardPositionSnapshotResponse {
    Full(TaskBoardItemPositionSnapshot),
    Viewer(RemoteViewerTaskBoardPositionSnapshot),
}

#[derive(Serialize)]
pub(crate) struct RemoteViewerTaskBoardListResponse {
    items: Vec<RemoteViewerTaskBoardItem>,
    items_change_seq: i64,
    item_revisions: std::collections::HashMap<String, i64>,
}

#[derive(Serialize)]
pub(crate) struct RemoteViewerTaskBoardItem {
    schema_version: u32,
    id: String,
    title: String,
    body: String,
    status: TaskBoardStatus,
    priority: TaskBoardPriority,
    #[serde(skip_serializing_if = "Option::is_none")]
    lane_position: Option<u32>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    tags: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    project_id: Option<String>,
    agent_mode: AgentMode,
    #[serde(skip_serializing_if = "Option::is_none")]
    session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    work_item_id: Option<String>,
    created_at: String,
    updated_at: String,
}

#[derive(Serialize)]
pub(crate) struct RemoteViewerTaskBoardPositionSnapshot {
    item: RemoteViewerTaskBoardItem,
    item_revision: i64,
    items_change_seq: i64,
}

#[must_use]
pub(crate) fn project_task_board_list(
    response: TaskBoardListItemsResponse,
    viewer: bool,
) -> TaskBoardReadListResponse {
    if viewer {
        let TaskBoardListItemsResponse {
            items,
            items_change_seq,
            item_revisions,
            ..
        } = response;
        TaskBoardReadListResponse::Viewer(RemoteViewerTaskBoardListResponse {
            items: items
                .into_iter()
                .map(RemoteViewerTaskBoardItem::from)
                .collect(),
            items_change_seq,
            item_revisions,
        })
    } else {
        TaskBoardReadListResponse::Full(response)
    }
}

#[must_use]
pub(crate) fn project_task_board_item(
    item: TaskBoardItem,
    viewer: bool,
) -> TaskBoardReadItemResponse {
    if viewer {
        TaskBoardReadItemResponse::Viewer(Box::new(item.into()))
    } else {
        TaskBoardReadItemResponse::Full(Box::new(item))
    }
}

#[must_use]
pub(crate) fn project_task_board_position_snapshot(
    snapshot: TaskBoardItemPositionSnapshot,
    viewer: bool,
) -> TaskBoardPositionSnapshotResponse {
    if viewer {
        TaskBoardPositionSnapshotResponse::Viewer(RemoteViewerTaskBoardPositionSnapshot {
            item: snapshot.item.into(),
            item_revision: snapshot.item_revision,
            items_change_seq: snapshot.items_change_seq,
        })
    } else {
        TaskBoardPositionSnapshotResponse::Full(snapshot)
    }
}

impl From<TaskBoardItem> for RemoteViewerTaskBoardItem {
    fn from(item: TaskBoardItem) -> Self {
        Self {
            schema_version: item.schema_version,
            id: item.id,
            title: redact_known_secrets(&item.title),
            body: body_preview(&item.body),
            status: item.status,
            priority: item.priority,
            lane_position: item.lane_position,
            tags: item
                .tags
                .into_iter()
                .map(|tag| redact_known_secrets(&tag))
                .collect(),
            project_id: item
                .project_id
                .map(|project_id| redact_known_secrets(&project_id)),
            agent_mode: item.agent_mode,
            session_id: item.session_id,
            work_item_id: item.work_item_id,
            created_at: item.created_at,
            updated_at: item.updated_at,
        }
    }
}

fn body_preview(body: &str) -> String {
    let redacted = redact_known_secrets(body.trim());
    let mut chars = redacted.chars();
    let prefix = chars
        .by_ref()
        .take(BODY_PREVIEW_CHAR_LIMIT)
        .collect::<String>();
    if chars.next().is_none() {
        return prefix;
    }
    let mut preview = prefix
        .chars()
        .take(BODY_PREVIEW_PREFIX_LIMIT)
        .collect::<String>();
    preview.push_str("...");
    preview
}

#[cfg(test)]
mod tests {
    use super::body_preview;

    #[test]
    fn viewer_body_preview_redacts_then_truncates_by_character() {
        let body = format!("Bearer abcdefghijklmnop {}", "\u{017c}".repeat(200));
        let preview = body_preview(&body);

        assert_eq!(preview.chars().count(), 180);
        assert!(preview.starts_with("Bearer [redacted]"));
        assert!(preview.ends_with("..."));
        assert!(!preview.contains("abcdefghijklmnop"));
    }

    #[test]
    fn viewer_body_preview_keeps_180_characters_and_truncates_181() {
        let exact = "x".repeat(180);
        assert_eq!(body_preview(&exact), exact);
        assert_eq!(
            body_preview(&"x".repeat(181)),
            format!("{}...", "x".repeat(177))
        );
    }
}
