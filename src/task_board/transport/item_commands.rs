use std::collections::HashSet;

use harness_daemon_client::DaemonClient;

use crate::app::command_context::{AppContext, Execute};
use crate::infra::io;
use crate::task_board::TASK_BOARD_LIST_MAX_LIMIT;
use crate::task_board::TaskBoardWorkflowKind;
use crate::task_board::types::{ExternalRef, TaskBoardItem};
use crate::task_board::wire::{
    TaskBoardAuditResponse, TaskBoardCreateItemRequest, TaskBoardListItemsRequest,
    TaskBoardListItemsResponse, TaskBoardUpdateEstimateClears, TaskBoardUpdateIdentityClears,
    TaskBoardUpdateItemRequest, TaskBoardUpdateStateClears,
};
use harness_kernel::errors::{CliError, CliErrorKind};

use super::{
    TaskBoardAuditArgs, TaskBoardCreateArgs, TaskBoardDeleteArgs, TaskBoardGetArgs,
    TaskBoardListArgs, TaskBoardUpdateArgs, leaf_daemon_client, leaf_daemon_client_error,
    print_json,
};

/// Stop the page walk after this many pages. Ported from the now-deleted
/// `daemon::client::task_board_list` (the root facade's module, not the leaf
/// client's) along with the query-string rendering and page-walk faults below
/// -- this is their only copy now, not a duplicate of it. A daemon that keeps
/// offering one more distinct cursor would otherwise grow the walk without
/// bound.
// `pub`, not private: `tests/integration_daemon.rs`'s
// `task_board_item_commands_daemon_routing` scenarios script exactly this
// many mock pages to prove the page-cap fault fires.
pub const TASK_BOARD_LIST_MAX_PAGES: usize = 200;

impl Execute for TaskBoardCreateArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let request = TaskBoardCreateItemRequest {
            title: self.title.clone(),
            body: self.body.clone(),
            status: self.status,
            priority: self.priority,
            agent_mode: self.agent_mode,
            kind: self.kind.clone(),
            workflow_kind: TaskBoardWorkflowKind::default(),
            execution_repository: None,
            estimated_tokens: self.fields.estimated_tokens,
            estimated_cost_microusd: self.fields.estimated_cost_microusd,
            tags: self.tag.clone(),
            project_id: self.project_id.clone(),
            target_project_types: self.target_project_type.clone(),
            external_refs: self.fields.external_refs(),
            planning: self.fields.planning().unwrap_or_default(),
            workflow: self.fields.workflow(None),
            session_id: self.fields.session_id.clone(),
            work_item_id: self.fields.work_item_id.clone(),
            id: self.id.clone(),
        };
        let item: TaskBoardItem = leaf_daemon_client()?
            .post("/v1/task-board/items", &request)
            .map_err(|error| leaf_daemon_client_error("create task-board item", &error))?;
        print_json(&item)?;
        Ok(0)
    }
}

impl Execute for TaskBoardListArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let client = leaf_daemon_client()?;
        let request = self.request();
        // Naming a page asks for exactly that page, so the response carries the
        // cursor needed to ask for the next one. Every other read walks the
        // pages here and prints the whole selection.
        if self.limit.is_some() || self.cursor.is_some() {
            let page = list_task_board_items_page(&client, &request)?;
            if self.json {
                print_json(&page)?;
            } else {
                print_item_lines(&page.items);
                if let Some(cursor) = &page.next_cursor {
                    // The hint has to carry the page size back, or following
                    // it silently reads the default page instead of the one
                    // the caller asked for.
                    let limit = self
                        .limit
                        .map(|limit| format!("--limit {limit} "))
                        .unwrap_or_default();
                    println!(
                        "-- {} of {} shown; next page: {limit}--cursor {cursor}",
                        page.items.len(),
                        page.total_matched
                    );
                }
            }
            return Ok(0);
        }
        let items = list_task_board_items(&client, &request)?;
        if self.json {
            print_json(&items)?;
        } else {
            print_item_lines(&items);
        }
        Ok(0)
    }
}

impl TaskBoardListArgs {
    fn request(&self) -> TaskBoardListItemsRequest {
        TaskBoardListItemsRequest {
            status: self.status,
            priority: self.priority,
            agent_mode: self.agent_mode,
            project_id: self.project_id.clone(),
            tags: self.tag.clone(),
            query: self.query.clone(),
            limit: self.limit,
            cursor: self.cursor.clone(),
        }
    }
}

