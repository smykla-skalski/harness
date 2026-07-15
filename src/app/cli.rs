use std::thread;
use std::time::Duration;

use clap::{Parser, Subcommand};
use tracing::field::{Empty, display};

use crate::app::command_context::{AppContext, Execute};
use crate::create::{
    ApprovalBeginArgs, CreateBeginArgs, CreateResetArgs, CreateSaveArgs, CreateShowArgs,
    CreateValidateArgs,
};
use crate::errors::{CliError, CliErrorKind};
use crate::observe::ObserveArgs;
use crate::run::{
    ApplyArgs, CaptureArgs, CloseoutArgs, ClusterCheckArgs, DiffArgs, DoctorArgs, EnvoyArgs,
    FinishArgs, InitArgs, KumaArgs, LogsArgs, PreflightArgs, RecordArgs, RepairArgs, ReportArgs,
    RestartNamespaceArgs, ResumeArgs, RunnerStateArgs, StartArgs, StatusArgs, TaskArgs,
    ValidateArgs,
};
use crate::session::transport::SessionCommand;
use crate::setup::{BootstrapArgs, CapabilitiesArgs, GatewayArgs, KumaSetupArgs, SecretsArgs};
use crate::task_board::transport::TaskBoardCommand;
use crate::telemetry::{current_trace_id, runtime_service_from_current_process};

use super::worker_routes::{BridgeRoute, DaemonRoute};

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
    Kuma(Box<KumaSetupArgs>),
    Gateway(GatewayArgs),
    Capabilities(CapabilitiesArgs),
    /// Inspect task-board secret state in your macOS Keychain.
    Secrets(SecretsArgs),
}

/// Top-level commands.
#[derive(Debug, Subcommand)]
#[non_exhaustive]
pub enum Command {
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

    /// Observe and classify harness-managed agent session logs.
    Observe(Box<ObserveArgs>),

    /// Multi-agent session orchestration.
    Session {
        #[command(subcommand)]
        command: SessionCommand,
    },

    /// Cross-project task board.
    TaskBoard {
        #[command(subcommand)]
        command: Box<TaskBoardCommand>,
    },

    /// Local daemon for the Harness app.
    Daemon {
        #[command(subcommand)]
        command: DaemonRoute,
    },

    /// Supervise host capabilities for sandboxed Codex and terminal agent flows.
    Bridge {
        #[command(subcommand)]
        command: BridgeRoute,
    },
}

/// Dispatch a parsed command to its owning subsystem.
///
/// # Errors
/// Returns `CliError` when the selected command fails.
pub fn dispatch(command: &Command) -> Result<i32, CliError> {
    if !matches!(command, Command::Daemon { .. } | Command::Bridge { .. }) {
        super::run_startup_migrations();
    }

    let ctx = AppContext::production();
    match command {
        Command::Run { command } => dispatch_run(&ctx, command),
        Command::Create { command } => dispatch_create(&ctx, command),
        Command::Setup { command } => dispatch_setup(&ctx, command),
        Command::Observe(args) => args.execute(&ctx),
        Command::Session { command } => command.execute(&ctx),
        Command::TaskBoard { command } => command.execute(&ctx),
        Command::Daemon { .. } => delegate("daemon", "harness-daemon"),
        Command::Bridge { .. } => delegate("bridge", "harness-bridge"),
    }
}

fn command_name(command: &Command) -> &'static str {
    match command {
        Command::Run { .. } => "run",
        Command::Create { .. } => "create",
        Command::Setup { .. } => "setup",
        Command::Observe(_) => "observe",
        Command::Session { .. } => "session",
        Command::TaskBoard { .. } => "task-board",
        Command::Daemon { .. } => "daemon",
        Command::Bridge { .. } => "bridge",
    }
}

fn delegate(route: &str, worker: &str) -> Result<i32, CliError> {
    let args = harness_command::routed_args(route).map_err(|error| worker_error(&error))?;
    harness_command::exec_worker(worker, env!("CARGO_PKG_VERSION"), args)
        .map_err(|error| worker_error(&error))
}

fn worker_error(error: &harness_command::WorkerError) -> CliError {
    CliErrorKind::workflow_io(error.to_string()).into()
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
        SetupCommand::Kuma(args) => args.execute(ctx),
        SetupCommand::Gateway(args) => args.execute(ctx),
        SetupCommand::Capabilities(args) => args.execute(ctx),
        SetupCommand::Secrets(args) => args.execute(ctx),
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
    dispatch(command)
}

#[cfg(test)]
#[path = "cli/tests.rs"]
mod tests;
