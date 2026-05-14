use uuid::Uuid;

use crate::daemon::protocol::{
    TaskBoardCapabilityStatus, TaskBoardCreateItemRequest, TaskBoardDeleteItemRequest,
    TaskBoardGetItemRequest, TaskBoardListItemsRequest, TaskBoardListItemsResponse,
    TaskBoardUpdateItemRequest,
};
use crate::errors::CliError;
use crate::task_board::store::{OptionalFieldPatch, TaskBoardItemPatch};
use crate::task_board::{TaskBoardItem, TaskBoardStore, default_board_root};
use crate::workspace::utc_now;

/// Create a persisted task-board item.
///
/// # Errors
/// Returns `CliError` when the generated or supplied ID is unsafe, already
/// exists, or the markdown item cannot be written.
pub fn create_task_board_item(
    request: &TaskBoardCreateItemRequest,
) -> Result<TaskBoardItem, CliError> {
    let now = utc_now();
    let mut item = TaskBoardItem::new(
        request.id.clone().unwrap_or_else(new_task_id),
        request.title.clone(),
        request.body.clone(),
        now,
    );
    item.priority = request.priority;
    item.agent_mode = request.agent_mode;
    item.tags.clone_from(&request.tags);
    item.project_id.clone_from(&request.project_id);
    item.external_refs.clone_from(&request.external_refs);
    item.planning.clone_from(&request.planning);
    item.session_id.clone_from(&request.session_id);
    item.work_item_id.clone_from(&request.work_item_id);
    store().create(&request.title, &request.body, item)
}

/// List active task-board items.
///
/// # Errors
/// Returns `CliError` when the board directory cannot be read or an item cannot
/// be parsed from markdown.
pub fn list_task_board_items(
    request: &TaskBoardListItemsRequest,
) -> Result<TaskBoardListItemsResponse, CliError> {
    store()
        .list(request.status)
        .map(|items| TaskBoardListItemsResponse { items })
}

/// Load one task-board item.
///
/// # Errors
/// Returns `CliError` when the ID is unsafe, the item is missing, or the
/// markdown/frontmatter payload cannot be parsed.
pub fn get_task_board_item(request: &TaskBoardGetItemRequest) -> Result<TaskBoardItem, CliError> {
    store().get(&request.id)
}

/// Update one task-board item.
///
/// # Errors
/// Returns `CliError` when the item cannot be loaded or the patched item cannot
/// be written.
pub fn update_task_board_item(
    id: &str,
    request: &TaskBoardUpdateItemRequest,
) -> Result<TaskBoardItem, CliError> {
    store().update(id, patch_from_request(request))
}

/// Tombstone one task-board item.
///
/// # Errors
/// Returns `CliError` when the item cannot be loaded or the tombstone cannot be
/// written.
pub fn delete_task_board_item(
    request: &TaskBoardDeleteItemRequest,
) -> Result<TaskBoardItem, CliError> {
    store().delete(&request.id)
}

#[must_use]
pub fn task_board_not_configured(operation: &str) -> TaskBoardCapabilityStatus {
    TaskBoardCapabilityStatus {
        installed: true,
        status: "not_configured".into(),
        message: format!("task-board {operation} is installed but not configured"),
    }
}

fn patch_from_request(request: &TaskBoardUpdateItemRequest) -> TaskBoardItemPatch {
    TaskBoardItemPatch {
        title: request.title.clone(),
        body: request.body.clone(),
        status: request.status,
        priority: request.priority,
        tags: request.tags.clone(),
        project_id: optional_string_patch(request.project_id.as_ref(), request.clear_project_id),
        agent_mode: request.agent_mode,
        external_refs: request.external_refs.clone(),
        planning: request.planning.clone(),
        session_id: optional_string_patch(request.session_id.as_ref(), request.clear_session_id),
        work_item_id: optional_string_patch(
            request.work_item_id.as_ref(),
            request.clear_work_item_id,
        ),
    }
}

fn optional_string_patch(value: Option<&String>, clear: bool) -> OptionalFieldPatch<String> {
    if clear {
        return OptionalFieldPatch::Clear;
    }
    value
        .cloned()
        .map_or(OptionalFieldPatch::Unchanged, OptionalFieldPatch::Set)
}

fn store() -> TaskBoardStore {
    TaskBoardStore::new(default_board_root())
}

fn new_task_id() -> String {
    format!("task-{}", Uuid::new_v4().simple())
}
