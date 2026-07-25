use async_trait::async_trait;
use serde_json::{Map, Value};

use crate::daemon::protocol::ws_methods;
use crate::mcp::protocol::ToolResult;
use crate::mcp::tool::{Tool, ToolError};

use super::support::{TaskBoardCallOutcome, task_board_call, validate_params};

/// Stop after this many pages. A daemon that kept handing back a cursor
/// without ever draining would otherwise spin the walk below forever.
const MAX_PAGES: usize = 200;

pub(super) const DESCRIPTION: &str = "List task-board items from the running daemon, filtered by \
     field values and by text in the title, body, or tags. Returns the whole matching selection by \
     default. Pass limit or cursor to read exactly one bounded page instead, then pass that \
     response's next_cursor back as cursor for the page after it.";

/// The task-board list tool, which folds the daemon's pages instead of
/// proxying one of them.
///
/// Every other task-board tool is a single round trip, but the list endpoint is
/// bounded, so proxying it directly would answer "the whole board" with at most
/// one page and no sign that anything was left. The CLI and the Monitor app
/// walk for the same reason; this keeps the MCP tool's default read whole.
pub(super) struct TaskBoardListTool {
    input_schema: fn() -> Value,
}

impl TaskBoardListTool {
    pub(super) const fn new(input_schema: fn() -> Value) -> Self {
        Self { input_schema }
    }
}

#[async_trait]
impl Tool for TaskBoardListTool {
    fn name(&self) -> &'static str {
        ws_methods::TASK_BOARD_LIST
    }

    fn description(&self) -> &'static str {
        DESCRIPTION
    }

    fn input_schema(&self) -> Value {
        (self.input_schema)()
    }

    async fn call(&self, params: Value) -> Result<ToolResult, ToolError> {
        let params = validate_params(params, &(self.input_schema)())?;
        // Naming a page asks for exactly that page, so hand it back untouched
        // along with the cursor needed to ask for the next one.
        if params.get("limit").is_some() || params.get("cursor").is_some() {
            return finish(task_board_call(ws_methods::TASK_BOARD_LIST, params).await?);
        }
        walk_every_page(params).await
    }
}

async fn walk_every_page(params: Value) -> Result<ToolResult, ToolError> {
    let mut merged = TaskBoardItemPages::default();
    let mut cursor: Option<String> = None;
    for _ in 0..MAX_PAGES {
        let page = match task_board_call(ws_methods::TASK_BOARD_LIST, page_params(&params, &cursor)?)
            .await?
        {
            TaskBoardCallOutcome::Result(page) => page,
            refused @ TaskBoardCallOutcome::Refused(_) => return finish(refused),
        };
        let Some(next) = merged.absorb(&page)? else {
            return finish(TaskBoardCallOutcome::Result(merged.into_response()));
        };
        // A cursor that names the same resume point can never drain, so stop
        // and say why rather than fetching that page forever.
        if cursor.as_deref() == Some(next.as_str()) {
            return Err(ToolError::internal(format!(
                "the daemon returned the same task-board page cursor '{next}' twice; \
                 the board read cannot advance"
            )));
        }
        cursor = Some(next);
    }
    Err(ToolError::internal(format!(
        "the task-board read did not drain within {MAX_PAGES} pages; narrow it with a filter, \
         or read one page at a time by passing limit and cursor"
    )))
}

/// One page's params: the caller's selection plus where to resume.
fn page_params(params: &Value, cursor: &Option<String>) -> Result<Value, ToolError> {
    let mut object = params
        .as_object()
        .ok_or_else(|| ToolError::invalid("arguments must be an object"))?
        .clone();
    match cursor {
        Some(cursor) => object.insert("cursor".to_string(), Value::String(cursor.clone())),
        None => object.remove("cursor"),
    };
    Ok(Value::Object(object))
}

/// The pages seen so far, folded into one response.
///
/// A cursor whose anchor left the selection between two reads resumes at the
/// slot that anchor held, which can re-serve a row an earlier page already
/// returned, so ids are tracked and a repeat is dropped rather than handed to
/// the caller twice.
#[derive(Default)]
struct TaskBoardItemPages {
    items: Vec<Value>,
    seen: std::collections::HashSet<String>,
    revisions: Map<String, Value>,
    extra: Map<String, Value>,
}

impl TaskBoardItemPages {
    /// Take this page's items and return the cursor it offers, if any.
    ///
    /// A page without an `items` array is a daemon this tool cannot read, not
    /// an empty board: answering it as a drained selection would report a
    /// protocol mismatch as "no items".
    fn absorb(&mut self, page: &Value) -> Result<Option<String>, ToolError> {
        let items = page.get("items").and_then(Value::as_array).ok_or_else(|| {
            ToolError::internal("the daemon returned a task-board page with no items array")
        })?;
        for item in items {
            // Every id the walk folds on comes from here, so an item without
            // one cannot be deduplicated or resumed past: it would ride into
            // the merged response and could arrive twice.
            let id = item.get("id").and_then(Value::as_str).ok_or_else(|| {
                ToolError::internal("the daemon returned a task-board item with no id")
            })?;
            if self.seen.insert(id.to_string()) {
                self.items.push(item.clone());
            }
        }
        // Item revisions are scoped to the page that carried them, so every
        // page adds its own or the merged answer would describe only the
        // first page's rows.
        if let Some(revisions) = page.get("item_revisions").and_then(Value::as_object) {
            for (id, revision) in revisions {
                self.revisions.insert(id.clone(), revision.clone());
            }
        }
        // Every page reports the same board-wide roll-ups and totals, so the
        // first one that carries them wins and later pages add nothing.
        if self.extra.is_empty()
            && let Some(object) = page.as_object()
        {
            self.extra = object
                .iter()
                .filter(|(key, _)| {
                    !matches!(key.as_str(), "items" | "next_cursor" | "item_revisions")
                })
                .map(|(key, value)| (key.clone(), value.clone()))
                .collect();
        }
        let next = page
            .get("next_cursor")
            .and_then(Value::as_str)
            .map(ToString::to_string);
        // An empty page beside a cursor cannot be walked any further, and the
        // merged response has nowhere to record that the read stopped early,
        // so it would answer as a whole board. A drained board is the one
        // legitimate empty page, and it carries no cursor.
        match (items.is_empty(), next) {
            (true, Some(cursor)) => Err(ToolError::internal(format!(
                "the daemon returned no task-board items beside cursor '{cursor}'; \
                 the board read cannot advance"
            ))),
            (true, None) => Ok(None),
            (false, next) => Ok(next),
        }
    }

    /// A drained walk answers the whole selection, so it carries no cursor.
    fn into_response(self) -> Value {
        let mut object = self.extra;
        object.insert("items".to_string(), Value::Array(self.items));
        if !self.revisions.is_empty() {
            object.insert("item_revisions".to_string(), Value::Object(self.revisions));
        }
        Value::Object(object)
    }
}

fn finish(outcome: TaskBoardCallOutcome) -> Result<ToolResult, ToolError> {
    match outcome {
        TaskBoardCallOutcome::Result(value) => ToolResult::json_text(&value).map_err(|error| {
            ToolError::internal(format!("serialize task-board MCP response: {error}"))
        }),
        TaskBoardCallOutcome::Refused(message) => Ok(ToolResult::error(message)),
    }
}

#[cfg(test)]
#[path = "list_walk_tests.rs"]
mod tests;
