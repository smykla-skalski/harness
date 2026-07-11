use clap::{Args, Subcommand};

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::protocol::TaskBoardHostSetProjectTypesRequest;
use crate::errors::CliError;

use super::{daemon_client, print_json};

#[derive(Debug, Clone, Subcommand)]
pub enum TaskBoardHostCommand {
    /// List every registered host.
    List(TaskBoardHostListArgs),
    /// Show the local host record, creating one on first call.
    Local(TaskBoardHostLocalArgs),
    /// Replace the local host's declared project types.
    SetProjectTypes(TaskBoardHostSetProjectTypesArgs),
    /// Drop every `project_type` from the local host record.
    ClearProjectTypes(TaskBoardHostLocalArgs),
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardHostListArgs {
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardHostLocalArgs {
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardHostSetProjectTypesArgs {
    /// Project types this host accepts. Repeat the flag for multiple types.
    #[arg(long = "type")]
    pub project_types: Vec<String>,
    #[arg(long)]
    pub json: bool,
}

impl Execute for TaskBoardHostCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::List(args) => args.run(context),
            Self::Local(args) => args.run_local(context),
            Self::SetProjectTypes(args) => args.run(context),
            Self::ClearProjectTypes(args) => args.run_clear(context),
        }
    }
}

impl TaskBoardHostListArgs {
    fn run(&self, _context: &AppContext) -> Result<i32, CliError> {
        let machines = daemon_client()?.task_board_host_list()?;
        if self.json {
            print_json(&machines)?;
        } else if machines.is_empty() {
            println!("no hosts registered");
        } else {
            for machine in machines {
                println!(
                    "{}\t{}\t[{}]",
                    machine.id,
                    machine.label,
                    machine.project_types.join(", ")
                );
            }
        }
        Ok(0)
    }
}

impl TaskBoardHostLocalArgs {
    fn run_local(&self, _context: &AppContext) -> Result<i32, CliError> {
        let machine = daemon_client()?.task_board_host_local()?;
        if self.json {
            print_json(&machine)?;
        } else {
            println!(
                "{}\t{}\t[{}]",
                machine.id,
                machine.label,
                machine.project_types.join(", ")
            );
        }
        Ok(0)
    }

    fn run_clear(&self, _context: &AppContext) -> Result<i32, CliError> {
        let stored = daemon_client()?
            .set_task_board_host_project_types(&TaskBoardHostSetProjectTypesRequest::default())?;
        if self.json {
            print_json(&stored)?;
        } else {
            println!("cleared project_types on host {}", stored.id);
        }
        Ok(0)
    }
}

impl TaskBoardHostSetProjectTypesArgs {
    fn run(&self, _context: &AppContext) -> Result<i32, CliError> {
        let stored = daemon_client()?.set_task_board_host_project_types(
            &TaskBoardHostSetProjectTypesRequest {
                project_types: self.project_types.clone(),
            },
        )?;
        if self.json {
            print_json(&stored)?;
        } else {
            println!(
                "host {} now accepts [{}]",
                stored.id,
                stored.project_types.join(", ")
            );
        }
        Ok(0)
    }
}
