use serde::Serialize;

use crate::daemon::protocol::TaskBoardListItemsResponse;
use crate::daemon::remote::RemoteRole;
use crate::daemon::remote_identity::RemoteStoredClient;
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
pub(crate) struct RemoteViewerTaskBoardListResponse {
    items: Vec<RemoteViewerTaskBoardItem>,
}

#[derive(Serialize)]
pub(crate) struct RemoteViewerTaskBoardItem {
    schema_version: u32,
    id: String,
    title: String,
    body: String,
    status: TaskBoardStatus,
    priority: TaskBoardPriority,
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

#[must_use]
pub(crate) fn is_remote_viewer(client: Option<&RemoteStoredClient>) -> bool {
    client.is_some_and(|client| client.role == RemoteRole::Viewer)
}

#[must_use]
pub(crate) fn project_task_board_list(
    response: TaskBoardListItemsResponse,
    viewer: bool,
) -> TaskBoardReadListResponse {
    if viewer {
        TaskBoardReadListResponse::Viewer(RemoteViewerTaskBoardListResponse {
            items: response
                .items
                .into_iter()
                .map(RemoteViewerTaskBoardItem::from)
                .collect(),
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

impl From<TaskBoardItem> for RemoteViewerTaskBoardItem {
    fn from(item: TaskBoardItem) -> Self {
        Self {
            schema_version: item.schema_version,
            id: item.id,
            title: redact_known_secrets(&item.title),
            body: body_preview(&item.body),
            status: item.status,
            priority: item.priority,
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
    if redacted.chars().count() <= BODY_PREVIEW_CHAR_LIMIT {
        return redacted;
    }
    format!(
        "{}...",
        redacted
            .chars()
            .take(BODY_PREVIEW_PREFIX_LIMIT)
            .collect::<String>()
    )
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
}
