use clap::{Args, Subcommand};
use serde::Serialize;

use crate::task_board::external::{
    ExternalProvider, ExternalSyncConflictPolicy, ExternalSyncDirection,
};
use crate::task_board::types::{AgentMode, TaskBoardItemKind, TaskBoardPriority, TaskBoardStatus};
use crate::task_board::wire::{TASK_BOARD_STORAGE_DATABASE, TaskBoardCapabilitiesResponse};
use harness_daemon_client::{ClientError, DaemonClient};
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_workspace::command_context::{AppContext, Execute};

mod catalog;
mod dispatch;
mod evaluate;
mod host;
// `pub`, not private: `tests/integration_daemon.rs`'s
// `task_board_item_commands_daemon_routing` scenarios build
// `TaskBoardItemFieldArgs` literals directly the same way this crate's own
// unit tests did.
pub mod item_args;
// `pub`, not private: `tests/integration_daemon.rs`'s
// `task_board_item_commands_daemon_routing` scenarios exercise the
// page-walk helpers below directly against a fake daemon, the same reason
// `daemon::db::AsyncDaemonDb` is `pub` there.
pub mod item_commands;
mod orchestrator;
mod orchestrator_tokens;
mod planning;
mod policy;
mod policy_io;
mod progress;
mod sync;
mod triage_escalation;

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
pub use progress::TaskBoardProgressCommand;
pub use triage_escalation::TaskBoardTriageEscalationReportArgs;

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
    /// Report and read worker progress on a dispatched item.
    Progress {
        #[command(subcommand)]
        command: TaskBoardProgressCommand,
    },
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
    /// Triage escalation commands. The daemon's own spawned escalation
    /// worker is the only real caller.
    TriageEscalation {
        #[command(subcommand)]
        command: TaskBoardTriageEscalationCommand,
    },
}

/// Grouped `task-board triage-escalation` commands.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum TaskBoardTriageEscalationCommand {
    /// Report a triage escalation verdict back to the daemon.
    Report(TaskBoardTriageEscalationReportArgs),
}

#[derive(Debug, Clone, Args)]
pub struct TaskBoardCreateArgs {
    #[arg(long)]
    pub title: String,
    #[arg(long, default_value = "")]
    pub body: String,
    #[arg(long, value_enum)]
    pub status: Option<TaskBoardStatus>,
    #[arg(long, value_enum, default_value = "medium")]
    pub priority: TaskBoardPriority,
    #[arg(long, value_enum, default_value = "headless")]
    pub agent_mode: AgentMode,
    #[arg(long, value_enum, default_value = "task")]
    pub kind: TaskBoardItemKind,
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

/// Read the board. Without `--limit` or `--cursor` this walks every page, so
/// the output stays the whole matching selection even though each daemon
/// response is bounded.
#[derive(Debug, Clone, Args)]
pub struct TaskBoardListArgs {
    #[arg(long, value_enum)]
    pub status: Option<TaskBoardStatus>,
    #[arg(long, value_enum)]
    pub priority: Option<TaskBoardPriority>,
    #[arg(long, value_enum)]
    pub agent_mode: Option<AgentMode>,
    #[arg(long)]
    pub project_id: Option<String>,
    /// Repeatable; an item must carry every requested tag.
    #[arg(long)]
    pub tag: Vec<String>,
    /// Case-insensitive substring over title, body, and tags.
    #[arg(long)]
    pub query: Option<String>,
    /// Read one page of at most this many items instead of every page.
    #[arg(long)]
    pub limit: Option<u32>,
    /// Read the page following a previous page's `next_cursor`.
    #[arg(long)]
    pub cursor: Option<String>,
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
    #[arg(long, value_enum)]
    pub kind: Option<TaskBoardItemKind>,
    #[arg(long)]
    pub tag: Vec<String>,
    #[arg(long)]
    pub project_id: Option<String>,
    #[arg(long)]
    pub target_project_type: Vec<String>,
    #[arg(long)]
    pub parent_id: Option<String>,
    #[command(flatten)]
    pub fields: TaskBoardItemFieldArgs,
    #[command(flatten)]
    pub clear_links: TaskBoardUpdateClearLinkArgs,
    #[command(flatten)]
    pub clear_estimates: TaskBoardUpdateClearEstimateArgs,
    #[command(flatten)]
    pub clear_state: TaskBoardUpdateClearStateArgs,
}

#[expect(
    clippy::struct_excessive_bools,
    reason = "CLI surface exposes independent identity-clear flags"
)]
#[derive(Debug, Clone, Args)]
pub struct TaskBoardUpdateClearLinkArgs {
    #[arg(long)]
    pub clear_project: bool,
    #[arg(long)]
    pub clear_session: bool,
    #[arg(long)]
    pub clear_work_item: bool,
    #[arg(long, conflicts_with = "parent_id")]
    pub clear_parent: bool,
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
            Self::Progress { command } => command.execute(context),
            Self::Audit(args) => args.execute(context),
            Self::Project(args) => args.execute_project(context),
            Self::Machine(args) => args.execute_machine(context),
            Self::Host { command } => command.execute(context),
            Self::Orchestrator { command } => command.execute(context),
            Self::Policy { command } => command.execute(context),
            Self::TriageEscalation { command } => command.execute(context),
        }
    }
}

impl Execute for TaskBoardTriageEscalationCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Report(args) => args.execute(context),
        }
    }
}

/// Every command in this module now goes through the leaf
/// `harness-daemon-client` rather than the root `daemon::client` facade, so
/// `task_board::transport` carries no daemon-crate dependency.
pub(super) fn leaf_daemon_client() -> Result<DaemonClient, CliError> {
    let client = DaemonClient::try_connect().ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_io(
            "task-board commands require a running daemon; start Harness Monitor or run `harness-daemon dev`",
        ))
    })?;
    require_database_task_board(&client)?;
    Ok(client)
}

fn require_database_task_board(client: &DaemonClient) -> Result<(), CliError> {
    let capability = client
        .get_optional::<TaskBoardCapabilitiesResponse>("/v1/task-board/capabilities", &[])
        .map_err(|error| leaf_daemon_client_error("check task-board capability", &error))?
        .ok_or_else(task_board_upgrade_required)?;
    if capability.storage != TASK_BOARD_STORAGE_DATABASE {
        return Err(task_board_upgrade_required());
    }
    Ok(())
}

fn task_board_upgrade_required() -> CliError {
    CliErrorKind::workflow_io(
        "the running daemon does not provide database-backed Task Board storage; upgrade and restart the daemon",
    )
    .into()
}

pub(super) fn leaf_daemon_client_error(operation: &str, error: &ClientError) -> CliError {
    CliError::from(CliErrorKind::workflow_io(format!(
        "daemon {operation}: {error}"
    )))
}

pub(super) fn print_json<T: Serialize>(value: &T) -> Result<(), CliError> {
    let json = serde_json::to_string_pretty(value)
        .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
    println!("{json}");
    Ok(())
}
