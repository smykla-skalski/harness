use std::env;

use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::protocol::{
    TaskBoardDispatchDeliverRequest, TaskBoardDispatchDeliverResponse,
    TaskBoardDispatchPickResponse, TaskBoardDispatchRequest,
};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::dispatch::{DispatchExecutionSummary, DispatchReadiness};

use super::{TaskBoardDispatchArgs, daemon_client, print_json};

#[derive(Debug, Clone, Args)]
pub struct TaskBoardDispatchPickArgs {
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardDispatchDeliverArgs {
    #[arg(long = "item-id", visible_alias = "id")]
    pub item_id: String,
    #[arg(long)]
    pub dry_run: bool,
    #[arg(long)]
    pub json: bool,
}

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

impl Execute for TaskBoardDispatchPickArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let response = daemon_client()?.pick_task_board_dispatch()?;
        if self.json {
            print_json(&response)?;
        } else {
            print_dispatch_pick(&response);
        }
        Ok(0)
    }
}

impl Execute for TaskBoardDispatchDeliverArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let response =
            daemon_client()?.deliver_task_board_dispatch(&TaskBoardDispatchDeliverRequest {
                item_id: self.item_id.clone(),
                dry_run: self.dry_run,
            })?;
        if self.json {
            print_json(&response)?;
        } else {
            print_dispatch_delivery(&response, self.dry_run);
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

fn print_dispatch_pick(response: &TaskBoardDispatchPickResponse) {
    let Some(selection) = &response.selection else {
        println!("no ready task-board dispatch");
        return;
    };
    println!("{}: {}", selection.item.id, selection.item.title);
    println!("{}", selection.plan.rendered_prompt);
}

fn print_dispatch_delivery(response: &TaskBoardDispatchDeliverResponse, dry_run: bool) {
    let disposition = if dry_run { "previewed" } else { "started" };
    println!(
        "task-board dispatch {}: {} -> session {} task {} ({disposition})",
        response.intent_id,
        response.applied.board_item_id,
        response.applied.session_id,
        response.applied.work_item_id
    );
    println!("{}", response.rendered_prompt);
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
