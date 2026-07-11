use crate::app::command_context::AppContext;
use crate::daemon::protocol::TaskBoardCatalogRequest;
use crate::errors::CliError;

use super::{TaskBoardCatalogArgs, daemon_client, print_json};

impl TaskBoardCatalogArgs {
    pub(super) fn execute_project(&self, _context: &AppContext) -> Result<i32, CliError> {
        let summaries = daemon_client()?.task_board_projects(&TaskBoardCatalogRequest {
            status: self.status,
        })?;
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
        let summaries = daemon_client()?.task_board_machines(&TaskBoardCatalogRequest {
            status: self.status,
        })?;
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