fn print_item_lines(items: &[TaskBoardItem]) {
    for item in items {
        println!(
            "[{:?}] {} - {} ({:?})",
            item.priority, item.id, item.title, item.status
        );
    }
}

impl Execute for TaskBoardGetArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let item = get_task_board_item(&leaf_daemon_client()?, &self.id)?;
        if self.json {
            print_json(&item)?;
        } else {
            println!("{} - {}\n\n{}", item.id, item.title, item.body);
        }
        Ok(0)
    }
}

impl Execute for TaskBoardUpdateArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        io::validate_safe_segment(&self.id)?;
        let client = leaf_daemon_client()?;
        let current = self
            .fields
            .has_workflow_update()
            .then(|| get_task_board_item(&client, &self.id))
            .transpose()?;
        let request = self.request(current.as_ref());
        let item: TaskBoardItem = client
            .put(&item_path(&self.id), &request)
            .map_err(|error| leaf_daemon_client_error("update task-board item", &error))?;
        print_json(&item)?;
        Ok(0)
    }
}

impl TaskBoardUpdateArgs {
    fn request(&self, current: Option<&TaskBoardItem>) -> TaskBoardUpdateItemRequest {
        TaskBoardUpdateItemRequest {
            title: self.title.clone(),
            body: self.body.clone(),
            status: self.status,
            priority: self.priority,
            agent_mode: self.agent_mode,
            kind: self.kind.clone(),
            workflow_kind: None,
            execution_repository: None,
            estimated_tokens: self.fields.estimated_tokens,
            estimated_cost_microusd: self.fields.estimated_cost_microusd,
            clear_estimates: TaskBoardUpdateEstimateClears {
                clear_estimated_tokens: self.clear_estimates.clear_estimated_tokens,
                clear_estimated_cost_microusd: self.clear_estimates.clear_estimated_cost_microusd,
            },
            tags: (!self.tag.is_empty()).then(|| self.tag.clone()),
            project_id: self.project_id.clone(),
            target_project_types: (!self.target_project_type.is_empty())
                .then(|| self.target_project_type.clone()),
            clear_identity: TaskBoardUpdateIdentityClears {
                clear_project_id: self.clear_links.clear_project,
                clear_execution_repository: false,
                clear_session_id: self.clear_links.clear_session,
                clear_work_item_id: self.clear_links.clear_work_item,
                clear_parent_item_id: self.clear_links.clear_parent,
            },
            external_refs: self.external_refs_patch(),
            planning: self.fields.planning(),
            clear_state: TaskBoardUpdateStateClears {
                clear_planning: self.clear_state.clear_planning,
                clear_workflow: self.clear_state.clear_workflow,
            },
            workflow: self.fields.workflow(current.map(|item| &item.workflow)),
            session_id: self.fields.session_id.clone(),
            work_item_id: self.fields.work_item_id.clone(),
            parent_item_id: self.parent_id.clone(),
        }
    }

    fn external_refs_patch(&self) -> Option<Vec<ExternalRef>> {
        if self.clear_state.clear_external_refs {
            Some(Vec::new())
        } else {
            self.fields
                .has_external_refs()
                .then(|| self.fields.external_refs())
        }
    }
}

impl Execute for TaskBoardDeleteArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        io::validate_safe_segment(&self.id)?;
        let item: TaskBoardItem = leaf_daemon_client()?
            .delete(&item_path(&self.id))
            .map_err(|error| leaf_daemon_client_error("delete task-board item", &error))?;
        print_json(&item)?;
        Ok(0)
    }
}

impl Execute for TaskBoardAuditArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let summary: TaskBoardAuditResponse = leaf_daemon_client()?
            .get("/v1/task-board/audit", &[])
            .map_err(|error| leaf_daemon_client_error("audit task board", &error))?;
        if self.json {
            print_json(&summary)?;
        } else {
            println!(
                "task-board: {} total, {} ready, {} blocked",
                summary.total, summary.ready, summary.blocked
            );
        }
        Ok(0)
    }
}

fn get_task_board_item(client: &DaemonClient, item_id: &str) -> Result<TaskBoardItem, CliError> {
    io::validate_safe_segment(item_id)?;
    client
        .get(&item_path(item_id), &[])
        .map_err(|error| leaf_daemon_client_error("get task-board item", &error))
}

