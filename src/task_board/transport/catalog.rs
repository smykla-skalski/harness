use crate::task_board::types::TaskBoardStatus;
use crate::task_board::wire::{TaskBoardMachinesResponse, TaskBoardProjectsResponse};
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_workspace::command_context::AppContext;

use super::{TaskBoardCatalogArgs, leaf_daemon_client, leaf_daemon_client_error, print_json};

impl TaskBoardCatalogArgs {
    pub(super) fn execute_project(&self, _context: &AppContext) -> Result<i32, CliError> {
        let status = status_label(self.status)?;
        let query = status_query(status.as_ref());
        let summaries: TaskBoardProjectsResponse = leaf_daemon_client()?
            .get("/v1/task-board/projects", &query)
            .map_err(|error| leaf_daemon_client_error("list task-board projects", &error))?;
        if self.json {
            print_json(&summaries)?;
        } else {
            for summary in summaries {
                println!(
                    "{}: {} items, {} ready",
                    summary.project_id, summary.item_count, summary.ready_count
                );
            }
        }
        Ok(0)
    }

    pub(super) fn execute_machine(&self, _context: &AppContext) -> Result<i32, CliError> {
        let status = status_label(self.status)?;
        let query = status_query(status.as_ref());
        let summaries: TaskBoardMachinesResponse = leaf_daemon_client()?
            .get("/v1/task-board/machines", &query)
            .map_err(|error| leaf_daemon_client_error("list task-board machines", &error))?;
        if self.json {
            print_json(&summaries)?;
        } else {
            for summary in summaries {
                println!(
                    "{:?}: {} items, {} ready",
                    summary.mode, summary.item_count, summary.ready_count
                );
            }
        }
        Ok(0)
    }
}

fn status_label(status: Option<TaskBoardStatus>) -> Result<Option<String>, CliError> {
    let Some(status) = status else {
        return Ok(None);
    };
    let value = serde_json::to_value(status)
        .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
    value
        .as_str()
        .map(|label| Some(label.to_string()))
        .ok_or_else(|| {
            CliErrorKind::workflow_serialize("expected task-board status to serialize as a string")
                .into()
        })
}

fn status_query(status: Option<&String>) -> Vec<(&str, &str)> {
    match status {
        Some(label) => vec![("status", label.as_str())],
        None => Vec::new(),
    }
}
