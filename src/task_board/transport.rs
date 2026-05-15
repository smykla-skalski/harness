use std::future::Future;
use std::path::PathBuf;

use clap::{Args, Subcommand};
use serde::Serialize;
use tokio::runtime::Builder as TokioRuntimeBuilder;
use uuid::Uuid;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::external::{
    ExternalProvider, ExternalSyncConflictPolicy, ExternalSyncDirection,
};
use crate::task_board::store::{TaskBoardStore, default_board_root};
use crate::task_board::types::{AgentMode, TaskBoardPriority, TaskBoardStatus};

mod catalog;
mod dispatch;
mod evaluate;
mod host;
mod item_args;
mod item_commands;
mod orchestrator;
mod orchestrator_tokens;
mod planning;
mod sync;

pub use evaluate::TaskBoardEvaluateArgs;
pub use host::TaskBoardHostCommand;
use item_args::TaskBoardItemFieldArgs;
pub use orchestrator::TaskBoardOrchestratorCommand;
pub use planning::{TaskBoardPlanApproveArgs, TaskBoardPlanBeginArgs, TaskBoardPlanSubmitArgs};

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
    /// Move an item into planning and clear any approval.
    Begin(TaskBoardPlanBeginArgs),
    /// Submit a plan summary for review.
    Submit(TaskBoardPlanSubmitArgs),
    /// Approve a submitted plan and move it to ready work.
    Approve(TaskBoardPlanApproveArgs),
    /// Run external synchronization.
    Sync(TaskBoardSyncArgs),
    /// Dispatch ready work into sessions.
    Dispatch(TaskBoardDispatchArgs),
    /// Evaluate linked session work and update board workflow state.
    Evaluate(TaskBoardEvaluateArgs),
    /// Print task-board audit data.
    Audit(TaskBoardAuditArgs),
    /// Manage known projects.
    Project(TaskBoardCatalogArgs),
    /// Manage known worker machines.
    Machine(TaskBoardCatalogArgs),
    /// Manage the local host record and its declared project types.
    Host {
        #[command(subcommand)]
        command: TaskBoardHostCommand,
    },
    /// Manage autonomous task-board orchestration.
    Orchestrator {
        #[command(subcommand)]
        command: TaskBoardOrchestratorCommand,
    },
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
    pub target_project_type: Vec<String>,
    #[command(flatten)]
    pub fields: TaskBoardItemFieldArgs,
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
    pub target_project_type: Vec<String>,
    #[command(flatten)]
    pub fields: TaskBoardItemFieldArgs,
    #[command(flatten)]
    pub clear_links: TaskBoardUpdateClearLinkArgs,
    #[command(flatten)]
    pub clear_state: TaskBoardUpdateClearStateArgs,
    #[arg(long)]
    pub board_root: Option<PathBuf>,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardUpdateClearLinkArgs {
    #[arg(long)]
    pub clear_project: bool,
    #[arg(long)]
    pub clear_session: bool,
    #[arg(long)]
    pub clear_work_item: bool,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardUpdateClearStateArgs {
    #[arg(long)]
    pub clear_external_refs: bool,
    #[arg(long)]
    pub clear_planning: bool,
    #[arg(long)]
    pub clear_workflow: bool,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardDeleteArgs {
    pub id: String,
    #[arg(long)]
    pub board_root: Option<PathBuf>,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardSyncArgs {
    #[arg(long)]
    pub json: bool,
    #[arg(long, value_enum)]
    pub provider: Option<ExternalProvider>,
    #[arg(long, value_enum, default_value = "both")]
    pub direction: ExternalSyncDirection,
    #[arg(long, value_enum, default_value = "report")]
    pub conflict_policy: ExternalSyncConflictPolicy,
    #[arg(long)]
    pub apply: bool,
    #[arg(long)]
    pub board_root: Option<PathBuf>,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardCatalogArgs {
    #[arg(long)]
    pub json: bool,
    #[arg(long, value_enum)]
    pub status: Option<TaskBoardStatus>,
    #[arg(long)]
    pub board_root: Option<PathBuf>,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardDispatchArgs {
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
    #[arg(long)]
    pub actor: Option<String>,
    #[arg(long)]
    pub board_root: Option<PathBuf>,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardAuditArgs {
    #[arg(long)]
    pub json: bool,
    #[arg(long)]
    pub board_root: Option<PathBuf>,
}

impl Execute for TaskBoardCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Create(args) => args.execute(context),
            Self::List(args) => args.execute(context),
            Self::Get(args) => args.execute(context),
            Self::Update(args) => args.execute(context),
            Self::Delete(args) => args.execute(context),
            Self::Begin(args) => args.execute(context),
            Self::Submit(args) => args.execute(context),
            Self::Approve(args) => args.execute(context),
            Self::Sync(args) => args.execute(context),
            Self::Dispatch(args) => args.execute(context),
            Self::Evaluate(args) => args.execute(context),
            Self::Audit(args) => args.execute(context),
            Self::Project(args) => args.execute_project(context),
            Self::Machine(args) => args.execute_machine(context),
            Self::Host { command } => command.execute(context),
            Self::Orchestrator { command } => command.execute(context),
        }
    }
}

pub(super) fn store(root: Option<PathBuf>) -> TaskBoardStore {
    TaskBoardStore::new(root.unwrap_or_else(default_board_root))
}

fn new_task_id() -> String {
    format!("task-{}", Uuid::new_v4().simple())
}

pub(super) fn new_workflow_execution_id() -> String {
    format!("workflow-{}", Uuid::new_v4().simple())
}

pub(super) fn new_policy_trace_id() -> String {
    format!("policy-trace-{}", Uuid::new_v4().simple())
}

pub(super) fn print_json<T: Serialize>(value: &T) -> Result<(), CliError> {
    let json = serde_json::to_string_pretty(value)
        .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
    println!("{json}");
    Ok(())
}

pub(super) fn run_blocking<T>(
    future: impl Future<Output = Result<T, CliError>>,
) -> Result<T, CliError> {
    TokioRuntimeBuilder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| CliErrorKind::workflow_io(format!("create task-board runtime: {error}")))?
        .block_on(future)
}
