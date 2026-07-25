//! Query-string rendering and page-walk faults for task-board list reads.

use crate::daemon::protocol::TaskBoardListItemsRequest;
use harness_kernel::errors::{CliError, CliErrorKind};

/// Render a list request as the daemon's query string, in a stable order.
pub(super) fn task_board_list_query(
    request: &TaskBoardListItemsRequest,
) -> Result<Vec<(&'static str, String)>, CliError> {
    let mut query = enum_facet_query(request)?;
    append_text_query(request, &mut query);
    append_page_query(request, &mut query);
    Ok(query)
}

fn enum_facet_query(
    request: &TaskBoardListItemsRequest,
) -> Result<Vec<(&'static str, String)>, CliError> {
    let mut query = Vec::new();
    if let Some(status) = request.status {
        query.push(("status", enum_label(status, "status")?));
    }
    if let Some(priority) = request.priority {
        query.push(("priority", enum_label(priority, "priority")?));
    }
    if let Some(agent_mode) = request.agent_mode {
        query.push(("agent_mode", enum_label(agent_mode, "agent mode")?));
    }
    Ok(query)
}

fn append_text_query(
    request: &TaskBoardListItemsRequest,
    query: &mut Vec<(&'static str, String)>,
) {
    if let Some(project_id) = &request.project_id {
        query.push(("project_id", project_id.clone()));
    }
    for tag in &request.tags {
        query.push(("tag", tag.clone()));
    }
    if let Some(text) = &request.query {
        query.push(("query", text.clone()));
    }
}

fn append_page_query(
    request: &TaskBoardListItemsRequest,
    query: &mut Vec<(&'static str, String)>,
) {
    if let Some(limit) = request.limit {
        query.push(("limit", limit.to_string()));
    }
    if let Some(cursor) = &request.cursor {
        query.push(("cursor", cursor.clone()));
    }
}

pub(super) fn enum_label<T: serde::Serialize>(value: T, label: &str) -> Result<String, CliError> {
    serde_json::to_value(value)
        .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?
        .as_str()
        .map(ToOwned::to_owned)
        .ok_or_else(|| {
            CliErrorKind::workflow_serialize(format!("task-board {label} is not a string")).into()
        })
}

pub(super) fn unusable_task_board_page(cursor: &str, fault: &str) -> CliError {
    CliErrorKind::workflow_io(format!(
        "the daemon {fault} at task-board page cursor '{cursor}'; \
         the board read cannot advance and would otherwise be silently partial"
    ))
    .into()
}

/// Stop the page walk after this many pages.
///
/// Refusing a repeated cursor only catches a resume point that stalls on the
/// very next page. A daemon that keeps offering one more distinct cursor still
/// grows the walk without bound, so the walk needs a ceiling of its own.
pub(super) const TASK_BOARD_LIST_MAX_PAGES: usize = 200;

pub(super) fn undrained_task_board_read() -> CliError {
    CliErrorKind::workflow_io(format!(
        "the task-board read did not drain within {TASK_BOARD_LIST_MAX_PAGES} pages; \
         narrow it with a filter, or read one page at a time with --limit and --cursor"
    ))
    .into()
}
