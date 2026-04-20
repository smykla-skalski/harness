use std::thread;
use std::time::Duration;

use clap::{Parser, Subcommand};
use tracing::field::{Empty, display};

use crate::agents::transport::AgentsCommand;
use crate::app::command_context::{AppContext, Execute};
use crate::create::{
    ApprovalBeginArgs, CreateBeginArgs, CreateResetArgs, CreateSaveArgs, CreateShowArgs,
    CreateValidateArgs,
};
use crate::daemon::bridge::BridgeCommand;
use crate::daemon::transport::DaemonCommand;
use crate::errors::CliError;
use crate::hooks::{self, HookArgs};
use crate::mcp::McpCommand;
use crate::observe::ObserveArgs;
use crate::run::{
    ApplyArgs, CaptureArgs, CloseoutArgs, ClusterCheckArgs, DiffArgs, DoctorArgs, EnvoyArgs,
    FinishArgs, InitArgs, KumaArgs, LogsArgs, PreflightArgs, RecordArgs, RepairArgs, ReportArgs,
    RestartNamespaceArgs, ResumeArgs, RunnerStateArgs, StartArgs, StatusArgs, TaskArgs,
    ValidateArgs,
};
use crate::session::transport::SessionCommand;
use crate::setup::{
    AgentsSetupCommand, BootstrapArgs, CapabilitiesArgs, GatewayArgs, KumaSetupArgs,
    PreCompactArgs, SessionStartArgs, SessionStopArgs,
};
use crate::telemetry::{current_trace_id, runtime_service_from_current_process};

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
    Doctor(DoctorArgs),
    Repair(RepairArgs),
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
    Agents {
        #[command(subcommand)]
        command: AgentsSetupCommand,
    },
    Kuma(Box<KumaSetupArgs>),
    Gateway(GatewayArgs),
    Capabilities(CapabilitiesArgs),
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
        command: Box<RunCommand>,
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

    /// Shared harness-managed agent lifecycle commands.
    Agents {
        #[command(subcommand)]
        command: AgentsCommand,
    },

    /// Handle session start hook.
    #[command(hide = true)]
    SessionStart(SessionStartArgs),

    /// Handle session stop cleanup.
    #[command(hide = true)]
    SessionStop(SessionStopArgs),

    /// Save compact handoff before compaction.
    #[command(hide = true)]
    PreCompact(PreCompactArgs),

    /// Observe and classify harness-managed agent session logs.
    Observe(Box<ObserveArgs>),

    /// Multi-agent session orchestration.
    Session {
        #[command(subcommand)]
        command: SessionCommand,
    },

    /// Local daemon for the Harness app.
    Daemon {
        #[command(subcommand)]
        command: DaemonCommand,
    },

    /// Supervise host capabilities for sandboxed Codex and terminal agent flows.
    Bridge {
        #[command(subcommand)]
        command: BridgeCommand,
    },

    /// Model Context Protocol server for driving the Harness Monitor app.
    Mcp {
        #[command(subcommand)]
        command: McpCommand,
    },
}

/// Dispatch a parsed command to its owning subsystem.
///
/// # Errors
/// Returns `CliError` when the selected command fails.
pub fn dispatch(command: &Command) -> Result<i32, CliError> {
    #[cfg(target_os = "macos")]
    {
        use crate::sandbox::migration::run_startup_migration;
        run_startup_migration();
    }

    let ctx = AppContext::production();
    match command {
        Command::Hook(_) => unreachable!("hooks are handled separately"),
        Command::Run { command } => dispatch_run(&ctx, command),
        Command::Create { command } => dispatch_create(&ctx, command),
        Command::Setup { command } => dispatch_setup(&ctx, command),
        Command::Agents { command } => command.execute(&ctx),
        Command::SessionStart(args) => args.execute(&ctx),
        Command::SessionStop(args) => args.execute(&ctx),
        Command::PreCompact(args) => args.execute(&ctx),
        Command::Observe(args) => args.execute(&ctx),
        Command::Session { command } => command.execute(&ctx),
        Command::Daemon { command } => command.execute(&ctx),
        Command::Bridge { command } => command.execute(&ctx),
        Command::Mcp { command } => command.execute(&ctx),
    }
}

fn command_name(command: &Command) -> &'static str {
    match command {
        Command::Hook(_) => "hook",
        Command::Run { .. } => "run",
        Command::Create { .. } => "create",
        Command::Setup { .. } => "setup",
        Command::Agents { .. } => "agents",
        Command::SessionStart(_) => "session-start",
        Command::SessionStop(_) => "session-stop",
        Command::PreCompact(_) => "pre-compact",
        Command::Observe(_) => "observe",
        Command::Session { .. } => "session",
        Command::Daemon { .. } => "daemon",
        Command::Bridge { .. } => "bridge",
        Command::Mcp { .. } => "mcp",
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
        RunCommand::Doctor(args) => args.execute(ctx),
        RunCommand::Repair(args) => args.execute(ctx),
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
        SetupCommand::Agents { command } => command.execute(ctx),
        SetupCommand::Kuma(args) => args.execute(ctx),
        SetupCommand::Gateway(args) => args.execute(ctx),
        SetupCommand::Capabilities(args) => args.execute(ctx),
    }
}

/// Parse CLI arguments and run the appropriate command.
///
/// # Errors
/// Returns `CliError` on command failure. Hook errors are handled internally
/// and never surface as `CliError`.
pub fn run() -> Result<i32, CliError> {
    let cli = Cli::parse();
    apply_cli_delay(cli.delay);
    let service = runtime_service_from_current_process();
    let command_name = command_name(&cli.command);
    let span = tracing::info_span!(
        "harness.command",
        command = command_name,
        service = service.service_name(),
        delay_seconds = cli.delay,
        trace_id = Empty
    );
    let _guard = span.enter();
    record_trace_id(&span);
    command_exit_code(&cli.command)
}

fn apply_cli_delay(delay_seconds: f64) {
    if delay_seconds > 0.0 {
        thread::sleep(Duration::from_secs_f64(delay_seconds));
    }
}

fn record_trace_id(span: &tracing::Span) {
    if let Some(trace_id) = current_trace_id() {
        span.record("trace_id", display(trace_id));
    }
}

fn command_exit_code(command: &Command) -> Result<i32, CliError> {
    match command {
        Command::Hook(args) => Ok(hooks::run_hook_command(args.agent, &args.skill, &args.hook)),
        other => dispatch(other),
    }
}

#[cfg(test)]
#[path = "cli/tests.rs"]
mod tests;
