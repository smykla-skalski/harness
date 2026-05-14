use std::path::PathBuf;

use clap::{Args, Subcommand};
use serde::Serialize;
use uuid::Uuid;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::store::{
    OptionalFieldPatch, TaskBoardItemPatch, TaskBoardStore, default_board_root,
};
use crate::task_board::types::{
    AgentMode, PlanningState, TaskBoardItem, TaskBoardPriority, TaskBoardStatus,
};
use crate::workspace::utc_now;

#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum TaskBoardCommand {
    /// Create a board task.
    Create(TaskBoardCreateArgs),
    /// List board tasks.
    List(TaskBoardListArgs),
    /// Show one board task.
    Get(TaskBoardGetArgs),
    /// Update one board task.
    Update(TaskBoardUpdateArgs),
    /// Tombstone one board task.
    Delete(TaskBoardDeleteArgs),
    /// Run external synchronization.
    Sync(TaskBoardNoopArgs),
    /// Dispatch ready work into sessions.
    Dispatch(TaskBoardNoopArgs),
    /// Print task-board audit data.
    Audit(TaskBoardNoopArgs),
    /// Manage known projects.
    Project(TaskBoardNoopArgs),
    /// Manage known worker machines.
    Machine(TaskBoardNoopArgs),
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardCreateArgs {
    #[arg(long)]
    pub title: String,
    #[arg(long, default_value = "")]
    pub body: String,
    #[arg(long, value_enum, default_value = "medium")]
    pub priority: TaskBoardPriority,
    #[arg(long, value_enum, default_value = "headless")]
    pub agent_mode: AgentMode,
    #[arg(long)]
    pub tag: Vec<String>,
    #[arg(long)]
    pub project_id: Option<String>,
    #[arg(long)]
    pub id: Option<String>,
    #[arg(long)]
    pub board_root: Option<PathBuf>,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardListArgs {
    #[arg(long, value_enum)]
    pub status: Option<TaskBoardStatus>,
    #[arg(long)]
    pub json: bool,
    #[arg(long)]
    pub board_root: Option<PathBuf>,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardGetArgs {
    pub id: String,
    #[arg(long)]
    pub json: bool,
    #[arg(long)]
    pub board_root: Option<PathBuf>,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardUpdateArgs {
    pub id: String,
    #[arg(long)]
    pub title: Option<String>,
    #[arg(long)]
    pub body: Option<String>,
    #[arg(long, value_enum)]
    pub status: Option<TaskBoardStatus>,
    #[arg(long, value_enum)]
    pub priority: Option<TaskBoardPriority>,
    #[arg(long, value_enum)]
    pub agent_mode: Option<AgentMode>,
    #[arg(long)]
    pub tag: Vec<String>,
    #[arg(long)]
    pub project_id: Option<String>,
    #[arg(long)]
    pub clear_project: bool,
    #[arg(long)]
    pub planning_summary: Option<String>,
    #[arg(long)]
    pub approved_by: Option<String>,
    #[arg(long)]
    pub board_root: Option<PathBuf>,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardDeleteArgs {
    pub id: String,
    #[arg(long)]
    pub board_root: Option<PathBuf>,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardNoopArgs {
    #[arg(long)]
    pub json: bool,
}

impl Execute for TaskBoardCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Create(args) => args.execute(context),
            Self::List(args) => args.execute(context),
            Self::Get(args) => args.execute(context),
            Self::Update(args) => args.execute(context),
            Self::Delete(args) => args.execute(context),
            Self::Sync(args)
            | Self::Dispatch(args)
            | Self::Audit(args)
            | Self::Project(args)
            | Self::Machine(args) => args.execute(context),
        }
    }
}

impl Execute for TaskBoardCreateArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let now = utc_now();
        let mut item = TaskBoardItem::new(
            self.id.clone().unwrap_or_else(new_task_id),
            self.title.clone(),
            self.body.clone(),
            now,
        );
        item.priority = self.priority;
        item.agent_mode = self.agent_mode;
        item.tags.clone_from(&self.tag);
        item.project_id.clone_from(&self.project_id);
        let item = store(self.board_root.clone()).create(&self.title, &self.body, item)?;
        print_json(&item)?;
        Ok(0)
    }
}

impl Execute for TaskBoardListArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let items = store(self.board_root.clone()).list(self.status)?;
        if self.json {
            print_json(&items)?;
        } else {
            for item in items {
                println!(
                    "[{:?}] {} - {} ({:?})",
                    item.priority, item.id, item.title, item.status
                );
            }
        }
        Ok(0)
    }
}

impl Execute for TaskBoardGetArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let item = store(self.board_root.clone()).get(&self.id)?;
        if self.json {
            print_json(&item)?;
        } else {
            println!("{} - {}\n\n{}", item.id, item.title, item.body);
        }
        Ok(0)
    }
}

impl Execute for TaskBoardUpdateArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let patch = self.patch();
        let item = store(self.board_root.clone()).update(&self.id, patch)?;
        print_json(&item)?;
        Ok(0)
    }
}

impl TaskBoardUpdateArgs {
    fn patch(&self) -> TaskBoardItemPatch {
        let planning = self.planning_patch();
        TaskBoardItemPatch {
            title: self.title.clone(),
            body: self.body.clone(),
            status: self.status,
            priority: self.priority,
            tags: (!self.tag.is_empty()).then(|| self.tag.clone()),
            project_id: self.project_patch(),
            agent_mode: self.agent_mode,
            planning,
            ..TaskBoardItemPatch::default()
        }
    }

    fn project_patch(&self) -> OptionalFieldPatch<String> {
        if self.clear_project {
            return OptionalFieldPatch::Clear;
        }
        self.project_id
            .clone()
            .map_or(OptionalFieldPatch::Unchanged, OptionalFieldPatch::Set)
    }

    fn planning_patch(&self) -> Option<PlanningState> {
        if self.planning_summary.is_none() && self.approved_by.is_none() {
            return None;
        }
        Some(PlanningState {
            summary: self.planning_summary.clone(),
            approved_by: self.approved_by.clone(),
            approved_at: self.approved_by.as_ref().map(|_| utc_now()),
        })
    }
}

impl Execute for TaskBoardDeleteArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let item = store(self.board_root.clone()).delete(&self.id)?;
        print_json(&item)?;
        Ok(0)
    }
}

impl Execute for TaskBoardNoopArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let payload = serde_json::json!({
            "status": "not_configured",
            "message": "task-board command surface is installed"
        });
        if self.json {
            print_json(&payload)?;
        } else {
            println!("task-board command surface is installed");
        }
        Ok(0)
    }
}

fn store(root: Option<PathBuf>) -> TaskBoardStore {
    TaskBoardStore::new(root.unwrap_or_else(default_board_root))
}

fn new_task_id() -> String {
    format!("task-{}", Uuid::new_v4().simple())
}

fn print_json<T: Serialize>(value: &T) -> Result<(), CliError> {
    let json = serde_json::to_string_pretty(value)
        .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
    println!("{json}");
    Ok(())
}
