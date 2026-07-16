use std::io::{Read as _, stdin};
use std::process::ExitCode;
use std::thread;
use std::time::Duration;

use clap::{Args, Parser, Subcommand};
use harness_hook::agents::service;
use harness_hook::app::resolve_project_dir;
use harness_hook::errors::{self, CliError, CliErrorKind};
use harness_hook::hooks::{
    AuditTurnArgs, HookAgent, HookCommand, SessionStartHookOutput, run_hook_command,
};
use harness_hook::infra::exec::RUNTIME;
use harness_hook::kernel::skills::SKILL_NAMES;
use harness_hook::setup::PreCompactArgs;
use harness_hook::telemetry::{RuntimeService, TelemetryGuard, init_tracing_subscriber_for};

#[derive(Debug, Parser)]
#[command(name = "harness-hook", version, about = "Harness lifecycle hooks")]
struct Cli {
    /// Seconds to wait before executing the command.
    #[arg(long, default_value = "0", global = true)]
    delay: f64,
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    ToolGuard(HookInvocationArgs),
    GuardStop(HookInvocationArgs),
    ToolResult(HookInvocationArgs),
    AuditTurn(AuditTurnInvocationArgs),
    ToolFailure(HookInvocationArgs),
    ContextAgent(HookInvocationArgs),
    ValidateAgent(HookInvocationArgs),
    SessionStart(AgentSessionArgs),
    SessionStop(AgentSessionArgs),
    PromptSubmit(AgentSessionArgs),
    PreCompact(PreCompactArgs),
}

#[derive(Debug, Args)]
struct HookInvocationArgs {
    /// Hook transport/agent protocol.
    #[arg(long, value_enum)]
    agent: HookAgent,
    /// Harness skill owning the hook.
    #[arg(long, value_parser = clap::builder::PossibleValuesParser::new(SKILL_NAMES))]
    skill: String,
}

#[derive(Debug, Args)]
struct AuditTurnInvocationArgs {
    #[command(flatten)]
    hook: HookInvocationArgs,
    /// Raw Codex notify payload passed as `argv[1]`.
    #[arg(hide = true)]
    payload: Option<String>,
}

#[derive(Debug, Clone, Args)]
struct AgentSessionArgs {
    /// Hook transport/agent protocol.
    #[arg(long, value_enum)]
    agent: HookAgent,
    /// Project directory associated with the runtime session.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    project_dir: Option<String>,
    /// Native runtime session identifier.
    #[arg(long)]
    session_id: Option<String>,
}

fn main() -> ExitCode {
    let telemetry_guard = match init_telemetry() {
        Ok(guard) => guard,
        Err(error) => return render_error(&error),
    };
    let cli = Cli::parse();
    if cli.delay > 0.0 {
        thread::sleep(Duration::from_secs_f64(cli.delay));
    }
    let result = execute(cli.command);
    drop(telemetry_guard);
    match result {
        Ok(code) => exit_code(code),
        Err(error) => render_error(&error),
    }
}

fn execute(command: Command) -> Result<i32, errors::CliError> {
    match command {
        Command::ToolGuard(args) => Ok(run_hook(&args, &HookCommand::ToolGuard)),
        Command::GuardStop(args) => Ok(run_hook(&args, &HookCommand::GuardStop)),
        Command::ToolResult(args) => Ok(run_hook(&args, &HookCommand::ToolResult)),
        Command::AuditTurn(args) => Ok(run_hook(
            &args.hook,
            &HookCommand::AuditTurn(AuditTurnArgs {
                payload: args.payload,
            }),
        )),
        Command::ToolFailure(args) => Ok(run_hook(&args, &HookCommand::ToolFailure)),
        Command::ContextAgent(args) => Ok(run_hook(&args, &HookCommand::ContextAgent)),
        Command::ValidateAgent(args) => Ok(run_hook(&args, &HookCommand::ValidateAgent)),
        Command::SessionStart(args) => session_start(args),
        Command::SessionStop(args) => session_stop(args),
        Command::PromptSubmit(args) => prompt_submit(args),
        Command::PreCompact(args) => harness_hook::setup::pre_compact(args.project_dir.as_deref()),
    }
}

fn session_start(args: AgentSessionArgs) -> Result<i32, CliError> {
    let project_dir = resolve_project_dir(args.project_dir.as_deref());
    if let Some(context) = RUNTIME.block_on(service::session_start(
        args.agent,
        project_dir,
        args.session_id,
    ))? {
        let output = SessionStartHookOutput::from_additional_context(&context);
        let json = output.to_json().map_err(|error| {
            CliError::from(CliErrorKind::workflow_serialize(format!(
                "session-start output: {error}"
            )))
        })?;
        print!("{json}");
    }
    Ok(0)
}

fn session_stop(args: AgentSessionArgs) -> Result<i32, CliError> {
    let project_dir = resolve_project_dir(args.project_dir.as_deref());
    RUNTIME.block_on(service::session_stop(
        args.agent,
        project_dir,
        args.session_id,
    ))?;
    Ok(0)
}

fn prompt_submit(args: AgentSessionArgs) -> Result<i32, CliError> {
    let project_dir = resolve_project_dir(args.project_dir.as_deref());
    let mut payload = Vec::new();
    stdin().read_to_end(&mut payload).map_err(|error| {
        CliError::from(CliErrorKind::hook_payload_invalid(format!(
            "failed to read stdin: {error}"
        )))
    })?;
    RUNTIME.block_on(service::prompt_submit(
        args.agent,
        project_dir,
        args.session_id,
        payload,
    ))?;
    Ok(0)
}

fn init_telemetry() -> Result<TelemetryGuard, CliError> {
    init_tracing_subscriber_for(RuntimeService::Hook).map_err(|error| {
        CliErrorKind::workflow_io(format!("initialize hook telemetry: {error}")).into()
    })
}

fn run_hook(args: &HookInvocationArgs, command: &HookCommand) -> i32 {
    run_hook_command(args.agent, &args.skill, command)
}

fn render_error(error: &errors::CliError) -> ExitCode {
    eprintln!("{}", errors::render_error(error));
    exit_code(error.exit_code())
}

fn exit_code(code: i32) -> ExitCode {
    ExitCode::from(u8::try_from(code).unwrap_or(1))
}
