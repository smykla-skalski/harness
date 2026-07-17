use clap::{Args, Subcommand};
use serde::Serialize;

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::client::DaemonClient;
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::external::{
    ExternalProvider, ExternalSyncConflictPolicy, ExternalSyncDirection,
};
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
mod policy;
mod policy_io;
mod sync;

pub use dispatch::{TaskBoardDispatchDeliverArgs, TaskBoardDispatchPickArgs};
pub use evaluate::TaskBoardEvaluateArgs;
pub use host::TaskBoardHostCommand;
use item_args::TaskBoardItemFieldArgs;
pub use orchestrator::TaskBoardOrchestratorCommand;
pub use planning::{
    TaskBoardPlanApproveArgs, TaskBoardPlanBeginArgs, TaskBoardPlanRevokeArgs,
    TaskBoardPlanSubmitArgs,
};
pub use policy::{
    TaskBoardPolicyCommand, TaskBoardPolicyGrantResolveArgs, TaskBoardPolicyGrantRevokeArgs,
    TaskBoardPolicyJsonArgs, TaskBoardPolicyToggleArgs,
};
pub use policy_io::{TaskBoardPolicyDumpArgs, TaskBoardPolicyImportArgs};

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
    /// Revoke a previously granted approval; the plan summary stays intact.
    PlanRevoke(TaskBoardPlanRevokeArgs),
    /// Run external synchronization.
    Sync(TaskBoardSyncArgs),
    /// Dispatch ready work into sessions.
    Dispatch(TaskBoardDispatchArgs),
    /// Preview the highest-priority ready task-board dispatch.
    #[command(visible_alias = "pick")]
    DispatchPick(TaskBoardDispatchPickArgs),
    /// Deliver one held task-board dispatch.
    #[command(visible_alias = "deliver")]
    DispatchDeliver(TaskBoardDispatchDeliverArgs),
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
    /// Manage task-board spawn policy and approval grants.
    Policy {
        #[command(subcommand)]
        command: TaskBoardPolicyCommand,
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
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardListArgs {
    #[arg(long, value_enum)]
    pub status: Option<TaskBoardStatus>,
    #[arg(long)]
    pub json: bool,
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardGetArgs {
    pub id: String,
    #[arg(long)]
    pub json: bool,
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
    pub clear_estimates: TaskBoardUpdateClearEstimateArgs,
    #[command(flatten)]
    pub clear_state: TaskBoardUpdateClearStateArgs,
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
pub struct TaskBoardUpdateClearEstimateArgs {
    #[arg(long, conflicts_with = "estimated_tokens")]
    pub clear_estimated_tokens: bool,
    #[arg(long, conflicts_with = "estimated_cost_microusd")]
    pub clear_estimated_cost_microusd: bool,
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
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardCatalogArgs {
    #[arg(long)]
    pub json: bool,
    #[arg(long, value_enum)]
    pub status: Option<TaskBoardStatus>,
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
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardAuditArgs {
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
            Self::Begin(args) => args.execute(context),
            Self::Submit(args) => args.execute(context),
            Self::Approve(args) => args.execute(context),
            Self::PlanRevoke(args) => args.execute(context),
            Self::Sync(args) => args.execute(context),
            Self::Dispatch(args) => args.execute(context),
            Self::DispatchPick(args) => args.execute(context),
            Self::DispatchDeliver(args) => args.execute(context),
            Self::Evaluate(args) => args.execute(context),
            Self::Audit(args) => args.execute(context),
            Self::Project(args) => args.execute_project(context),
            Self::Machine(args) => args.execute_machine(context),
            Self::Host { command } => command.execute(context),
            Self::Orchestrator { command } => command.execute(context),
            Self::Policy { command } => command.execute(context),
        }
    }
}

pub(super) fn daemon_client() -> Result<DaemonClient, CliError> {
    let client = DaemonClient::try_connect().ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_io(
            "task-board commands require a running daemon; start Harness Monitor or run `harness-daemon dev`",
        ))
    })?;
    client.require_database_task_board()?;
    Ok(client)
}

pub(super) fn print_json<T: Serialize>(value: &T) -> Result<(), CliError> {
    let json = serde_json::to_string_pretty(value)
        .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
    println!("{json}");
    Ok(())
}
