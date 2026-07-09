use crate::daemon::db::DaemonDb;
use crate::daemon::http::DaemonHttpAuthMode;
use crate::daemon::remote_acme::{RemoteAcmeRuntimePlan, build_remote_acme_runtime_plan};
use crate::daemon::service::DaemonServeConfig;
use crate::errors::{CliError, CliErrorKind};

use super::control::adopt_daemon_root_for_transport_command;
use super::remote::{DaemonRemoteServeArgs, open_remote_daemon_db};

#[derive(Debug, Clone)]
pub(crate) struct RemoteDaemonServeExecutionPlan {
    pub(crate) service_config: DaemonServeConfig,
    pub(crate) acme_plan: RemoteAcmeRuntimePlan,
}

pub(super) fn execute_remote_serve(args: &DaemonRemoteServeArgs) -> Result<i32, CliError> {
    adopt_daemon_root_for_transport_command("daemon-remote-serve");
    let db = open_remote_daemon_db()?;
    let plan = build_remote_serve_execution_plan(args, &db)?;
    run_remote_serve_plan(&plan)
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
    let acme_state = db.load_remote_acme_runtime_state()?;
    let acme_plan = build_remote_acme_runtime_plan(&remote_config, &acme_state)
        .map_err(|error| CliError::from(CliErrorKind::workflow_parse(error.to_string())))?;
    let service_config = DaemonServeConfig {
        host: remote_config.host,
        port: remote_config.https_port,
        auth_mode: DaemonHttpAuthMode::Remote,
        remote_domain: Some(remote_config.domain),
        ..DaemonServeConfig::default()
    };
    Ok(RemoteDaemonServeExecutionPlan {
        service_config,
        acme_plan,
    })
}

fn run_remote_serve_plan(plan: &RemoteDaemonServeExecutionPlan) -> Result<i32, CliError> {
    Err(CliErrorKind::workflow_parse(format!(
        "remote daemon HTTPS listener is not implemented yet; TLS preflight passed for {} on {}:{}",
        plan.acme_plan.public_https_origin(),
        plan.service_config.host,
        plan.service_config.port
    ))
    .into())
}
