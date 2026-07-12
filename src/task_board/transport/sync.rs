use crate::app::command_context::{AppContext, Execute};
use crate::daemon::protocol::TaskBoardSyncRequest;
use crate::errors::CliError;
use crate::task_board::summary::TaskBoardSyncSummary;

use super::{TaskBoardSyncArgs, daemon_client, print_json};

impl Execute for TaskBoardSyncArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let request = TaskBoardSyncRequest {
            status: None,
            provider: self.provider,
            direction: self.direction,
            conflict_policy: self.conflict_policy,
            dry_run: !self.apply,
        };
        let payload = daemon_client()?.sync_task_board(&request)?;
        if self.json {
            print_json(&payload)?;
        } else {
            print_sync_summary(&payload);
        }
        Ok(0)
    }
}

fn print_sync_summary(payload: &TaskBoardSyncSummary) {
    let mode = if payload.operations.iter().any(|operation| operation.applied) {
        "applied"
    } else {
        "dry-run"
    };
    println!("task-board sync ({mode}): {} local items", payload.total);
    for provider in &payload.providers {
        println!(
            "{:?}: configured={}, linked={}, pushable={}, blocked={}",
            provider.provider,
            provider.configured,
            provider.linked,
            provider.pushable,
            provider.blocked
        );
    }
    if !payload.operations.is_empty() {
        println!("{} sync operations", payload.operations.len());
    }
}
