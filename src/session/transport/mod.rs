use clap::Subcommand;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::CliError;

mod improver;
mod managed_agents;
mod recover;
mod session_commands;
mod signal;
mod support;
mod task;

pub use improver::SessionImproverApplyArgs;
pub use managed_agents::{
    CodexAgentApprovalArgs, CodexAgentInterruptArgs, CodexAgentStartArgs, CodexAgentSteerArgs,
    ManagedAgentAttachArgs, ManagedAgentListArgs, ManagedAgentShowArgs, ManagedTerminalInputArgs,
    ManagedTerminalResizeArgs, ManagedTerminalStopArgs, SessionAgentStartCommand,
    SessionAgentsCommand, TerminalAgentStartArgs,
};
pub use recover::SessionRecoverLeaderArgs;
pub use session_commands::{
    SessionAdoptArgs, SessionAssignArgs, SessionEndArgs, SessionJoinArgs, SessionLeaveArgs,
    SessionListArgs, SessionObserveArgs, SessionRemoveArgs, SessionStartArgs, SessionStatusArgs,
    SessionSyncArgs, SessionTitleArgs, SessionTransferLeaderArgs,
};
pub use signal::{SignalListArgs, SignalSendArgs};
pub use task::{
    TaskArbitrateArgs, TaskAssignArgs, TaskCheckpointArgs, TaskClaimReviewArgs, TaskCreateArgs,
    TaskListArgs, TaskRespondReviewArgs, TaskSubmitForReviewArgs, TaskSubmitReviewArgs,
    TaskUpdateArgs,
};

/// Multi-agent session orchestration commands.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum SessionCommand {
    /// Adopt an existing on-disk session directory into this daemon.
    Adopt(SessionAdoptArgs),
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
    /// Recover a leaderless degraded session with a managed leader TUI.
    RecoverLeader(SessionRecoverLeaderArgs),
    /// Task management.
    Task {
        #[command(subcommand)]
        command: SessionTaskCommand,
    },
    /// Improver actions (apply observer-flagged patches to canonical sources).
    Improver {
        #[command(subcommand)]
        command: SessionImproverCommand,
    },
    /// Signal management.
    Signal {
        #[command(subcommand)]
        command: SessionSignalCommand,
    },
    /// Unified managed terminal and Codex thread operations.
    Agents {
        #[command(subcommand)]
        command: SessionAgentsCommand,
    },
    /// Observe all agents in a session.
    Observe(SessionObserveArgs),
    /// Run a one-shot agent liveness reconciliation.
    Sync(SessionSyncArgs),
    /// Voluntarily leave a session.
    Leave(SessionLeaveArgs),
    /// Set or update a session title.
    Title(SessionTitleArgs),
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
    /// Return a task to the reviewer queue.
    SubmitForReview(TaskSubmitForReviewArgs),
    /// Claim an awaiting-review task for review.
    ClaimReview(TaskClaimReviewArgs),
    /// Submit a review verdict.
    SubmitReview(TaskSubmitReviewArgs),
    /// Respond to review feedback as the worker.
    RespondReview(TaskRespondReviewArgs),
    /// Leader arbitration on an exhausted review cycle.
    Arbitrate(TaskArbitrateArgs),
}

/// Session improver subcommands.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum SessionImproverCommand {
    /// Apply a patch to a canonical skill/plugin source.
    Apply(SessionImproverApplyArgs),
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
            Self::Adopt(args) => args.execute(context),
            Self::Start(args) => args.execute(context),
            Self::Join(args) => args.execute(context),
            Self::End(args) => args.execute(context),
            Self::Assign(args) => args.execute(context),
            Self::Remove(args) => args.execute(context),
            Self::TransferLeader(args) => args.execute(context),
            Self::RecoverLeader(args) => args.execute(context),
            Self::Task { command } => command.execute(context),
            Self::Improver { command } => command.execute(context),
            Self::Signal { command } => command.execute(context),
            Self::Agents { command } => command.execute(context),
            Self::Observe(args) => args.execute(context),
            Self::Sync(args) => args.execute(context),
            Self::Leave(args) => args.execute(context),
            Self::Title(args) => args.execute(context),
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
            Self::SubmitForReview(args) => args.execute(context),
            Self::ClaimReview(args) => args.execute(context),
            Self::SubmitReview(args) => args.execute(context),
            Self::RespondReview(args) => args.execute(context),
            Self::Arbitrate(args) => args.execute(context),
        }
    }
}

impl Execute for SessionImproverCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Apply(args) => args.execute(context),
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
