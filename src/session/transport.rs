use std::env;

use clap::{Args, Subcommand};
use serde::Serialize;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::HookAgent;

use super::service;
use super::types::{SessionRole, TaskSeverity, TaskStatus};

/// Multi-agent session orchestration commands.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum SessionCommand {
    /// Create a new multi-agent orchestration session.
    Start(SessionStartArgs),
    /// Register an agent into an existing session.
    Join(SessionJoinArgs),
    /// End an active session.
    End(SessionEndArgs),
    /// Assign or change the role of an agent.
    Assign(SessionAssignArgs),
    /// Remove an agent from a session.
    Remove(SessionRemoveArgs),
    /// Transfer leader role to another agent.
    TransferLeader(SessionTransferLeaderArgs),
    /// Task management.
    Task {
        #[command(subcommand)]
        command: SessionTaskCommand,
    },
    /// Signal management.
    Signal {
        #[command(subcommand)]
        command: SessionSignalCommand,
    },
    /// Observe all agents in a session.
    Observe(SessionObserveArgs),
    /// Show current session status.
    Status(SessionStatusArgs),
    /// List sessions.
    List(SessionListArgs),
}

/// Session task subcommands.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum SessionTaskCommand {
    /// Create a new work item.
    Create(TaskCreateArgs),
    /// Assign a work item to an agent.
    Assign(TaskAssignArgs),
    /// List work items in a session.
    List(TaskListArgs),
    /// Update a work item's status.
    Update(TaskUpdateArgs),
    /// Record an append-only task checkpoint.
    Checkpoint(TaskCheckpointArgs),
}

/// Session signal subcommands.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum SessionSignalCommand {
    /// Send a file-backed signal to an agent runtime.
    Send(SignalSendArgs),
    /// List known signals for a session.
    List(SignalListArgs),
}

impl Execute for SessionCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Start(args) => args.execute(context),
            Self::Join(args) => args.execute(context),
            Self::End(args) => args.execute(context),
            Self::Assign(args) => args.execute(context),
            Self::Remove(args) => args.execute(context),
            Self::TransferLeader(args) => args.execute(context),
            Self::Task { command } => command.execute(context),
            Self::Signal { command } => command.execute(context),
            Self::Observe(args) => args.execute(context),
            Self::Status(args) => args.execute(context),
            Self::List(args) => args.execute(context),
        }
    }
}

impl Execute for SessionTaskCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Create(args) => args.execute(context),
            Self::Assign(args) => args.execute(context),
            Self::List(args) => args.execute(context),
            Self::Update(args) => args.execute(context),
            Self::Checkpoint(args) => args.execute(context),
        }
    }
}

impl Execute for SessionSignalCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Send(args) => args.execute(context),
            Self::List(args) => args.execute(context),
        }
    }
}

fn resolve_project_dir(hint: Option<&str>) -> String {
    hint.filter(|value| !value.trim().is_empty()).map_or_else(
        || {
            env::current_dir().map_or_else(
                |_| ".".to_string(),
                |path| path.to_string_lossy().to_string(),
            )
        },
        ToString::to_string,
    )
}

fn print_json<T: Serialize>(value: &T) -> Result<(), CliError> {
    let json = serde_json::to_string_pretty(value)
        .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
    println!("{json}");
    Ok(())
}

#[derive(Debug, Clone, Args)]
pub struct SessionStartArgs {
    /// Human-readable context or goal for this session.
    #[arg(long)]
    pub context: String,
    /// Project directory (defaults to cwd).
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
    /// Agent runtime of the leader starting this session.
    #[arg(long, value_enum)]
    pub runtime: Option<HookAgent>,
    /// Explicit session ID (auto-generated if omitted).
    #[arg(long)]
    pub session_id: Option<String>,
}