/// Read one bounded page of matching task-board items.
///
/// # Errors
/// Returns [`CliError`] when the request fails.
// `pub`, not private: `tests/integration_daemon.rs`'s
// `task_board_item_commands_daemon_routing` scenarios call this directly
// against a fake daemon to prove the query-string rendering, the same reason
// `daemon::db::AsyncDaemonDb`'s methods are `pub` there.
pub fn list_task_board_items_page(
    client: &DaemonClient,
    request: &TaskBoardListItemsRequest,
) -> Result<TaskBoardListItemsResponse, CliError> {
    let owned = task_board_list_query(request)?;
    let query = owned
        .iter()
        .map(|(name, value)| (*name, value.as_str()))
        .collect::<Vec<_>>();
    client
        .get("/v1/task-board/items", &query)
        .map_err(|error| leaf_daemon_client_error("list task-board items", &error))
}

/// Read every matching task-board item by walking the daemon's pages.
///
/// The daemon bounds each response, so a caller that wants the whole
/// selection has to ask for the rest; this keeps that loop in one place
/// rather than in every command that reads the board.
///
/// A walk that cannot advance fails instead of returning what it has. The
/// daemon only ever pairs a cursor with a non-empty page, and never repeats
/// the resume point it was handed, so either shape means the daemon is not
/// the one this client is built against - and a `Vec` has nowhere to say the
/// board was read only in part.
///
/// Sequence-bound cursors prevent overlap in valid responses. Ids are still
/// tracked so a malformed overlapping page cannot put duplicate rows in the
/// returned board.
///
/// # Errors
/// Returns [`CliError`] when a page cannot be read or the walk cannot advance.
pub fn list_task_board_items(
    client: &DaemonClient,
    request: &TaskBoardListItemsRequest,
) -> Result<Vec<TaskBoardItem>, CliError> {
    let mut request = request.clone();
    request.limit.get_or_insert(TASK_BOARD_LIST_MAX_LIMIT);
    let mut items = Vec::new();
    let mut seen = HashSet::new();
    let mut items_change_seq = None;
    for _ in 0..TASK_BOARD_LIST_MAX_PAGES {
        let page = list_task_board_items_page(client, &request)?;
        if let Some(expected) = items_change_seq
            && page.items_change_seq != expected
        {
            return Err(changed_task_board_read(expected, page.items_change_seq));
        }
        items_change_seq.get_or_insert(page.items_change_seq);
        let drained = page.items.is_empty();
        items.extend(
            page.items
                .into_iter()
                .filter(|item| seen.insert(item.id.clone())),
        );
        let Some(cursor) = page.next_cursor else {
            return Ok(items);
        };
        if drained {
            return Err(unusable_task_board_page(
                &cursor,
                "handed back a cursor with no items",
            ));
        }
        if request.cursor.as_deref() == Some(cursor.as_str()) {
            return Err(unusable_task_board_page(
                &cursor,
                "repeated the cursor it was given",
            ));
        }
        request.cursor = Some(cursor);
    }
    Err(undrained_task_board_read())
}

/// Render a list request as the daemon's query string, in a stable order.
fn task_board_list_query(
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

fn append_text_query(request: &TaskBoardListItemsRequest, query: &mut Vec<(&'static str, String)>) {
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

fn append_page_query(request: &TaskBoardListItemsRequest, query: &mut Vec<(&'static str, String)>) {
    if let Some(limit) = request.limit {
        query.push(("limit", limit.to_string()));
    }
    if let Some(cursor) = &request.cursor {
        query.push(("cursor", cursor.clone()));
    }
}

fn enum_label<T: serde::Serialize>(value: T, label: &str) -> Result<String, CliError> {
    serde_json::to_value(value)
        .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?
        .as_str()
        .map(ToOwned::to_owned)
        .ok_or_else(|| {
            CliErrorKind::workflow_serialize(format!("task-board {label} is not a string")).into()
        })
}

fn unusable_task_board_page(cursor: &str, fault: &str) -> CliError {
    CliErrorKind::workflow_io(format!(
        "the daemon {fault} at task-board page cursor '{cursor}'; \
         the board read cannot advance and would otherwise be silently partial"
    ))
    .into()
}

fn changed_task_board_read(expected: i64, actual: i64) -> CliError {
    CliErrorKind::workflow_io(format!(
        "the task-board changed from sequence {expected} to {actual} during the page walk; \
         restart from the first page"
    ))
    .into()
}

fn undrained_task_board_read() -> CliError {
    CliErrorKind::workflow_io(format!(
        "the task-board read did not drain within {TASK_BOARD_LIST_MAX_PAGES} pages; \
         narrow it with a filter, or read one page at a time with --limit and --cursor"
    ))
    .into()
}

fn item_path(item_id: &str) -> String {
    format!("/v1/task-board/items/{item_id}")
}
