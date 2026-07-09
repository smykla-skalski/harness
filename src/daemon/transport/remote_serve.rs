use std::thread;

use crate::daemon::db::DaemonDb;
use crate::daemon::remote_acme::{RemoteAcmeRuntimePlan, build_remote_acme_runtime_plan};
use crate::daemon::service::{self, DaemonServeConfig};
use crate::errors::{CliError, CliErrorKind};
use crate::workspace::utc_now;
use tokio::runtime::{Handle, Runtime};

use super::control::adopt_daemon_root_for_transport_command;
use super::remote::{DaemonRemoteServeArgs, open_remote_daemon_db};

#[derive(Clone)]
pub(crate) struct RemoteDaemonServeExecutionPlan {
    pub(crate) service_config: DaemonServeConfig,
    pub(crate) acme_plan: RemoteAcmeRuntimePlan,
}

pub(super) fn execute_remote_serve(args: &DaemonRemoteServeArgs) -> Result<i32, CliError> {
    execute_remote_serve_with(args, open_remote_daemon_db, run_remote_serve_plan)
}

pub(crate) fn execute_remote_serve_with<OpenDb, Run>(
    args: &DaemonRemoteServeArgs,
    open_db: OpenDb,
    run_plan: Run,
) -> Result<i32, CliError>
where
    OpenDb: FnOnce() -> Result<DaemonDb, CliError>,
    Run: FnOnce(RemoteDaemonServeExecutionPlan) -> Result<i32, CliError>,
{
    adopt_daemon_root_for_transport_command("daemon-remote-serve");
    let db = open_db()?;
    let plan = build_remote_serve_execution_plan(args, &db)?;
    run_plan(plan)
}

/// Build the remote daemon serve execution plan from static CLI config and
/// persisted ACME runtime state.
///
/// # Errors
/// Returns [`CliError`] when remote config is invalid or persisted ACME TLS
/// state is incomplete.
pub(crate) fn build_remote_serve_execution_plan(
    args: &DaemonRemoteServeArgs,
    db: &DaemonDb,
) -> Result<RemoteDaemonServeExecutionPlan, CliError> {
    let remote_config = args.contract_config()?;
    db.record_remote_acme_serve_config(&remote_config, utc_now().as_str())?;
    let acme_state = db.load_remote_acme_runtime_state()?;
    let acme_plan = build_remote_acme_runtime_plan(&remote_config, &acme_state)
        .map_err(|error| CliError::from(CliErrorKind::workflow_parse(error.to_string())))?;
    let service_config = args.remote_auth_scaffold_config()?;
    Ok(RemoteDaemonServeExecutionPlan {
        service_config,
        acme_plan,
    })
}

fn run_remote_serve_plan(plan: RemoteDaemonServeExecutionPlan) -> Result<i32, CliError> {
    match remote_serve_runtime_mode() {
        RemoteServeRuntimeMode::ExistingTokioRuntime => run_remote_serve_plan_on_thread(plan),
        RemoteServeRuntimeMode::NewTokioRuntime => run_remote_serve_plan_on_runtime(plan),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RemoteServeRuntimeMode {
    ExistingTokioRuntime,
    NewTokioRuntime,
}

pub(crate) fn remote_serve_runtime_mode() -> RemoteServeRuntimeMode {
    if Handle::try_current().is_ok() {
        RemoteServeRuntimeMode::ExistingTokioRuntime
    } else {
        RemoteServeRuntimeMode::NewTokioRuntime
    }
}

fn run_remote_serve_plan_on_thread(plan: RemoteDaemonServeExecutionPlan) -> Result<i32, CliError> {
    thread::Builder::new()
        .name("harness-remote-daemon".to_string())
        .spawn(move || run_remote_serve_plan_on_runtime(plan))
        .map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "spawn remote daemon runtime thread: {error}"
            )))
        })?
        .join()
        .map_err(|_| {
            CliError::from(CliErrorKind::workflow_io(
                "remote daemon runtime thread panicked",
            ))
        })?
}

fn run_remote_serve_plan_on_runtime(plan: RemoteDaemonServeExecutionPlan) -> Result<i32, CliError> {
    let runtime = Runtime::new().map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "create remote daemon tokio runtime: {error}"
        )))
    })?;
    runtime.block_on(service::serve_remote_https(
        plan.service_config,
        plan.acme_plan,
    ))?;
    Ok(0)
}