impl Execute for SessionStartArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let project = resolve_project_dir(self.project_dir.as_deref());
        let state = service::start_session(
            &self.context,
            project.as_ref(),
            self.runtime.map(agent_to_str),
            self.session_id.as_deref(),
        )?;
        print_json(&state)?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct SessionJoinArgs {
    /// Session ID to join.
    pub session_id: String,
    /// Role to join as.
    #[arg(long, value_enum)]
    pub role: SessionRole,
    /// Agent runtime.
    #[arg(long, value_enum)]
    pub runtime: HookAgent,
    /// Comma-separated capability tags.
    #[arg(long)]
    pub capabilities: Option<String>,
    /// Human-readable agent display name.
    #[arg(long)]
    pub name: Option<String>,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for SessionJoinArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let project = resolve_project_dir(self.project_dir.as_deref());
        let capabilities: Vec<String> = self
            .capabilities
            .as_deref()
            .map(|value| {
                value
                    .split(',')
                    .map(str::trim)
                    .filter(|item| !item.is_empty())
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let state = service::join_session(
            &self.session_id,
            self.role,
            agent_to_str(self.runtime),
            &capabilities,
            self.name.as_deref(),
            project.as_ref(),
        )?;
        print_json(&state)?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct SessionEndArgs {
    /// Session ID.
    pub session_id: String,
    /// Agent ID of the caller.
    #[arg(long)]
    pub actor: String,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for SessionEndArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let project = resolve_project_dir(self.project_dir.as_deref());
        service::end_session(&self.session_id, &self.actor, project.as_ref())?;
        println!("session '{}' ended", self.session_id);
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct SessionAssignArgs {
    /// Session ID.
    pub session_id: String,
    /// Agent ID to assign.
    pub agent_id: String,
    /// New role.
    #[arg(long, value_enum)]
    pub role: SessionRole,
    /// Agent ID of the caller.
    #[arg(long)]
    pub actor: String,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for SessionAssignArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let project = resolve_project_dir(self.project_dir.as_deref());
        service::assign_role(
            &self.session_id,
            &self.agent_id,
            self.role,
            &self.actor,
            project.as_ref(),
        )?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct SessionRemoveArgs {
    /// Session ID.
    pub session_id: String,
    /// Agent ID to remove.
    pub agent_id: String,
    /// Agent ID of the caller.
    #[arg(long)]
    pub actor: String,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for SessionRemoveArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let project = resolve_project_dir(self.project_dir.as_deref());
        service::remove_agent(
            &self.session_id,
            &self.agent_id,
            &self.actor,
            project.as_ref(),
        )?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct SessionTransferLeaderArgs {
    /// Session ID.
    pub session_id: String,
    /// Agent ID of the new leader.
    pub new_leader_id: String,
    /// Reason for transfer.
    #[arg(long)]
    pub reason: Option<String>,
    /// Agent ID of the caller.
    #[arg(long)]
    pub actor: String,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for SessionTransferLeaderArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let project = resolve_project_dir(self.project_dir.as_deref());
        service::transfer_leader(
            &self.session_id,
            &self.new_leader_id,
            self.reason.as_deref(),
            &self.actor,
            project.as_ref(),
        )?;
        Ok(0)
    }
}

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
    /// Agent ID of the caller.
    #[arg(long)]
    pub actor: String,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for TaskCreateArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let project = resolve_project_dir(self.project_dir.as_deref());
        let item = service::create_task(
            &self.session_id,
            &self.title,
            self.context.as_deref(),
            self.severity,
            &self.actor,
            project.as_ref(),
        )?;
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
        let project = resolve_project_dir(self.project_dir.as_deref());
        service::assign_task(
            &self.session_id,
            &self.task_id,
            &self.agent_id,
            &self.actor,
            project.as_ref(),
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
        let project = resolve_project_dir(self.project_dir.as_deref());
        let items = service::list_tasks(&self.session_id, self.status, project.as_ref())?;
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
                    item.checkpoint_summary
                        .as_ref()
                        .map_or_else(|| "-".to_string(), |summary| format!("{}%", summary.progress)),
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
        let project = resolve_project_dir(self.project_dir.as_deref());
        service::update_task(
            &self.session_id,
            &self.task_id,
            self.status,
            self.note.as_deref(),
            &self.actor,
            project.as_ref(),
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
        let project = resolve_project_dir(self.project_dir.as_deref());
        let checkpoint = service::record_task_checkpoint(
            &self.session_id,
            &self.task_id,
            &self.actor,
            &self.summary,
            self.progress,
            project.as_ref(),
        )?;
        print_json(&checkpoint)?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct SignalSendArgs {
    /// Session ID.
    pub session_id: String,
    /// Agent ID receiving the signal.
    pub agent_id: String,
    /// Runtime command name for the signal.
    #[arg(long)]
    pub command: String,
    /// Human-readable message payload.
    #[arg(long)]
    pub message: String,
    /// Optional action hint for the target agent.
    #[arg(long)]
    pub action_hint: Option<String>,
    /// Agent ID of the caller.
    #[arg(long)]
    pub actor: String,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for SignalSendArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let project = resolve_project_dir(self.project_dir.as_deref());
        let signal = service::send_signal(
            &self.session_id,
            &self.agent_id,
            &self.command,
            &self.message,
            self.action_hint.as_deref(),
            &self.actor,
            project.as_ref(),
        )?;
        print_json(&signal)?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct SignalListArgs {
    /// Session ID.
    pub session_id: String,
    /// Filter to a single agent.
    #[arg(long)]
    pub agent: Option<String>,
    /// Output as JSON.
    #[arg(long)]
    pub json: bool,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for SignalListArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let project = resolve_project_dir(self.project_dir.as_deref());
        let signals =
            service::list_signals(&self.session_id, self.agent.as_deref(), project.as_ref())?;
        if self.json {
            print_json(&signals)?;
        } else {
            for signal in &signals {
                println!(
                    "[{:?}] {} -> {} ({}) {}",
                    signal.status,
                    signal.signal.source_agent,
                    signal.agent_id,
                    signal.runtime,
                    signal.signal.command,
                );
            }
        }
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct SessionObserveArgs {
    /// Session ID.
    pub session_id: String,
    /// Poll interval in seconds for watch mode (0 = one-shot scan).
    #[arg(long, default_value = "0")]
    pub poll_interval: u64,
    /// Output as JSON.
    #[arg(long)]
    pub json: bool,
    /// Actor ID used for task creation; omit to keep observe read-only.
    #[arg(long)]
    pub actor: Option<String>,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for SessionObserveArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let project = resolve_project_dir(self.project_dir.as_deref());
        if self.poll_interval > 0 {
            super::observe::execute_session_watch(
                &self.session_id,
                project.as_ref(),
                self.poll_interval,
                self.json,
                self.actor.as_deref(),
            )
        } else {
            super::observe::execute_session_observe(
                &self.session_id,
                project.as_ref(),
                self.json,
                self.actor.as_deref(),
            )
        }
    }
}

#[derive(Debug, Clone, Args)]
pub struct SessionStatusArgs {
    /// Session ID.
    pub session_id: String,
    /// Output as JSON.
    #[arg(long)]
    pub json: bool,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for SessionStatusArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let project = resolve_project_dir(self.project_dir.as_deref());
        let state = service::session_status(&self.session_id, project.as_ref())?;
        if self.json {
            print_json(&state)?;
        } else {
            println!(
                "{} [{:?}] - {} (agents: {}, active: {}, tasks: {} open / {} in flight / {} done)",
                state.session_id,
                state.status,
                state.context,
                state.metrics.agent_count,
                state.metrics.active_agent_count,
                state.metrics.open_task_count,
                state.metrics.in_progress_task_count + state.metrics.blocked_task_count,
                state.metrics.completed_task_count,
            );
        }
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct SessionListArgs {
    /// Include archived sessions.
    #[arg(long)]
    pub all: bool,
    /// Output as JSON.
    #[arg(long)]
    pub json: bool,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for SessionListArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let project = resolve_project_dir(self.project_dir.as_deref());
        let sessions = service::list_sessions(project.as_ref(), self.all)?;
        if self.json {
            print_json(&sessions)?;
        } else {
            for session in &sessions {
                println!(
                    "{} [{:?}] - {} (agents: {}, active: {}, tasks: {} open / {} in flight / {} done)",
                    session.session_id,
                    session.status,
                    session.context,
                    session.metrics.agent_count,
                    session.metrics.active_agent_count,
                    session.metrics.open_task_count,
                    session.metrics.in_progress_task_count + session.metrics.blocked_task_count,
                    session.metrics.completed_task_count,
                );
            }
        }
        Ok(0)
    }
}

fn agent_to_str(agent: HookAgent) -> &'static str {
    match agent {
        HookAgent::Claude => "claude",
        HookAgent::Codex => "codex",
        HookAgent::Gemini => "gemini",
        HookAgent::Copilot => "copilot",
        HookAgent::OpenCode => "opencode",
    }
}
