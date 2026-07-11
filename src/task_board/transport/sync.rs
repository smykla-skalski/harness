use crate::app::command_context::{AppContext, Execute};
use crate::errors::CliError;
use crate::task_board::external::{
    ExternalSyncConfig, ExternalSyncOptions, configured_sync_clients, sync_external_tasks,
};
use crate::task_board::summary::{TaskBoardSyncSummary, build_sync_summary};

use super::{TaskBoardSyncArgs, print_json, run_blocking, store};

impl Execute for TaskBoardSyncArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let board = store(self.board_root.clone());
        let config = ExternalSyncConfig::from_env();
        let clients = configured_sync_clients(&config, self.provider)?;
        let options = ExternalSyncOptions {
            provider: self.provider,
            direction: self.direction,
            conflict_policy: self.conflict_policy,
            dry_run: !self.apply,
            ..ExternalSyncOptions::default()
        };
        let operations = run_blocking(sync_external_tasks(&board, options, &clients))?;
        let items = board.list(None)?;
        let mut payload = build_sync_summary(&items, &config);
        payload.operations = operations;
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
