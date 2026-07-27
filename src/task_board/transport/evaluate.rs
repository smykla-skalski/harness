use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::task_board::wire::{TaskBoardEvaluateRequest, TaskBoardEvaluationResponse};
use harness_kernel::errors::CliError;
use crate::task_board::transport::{leaf_daemon_client, leaf_daemon_client_error, print_json};
use crate::task_board::types::TaskBoardStatus;

#[derive(Debug, Clone, Args)]
pub struct TaskBoardEvaluateArgs {
    #[arg(long)]
    pub json: bool,
    #[arg(long)]
    pub dry_run: bool,
    #[arg(long = "item-id", visible_alias = "id")]
    pub item_id: Option<String>,
    #[arg(long, value_enum)]
    pub status: Option<TaskBoardStatus>,
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for TaskBoardEvaluateArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let request = TaskBoardEvaluateRequest {
            item_id: self.item_id.clone(),
            status: self.status,
            dry_run: self.dry_run,
        };
        let summary: TaskBoardEvaluationResponse = leaf_daemon_client()?
            .post("/v1/task-board/evaluate", &request)
            .map_err(|error| leaf_daemon_client_error("evaluate task board", &error))?;
        if self.json {
            print_json(&summary)?;
        } else {
            println!(
                "task-board evaluate: {} evaluated, {} updated, {} skipped",
                summary.evaluated, summary.updated, summary.skipped
            );
            for record in &summary.records {
                println!("[{:?}] {}", record.outcome, record.board_item_id);
            }
        }
        Ok(0)
    }
}
