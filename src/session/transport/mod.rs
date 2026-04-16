use clap::Subcommand;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::CliError;

mod attach;
mod recover;
mod session_commands;
mod signal;
mod support;
mod task;
mod tui;

pub use attach::TuiAttachArgs;
pub use recover::SessionRecoverLeaderArgs;
pub use session_commands::{
    SessionAssignArgs, SessionEndArgs, SessionJoinArgs, SessionLeaveArgs, SessionListArgs,
    SessionObserveArgs, SessionRemoveArgs, SessionStartArgs, SessionStatusArgs, SessionSyncArgs,
    SessionTitleArgs, SessionTransferLeaderArgs,
};
pub use signal::{SignalListArgs, SignalSendArgs};
pub use task::{TaskAssignArgs, TaskCheckpointArgs, TaskCreateArgs, TaskListArgs, TaskUpdateArgs};
pub use tui::{
    TuiInputArgs, TuiKeyArg, TuiListArgs, TuiResizeArgs, TuiShowArgs, TuiStartArgs, TuiStopArgs,
};

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
    /// Recover a leaderless degraded session with a managed leader TUI.
    RecoverLeader(SessionRecoverLeaderArgs),
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
    /// Managed interactive agent TUI processes.
    Tui {
        #[command(subcommand)]
        command: SessionTuiCommand,
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

/// Session TUI subcommands.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum SessionTuiCommand {
    /// Start an agent runtime in a managed PTY.
    Start(TuiStartArgs),
    /// Attach to an active managed TUI process.
    Attach(TuiAttachArgs),
    /// List managed TUIs for a session.
    List(TuiListArgs),
    /// Show the latest snapshot for one managed TUI.
    Show(TuiShowArgs),
    /// Send keyboard-like input to an active managed TUI.
    Input(TuiInputArgs),
    /// Resize an active managed TUI.
    Resize(TuiResizeArgs),
    /// Stop an active managed TUI.
    Stop(TuiStopArgs),
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
            Self::RecoverLeader(args) => args.execute(context),
            Self::Task { command } => command.execute(context),
            Self::Signal { command } => command.execute(context),
            Self::Tui { command } => command.execute(context),
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

impl Execute for SessionTuiCommand {
    fn execute(&self, context: &AppContext) -> Result<i32, CliError> {
        match self {
            Self::Start(args) => args.execute(context),
            Self::Attach(args) => args.execute(context),
            Self::List(args) => args.execute(context),
            Self::Show(args) => args.execute(context),
            Self::Input(args) => args.execute(context),
            Self::Resize(args) => args.execute(context),
            Self::Stop(args) => args.execute(context),
        }
    }
}
