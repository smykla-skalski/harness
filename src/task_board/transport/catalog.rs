use crate::app::command_context::AppContext;
use crate::errors::CliError;
use crate::task_board::summary::{build_machine_summaries, build_project_summaries};

use super::{TaskBoardCatalogArgs, print_json, store};

impl TaskBoardCatalogArgs {
    pub(super) fn execute_project(&self, _context: &AppContext) -> Result<i32, CliError> {
        let items = store(self.board_root.clone()).list(self.status)?;
        let summaries = build_project_summaries(&items);
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
        let items = store(self.board_root.clone()).list(self.status)?;
        let summaries = build_machine_summaries(&items);
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
