use clap::{Args, Subcommand};

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::protocol::{
    TaskBoardOrchestratorRunOnceRequest, TaskBoardOrchestratorSettingsUpdateRequest,
};
use crate::daemon::service;
use crate::errors::CliError;
use crate::task_board::types::TaskBoardStatus;

use super::print_json;

#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum TaskBoardOrchestratorCommand {
    /// Print durable orchestrator status.
    Status(TaskBoardOrchestratorJsonArgs),
    /// Enable autonomous orchestration intent.
    Start(TaskBoardOrchestratorJsonArgs),
    /// Disable autonomous orchestration intent.
    Stop(TaskBoardOrchestratorJsonArgs),
    /// Run one orchestrator tick.
    RunOnce(TaskBoardOrchestratorRunOnceArgs),
    /// Read or update durable orchestrator settings.
    Settings(TaskBoardOrchestratorSettingsArgs),
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardOrchestratorJsonArgs {
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardOrchestratorRunOnceArgs {
    #[arg(long)]
    pub json: bool,
    #[arg(long, conflicts_with = "apply")]
    pub dry_run: bool,
    #[arg(long)]
    pub apply: bool,
    #[arg(long, value_enum)]
    pub status: Option<TaskBoardStatus>,
    #[arg(long)]
    pub project_dir: Option<String>,
    #[arg(long)]
    pub actor: Option<String>,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardOrchestratorSettingsArgs {
    #[arg(long)]
    pub json: bool,
    #[arg(long)]
    pub dry_run_default: Option<bool>,
    #[arg(long, value_enum)]
    pub dispatch_status_filter: Option<TaskBoardStatus>,
    #[arg(long)]
    pub clear_dispatch_status_filter: bool,
    #[arg(long)]
    pub project_dir: Option<String>,
    #[arg(long)]
    pub clear_project_dir: bool,
}

impl Execute for TaskBoardOrchestratorCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Status(args) => args.execute_status(context),
            Self::Start(args) => args.execute_start(context),
            Self::Stop(args) => args.execute_stop(context),
            Self::RunOnce(args) => args.execute(context),
            Self::Settings(args) => args.execute(context),
        }
    }
}

impl TaskBoardOrchestratorJsonArgs {
    fn execute_status(&self, _context: &AppContext) -> Result<i32, CliError> {
        let status = service::task_board_orchestrator_status()?;
        print_status(&status, self.json)
    }

    fn execute_start(&self, _context: &AppContext) -> Result<i32, CliError> {
        let status = service::start_task_board_orchestrator()?;
        print_status(&status, self.json)
    }

    fn execute_stop(&self, _context: &AppContext) -> Result<i32, CliError> {
        let status = service::stop_task_board_orchestrator()?;
        print_status(&status, self.json)
    }
}

impl Execute for TaskBoardOrchestratorRunOnceArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let request = TaskBoardOrchestratorRunOnceRequest {
            dry_run: dry_run_override(self.dry_run, self.apply),
            status: self.status,
            project_dir: self.project_dir.clone(),
            actor: self.actor.clone(),
        };
        let status = service::run_task_board_orchestrator_once(&request, None)?;
        print_status(&status, self.json)
    }
}

impl Execute for TaskBoardOrchestratorSettingsArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let settings = if self.has_update() {
            service::update_task_board_orchestrator_settings(&self.update_request())?
        } else {
            service::task_board_orchestrator_settings()?
        };
        if self.json {
            print_json(&settings)?;
        } else {
            println!(
                "task-board orchestrator settings: dry_run_default={}, project_dir={}",
                settings.dry_run_default,
                settings.project_dir.as_deref().unwrap_or("<unset>")
            );
        }
        Ok(0)
    }
}

impl TaskBoardOrchestratorSettingsArgs {
    fn has_update(&self) -> bool {
        self.dry_run_default.is_some()
            || self.dispatch_status_filter.is_some()
            || self.clear_dispatch_status_filter
            || self.project_dir.is_some()
            || self.clear_project_dir
    }

    fn update_request(&self) -> TaskBoardOrchestratorSettingsUpdateRequest {
        TaskBoardOrchestratorSettingsUpdateRequest {
            dry_run_default: self.dry_run_default,
            dispatch_status_filter: self.dispatch_status_filter,
            clear_dispatch_status_filter: self.clear_dispatch_status_filter,
            project_dir: self.project_dir.clone(),
            clear_project_dir: self.clear_project_dir,
            ..TaskBoardOrchestratorSettingsUpdateRequest::default()
        }
    }
}

fn dry_run_override(dry_run: bool, apply: bool) -> Option<bool> {
    if dry_run {
        Some(true)
    } else if apply {
        Some(false)
    } else {
        None
    }
}

fn print_status(
    status: &crate::task_board::TaskBoardOrchestratorStatus,
    json: bool,
) -> Result<i32, CliError> {
    if json {
        print_json(status)?;
    } else {
        println!(
            "task-board orchestrator: enabled={}, running={}, last_applied={}",
            status.enabled,
            status.running,
            status.last_run_applied_count()
        );
    }
    Ok(0)
}
