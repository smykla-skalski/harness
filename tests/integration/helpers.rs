// Shared test helper utilities for integration tests.
// Delegates to harness-testkit builders for fixture construction.

#![allow(dead_code)]

use std::borrow::Borrow;
use std::sync::Mutex;

use harness::app::cli::{self, Command, CreateCommand, RunCommand, SetupCommand};
use harness::create::{ApprovalBeginArgs, CreateBeginArgs, CreateSaveArgs, CreateValidateArgs};
use harness::errors::CliError;
use harness::run::{
    ApiArgs, ApplyArgs, CaptureArgs, CloseoutArgs, EnvoyArgs, KumaArgs, KumaCommand, KumactlArgs,
    PreflightArgs, RecordArgs, ReportArgs, ServiceArgs, ValidateArgs,
};
use harness::setup::{
    ClusterArgs, GatewayArgs, KumaSetupArgs, KumaSetupCommand, PreCompactArgs, SessionStartArgs,
    SessionStopArgs,
};

// Re-export everything from the testkit so integration tests can use
// `helpers::write_suite`, `helpers::make_bash_payload`, etc. unchanged.
pub use harness_testkit::*;

/// Global lock for tests that modify the process environment via `with_env_vars`.
///
/// All integration test modules that set PATH (or other env vars) must acquire
/// this lock so that concurrent tests never observe a partially-modified
/// environment. Per-module locks are insufficient because Rust runs tests from
/// different modules on the same thread pool.
pub static ENV_LOCK: Mutex<()> = Mutex::new(());

pub fn run_command(command: impl Borrow<Command>) -> Result<i32, CliError> {
    cli::dispatch(command.borrow())
}

pub fn run_cmd(command: RunCommand) -> Command {
    Command::Run { command }
}

pub fn setup_cmd(command: SetupCommand) -> Command {
    Command::Setup { command }
}

pub fn create_cmd(command: CreateCommand) -> Command {
    Command::Create { command }
}

pub fn api_cmd(args: ApiArgs) -> Command {
    run_cmd(RunCommand::Kuma(KumaArgs {
        command: KumaCommand::Api(args),
    }))
}

pub fn apply_cmd(args: ApplyArgs) -> Command {
    run_cmd(RunCommand::Apply(args))
}

pub fn create_begin_cmd(args: CreateBeginArgs) -> Command {
    create_cmd(CreateCommand::Begin(args))
}

pub fn create_save_cmd(args: CreateSaveArgs) -> Command {
    create_cmd(CreateCommand::Save(args))
}

pub fn create_validate_cmd(args: CreateValidateArgs) -> Command {
    create_cmd(CreateCommand::Validate(args))
}

pub fn approval_begin_cmd(args: ApprovalBeginArgs) -> Command {
    create_cmd(CreateCommand::ApprovalBegin(args))
}

pub fn capabilities_cmd() -> Command {
    setup_cmd(SetupCommand::Capabilities)
}

pub fn capture_cmd(args: CaptureArgs) -> Command {
    run_cmd(RunCommand::Capture(args))
}

pub fn closeout_cmd(args: CloseoutArgs) -> Command {
    run_cmd(RunCommand::Closeout(args))
}

pub fn cluster_cmd(args: ClusterArgs) -> Command {
    setup_cmd(SetupCommand::Kuma(KumaSetupArgs {
        command: KumaSetupCommand::Cluster(args),
    }))
}

pub fn envoy_cmd(args: EnvoyArgs) -> Command {
    run_cmd(RunCommand::Envoy(args))
}

pub fn gateway_cmd(args: GatewayArgs) -> Command {
    setup_cmd(SetupCommand::Gateway(args))
}

pub fn kumactl_cmd(args: KumactlArgs) -> Command {
    run_cmd(RunCommand::Kuma(KumaArgs {
        command: KumaCommand::Cli(args),
    }))
}

pub fn pre_compact_cmd(args: PreCompactArgs) -> Command {
    setup_cmd(SetupCommand::PreCompact(args))
}

pub fn preflight_cmd(args: PreflightArgs) -> Command {
    run_cmd(RunCommand::Preflight(args))
}

pub fn record_cmd(args: RecordArgs) -> Command {
    run_cmd(RunCommand::Record(args))
}

pub fn report_cmd(args: ReportArgs) -> Command {
    run_cmd(RunCommand::Report(args))
}

pub fn service_cmd(args: ServiceArgs) -> Command {
    run_cmd(RunCommand::Kuma(KumaArgs {
        command: KumaCommand::Service(args),
    }))
}

pub fn session_start_cmd(args: SessionStartArgs) -> Command {
    setup_cmd(SetupCommand::SessionStart(args))
}

pub fn session_stop_cmd(args: SessionStopArgs) -> Command {
    setup_cmd(SetupCommand::SessionStop(args))
}

pub fn validate_cmd(args: ValidateArgs) -> Command {
    run_cmd(RunCommand::Validate(args))
}

pub trait CommandExt {
    fn execute(self) -> Result<i32, CliError>;
}

impl CommandExt for Command {
    fn execute(self) -> Result<i32, CliError> {
        run_command(self)
    }
}
