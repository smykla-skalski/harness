use std::env;

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::protocol::TaskBoardDispatchRequest;
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::dispatch::{DispatchExecutionSummary, DispatchReadiness};

use super::{TaskBoardDispatchArgs, daemon_client, print_json};

impl Execute for TaskBoardDispatchArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let request = TaskBoardDispatchRequest {
            item_id: self.item_id.clone(),
            status: self.status,
            dry_run: self.dry_run,
            project_dir: Some(self.dispatch_project_dir()?),
            actor: self.actor.clone(),
        };
        let summary = daemon_client()?.dispatch_task_board(&request)?;
        if self.json {
            print_json(&summary)?;
        } else {
            print_dispatch_summary(&summary);
        }
        Ok(0)
    }
}

impl TaskBoardDispatchArgs {
    fn dispatch_project_dir(&self) -> Result<String, CliError> {
        self.project_dir.clone().map_or_else(
            || {
                env::current_dir()
                    .map(|path| path.to_string_lossy().into_owned())
                    .map_err(|error| CliErrorKind::workflow_io(error.to_string()).into())
            },
            Ok,
        )
    }
}

fn print_dispatch_summary(summary: &DispatchExecutionSummary) {
    for plan in &summary.plans {
        println!(
            "[{}] {}",
            dispatch_readiness_label(&plan.readiness),
            plan.board_item_id
        );
    }
    if !summary.applied.is_empty() {
        println!("applied {} task-board dispatches", summary.applied.len());
    }
}

fn dispatch_readiness_label(readiness: &DispatchReadiness) -> &'static str {
    match readiness {
        DispatchReadiness::Ready => "ready",
        DispatchReadiness::Blocked { .. } => "blocked",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::task_board::types::TaskBoardStatus;

    #[test]
    fn dispatch_request_uses_explicit_project_dir() {
        let args = TaskBoardDispatchArgs {
            json: true,
            dry_run: true,
            item_id: Some("task-1".into()),
            status: Some(TaskBoardStatus::Todo),
            project_dir: Some("/tmp/project".into()),
            actor: Some("operator".into()),
        };

        assert_eq!(
            args.dispatch_project_dir().expect("project dir"),
            "/tmp/project"
        );
    }
}
