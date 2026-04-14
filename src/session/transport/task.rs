use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::CliError;
use crate::session::service;
use crate::session::types::{TaskSeverity, TaskSource, TaskStatus};

use super::support::{print_json, resolve_project_dir};

#[derive(Debug, Clone, Args)]
pub struct TaskCreateArgs {
    /// Session ID.
    pub session_id: String,
    /// Task title.
    #[arg(long)]
    pub title: String,
    /// Task context.
    #[arg(long)]
    pub context: Option<String>,
    /// Severity level.
    #[arg(long, value_enum, default_value = "medium")]
    pub severity: TaskSeverity,
    /// Suggested fix, if already known.
    #[arg(long)]
    pub suggested_fix: Option<String>,
    /// Agent ID of the caller.
    #[arg(long)]
    pub actor: String,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for TaskCreateArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, local_project.as_ref())?;
        let spec = service::TaskSpec {
            title: &self.title,
            context: self.context.as_deref(),
            severity: self.severity,
            suggested_fix: self.suggested_fix.as_deref(),
            source: TaskSource::Manual,
            observe_issue_id: None,
        };
        let item =
            service::create_task_with_source(&self.session_id, &spec, &self.actor, &project)?;
        print_json(&item)?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct TaskAssignArgs {
    /// Session ID.
    pub session_id: String,
    /// Task ID to assign.
    pub task_id: String,
    /// Agent ID to assign to.
    pub agent_id: String,
    /// Agent ID of the caller.
    #[arg(long)]
    pub actor: String,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for TaskAssignArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, local_project.as_ref())?;
        service::assign_task(
            &self.session_id,
            &self.task_id,
            &self.agent_id,
            &self.actor,
            &project,
        )?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct TaskListArgs {
    /// Session ID.
    pub session_id: String,
    /// Filter by status.
    #[arg(long, value_enum)]
    pub status: Option<TaskStatus>,
    /// Output as JSON.
    #[arg(long)]
    pub json: bool,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for TaskListArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, local_project.as_ref())?;
        let items = service::list_tasks(&self.session_id, self.status, &project)?;
        if self.json {
            print_json(&items)?;
        } else {
            for item in &items {
                println!(
                    "[{:?}] {} - {} (assigned: {}, progress: {})",
                    item.severity,
                    item.task_id,
                    item.title,
                    item.assigned_to.as_deref().unwrap_or("unassigned"),
                    item.checkpoint_summary.as_ref().map_or_else(
                        || "-".to_string(),
                        |summary| format!("{}%", summary.progress)
                    ),
                );
            }
        }
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct TaskUpdateArgs {
    /// Session ID.
    pub session_id: String,
    /// Task ID to update.
    pub task_id: String,
    /// New status.
    #[arg(long, value_enum)]
    pub status: TaskStatus,
    /// Optional note.
    #[arg(long)]
    pub note: Option<String>,
    /// Agent ID of the caller.
    #[arg(long)]
    pub actor: String,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for TaskUpdateArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, local_project.as_ref())?;
        service::update_task(
            &self.session_id,
            &self.task_id,
            self.status,
            self.note.as_deref(),
            &self.actor,
            &project,
        )?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct TaskCheckpointArgs {
    /// Session ID.
    pub session_id: String,
    /// Task ID.
    pub task_id: String,
    /// Agent ID of the caller.
    #[arg(long)]
    pub actor: String,
    /// Human-readable checkpoint summary.
    #[arg(long)]
    pub summary: String,
    /// Progress percentage.
    #[arg(long, value_parser = clap::value_parser!(u8).range(0..=100))]
    pub progress: u8,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for TaskCheckpointArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, local_project.as_ref())?;
        let checkpoint = service::record_task_checkpoint(
            &self.session_id,
            &self.task_id,
            &self.actor,
            &self.summary,
            self.progress,
            &project,
        )?;
        print_json(&checkpoint)?;
        Ok(0)
    }
}
