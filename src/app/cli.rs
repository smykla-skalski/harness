use std::thread;
use std::time::Duration;

use clap::{Parser, Subcommand};

use crate::app::command_context::{AppContext, Execute};
use crate::create::{
    ApprovalBeginArgs, CreateBeginArgs, CreateResetArgs, CreateSaveArgs, CreateShowArgs,
    CreateValidateArgs,
};
use crate::errors::CliError;
use crate::hooks::{self, HookArgs};
use crate::observe::ObserveArgs;
use crate::run::{
    ApplyArgs, CaptureArgs, CloseoutArgs, ClusterCheckArgs, DiffArgs, EnvoyArgs, FinishArgs,
    InitArgs, KumaArgs, LogsArgs, PreflightArgs, RecordArgs, ReportArgs, RestartNamespaceArgs,
    ResumeArgs, RunnerStateArgs, StartArgs, StatusArgs, TaskArgs, ValidateArgs,
};
use crate::setup;
use crate::setup::{
    BootstrapArgs, GatewayArgs, KumaSetupArgs, PreCompactArgs, SessionStartArgs, SessionStopArgs,
};

/// Harness CLI.
#[derive(Debug, Parser)]
#[command(name = "harness", version, about = "Harness CLI")]
pub struct Cli {
    /// Seconds to wait before executing the command. Accepts fractional
    /// values (e.g. 0.5). Use instead of `sleep N && harness ...`.
    #[arg(long, default_value = "0", global = true)]
    pub delay: f64,
    /// Subcommand to execute.
    #[command(subcommand)]
    pub command: Command,
}

/// Grouped `run` commands.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum RunCommand {
    Start(StartArgs),
    Init(InitArgs),
    Preflight(PreflightArgs),
    Capture(CaptureArgs),
    Record(RecordArgs),
    RestartNamespace(RestartNamespaceArgs),
    Apply(ApplyArgs),
    Validate(ValidateArgs),
    RunnerState(RunnerStateArgs),
    Resume(ResumeArgs),
    Finish(FinishArgs),
    Closeout(CloseoutArgs),
    Report(ReportArgs),
    Diff(DiffArgs),
    Envoy(EnvoyArgs),
    Kuma(KumaArgs),
    Status(StatusArgs),
    Logs(LogsArgs),
    ClusterCheck(ClusterCheckArgs),
    Task(TaskArgs),
}

/// Grouped `create` commands.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum CreateCommand {
    Begin(CreateBeginArgs),
    Save(CreateSaveArgs),
    Show(CreateShowArgs),
    Reset(CreateResetArgs),
    Validate(CreateValidateArgs),
    ApprovalBegin(ApprovalBeginArgs),
}

/// Grouped `setup` commands.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum SetupCommand {
    Bootstrap(BootstrapArgs),
    Kuma(KumaSetupArgs),
    Gateway(GatewayArgs),
    Capabilities,
}

/// Top-level commands.
#[derive(Debug, Subcommand)]
#[non_exhaustive]
pub enum Command {
    /// Run a harness hook for a skill.
    Hook(HookArgs),

    /// Suite:run commands grouped by domain.
    Run {
        #[command(subcommand)]
        command: RunCommand,
    },

    /// Suite:create commands grouped by domain.
    Create {
        #[command(subcommand)]
        command: CreateCommand,
    },

    /// Setup environment and cluster commands.
    Setup {
        #[command(subcommand)]
        command: SetupCommand,
    },

    /// Handle session start hook.
    SessionStart(SessionStartArgs),

    /// Handle session stop cleanup.
    SessionStop(SessionStopArgs),

    /// Save compact handoff before compaction.
    PreCompact(PreCompactArgs),

    /// Observe and classify Claude Code session logs.
    Observe(ObserveArgs),
}

/// Dispatch a parsed command to its owning subsystem.
///
/// # Errors
/// Returns `CliError` when the selected command fails.
pub fn dispatch(command: &Command) -> Result<i32, CliError> {
    let ctx = AppContext::production();
    match command {
        Command::Hook(_) => unreachable!("hooks are handled separately"),
        Command::Run { command } => dispatch_run(&ctx, command),
        Command::Create { command } => dispatch_create(&ctx, command),
        Command::Setup { command } => dispatch_setup(&ctx, command),
        Command::SessionStart(args) => args.execute(&ctx),
        Command::SessionStop(args) => args.execute(&ctx),
        Command::PreCompact(args) => args.execute(&ctx),
        Command::Observe(args) => args.execute(&ctx),
    }
}

fn dispatch_run(ctx: &AppContext, command: &RunCommand) -> Result<i32, CliError> {
    match command {
        RunCommand::Start(args) => args.execute(ctx),
        RunCommand::Init(args) => args.execute(ctx),
        RunCommand::Preflight(args) => args.execute(ctx),
        RunCommand::Capture(args) => args.execute(ctx),
        RunCommand::Record(args) => args.execute(ctx),
        RunCommand::RestartNamespace(args) => args.execute(ctx),
        RunCommand::Apply(args) => args.execute(ctx),
        RunCommand::Validate(args) => args.execute(ctx),
        RunCommand::RunnerState(args) => args.execute(ctx),
        RunCommand::Resume(args) => args.execute(ctx),
        RunCommand::Finish(args) => args.execute(ctx),
        RunCommand::Closeout(args) => args.execute(ctx),
        RunCommand::Report(args) => args.execute(ctx),
        RunCommand::Diff(args) => args.execute(ctx),
        RunCommand::Envoy(args) => args.execute(ctx),
        RunCommand::Kuma(args) => args.execute(ctx),
        RunCommand::Status(args) => args.execute(ctx),
        RunCommand::Logs(args) => args.execute(ctx),
        RunCommand::ClusterCheck(args) => args.execute(ctx),
        RunCommand::Task(args) => args.execute(ctx),
    }
}

fn dispatch_create(ctx: &AppContext, command: &CreateCommand) -> Result<i32, CliError> {
    match command {
        CreateCommand::Begin(args) => args.execute(ctx),
        CreateCommand::Save(args) => args.execute(ctx),
        CreateCommand::Show(args) => args.execute(ctx),
        CreateCommand::Reset(args) => args.execute(ctx),
        CreateCommand::Validate(args) => args.execute(ctx),
        CreateCommand::ApprovalBegin(args) => args.execute(ctx),
    }
}

fn dispatch_setup(ctx: &AppContext, command: &SetupCommand) -> Result<i32, CliError> {
    match command {
        SetupCommand::Bootstrap(args) => args.execute(ctx),
        SetupCommand::Kuma(args) => args.execute(ctx),
        SetupCommand::Gateway(args) => args.execute(ctx),
        SetupCommand::Capabilities => setup::capabilities(),
    }
}

/// Parse CLI arguments and run the appropriate command.
///
/// # Errors
/// Returns `CliError` on command failure. Hook errors are handled internally
/// and never surface as `CliError`.
pub fn run() -> Result<i32, CliError> {
    let cli = Cli::parse();
    if cli.delay > 0.0 {
        thread::sleep(Duration::from_secs_f64(cli.delay));
    }
    match cli.command {
        Command::Hook(ref args) => Ok(hooks::run_hook_command(args.agent, &args.skill, &args.hook)),
        ref other => dispatch(other),
    }
}

#[cfg(test)]
#[path = "cli/tests.rs"]
mod tests;
