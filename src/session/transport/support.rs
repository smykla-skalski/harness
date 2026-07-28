use std::env;
use std::path::PathBuf;

use serde::Serialize;

use crate::daemon::client::DaemonClient;
use harness_daemon_client::ClientError;
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_protocol::agent::HookAgent;
use harness_workspace::command_context::resolve_project_dir as resolve_project_path;

pub(super) fn resolve_project_dir(hint: Option<&str>) -> String {
    let path = hint.filter(|value| !value.trim().is_empty()).map_or_else(
        || env::current_dir().unwrap_or_else(|_| ".".into()),
        PathBuf::from,
    );
    resolve_project_path(path.to_str())
        .to_string_lossy()
        .to_string()
}

pub(super) fn print_json<T: Serialize>(value: &T) -> Result<(), CliError> {
    let json = serde_json::to_string_pretty(value)
        .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
    println!("{json}");
    Ok(())
}

pub(super) fn daemon_client() -> Result<DaemonClient, CliError> {
    DaemonClient::try_connect().ok_or_else(|| {
        CliErrorKind::workflow_io(
            "harness daemon is not running; start the daemon before using managed TUIs",
        )
        .into()
    })
}

/// Shared error mapper for command surfaces that call the leaf
/// `harness-daemon-client` directly instead of this module's `daemon_client()`,
/// which returns the unrelated root-facade client of the same type name.
pub(super) fn daemon_client_error(operation: &str, error: &ClientError) -> CliError {
    CliError::from(CliErrorKind::workflow_io(format!(
        "daemon {operation}: {error}"
    )))
}

pub(super) fn capability_args(values: &[String]) -> Vec<String> {
    values
        .iter()
        .flat_map(|value| value.split(','))
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
        .collect()
}

pub(super) fn agent_to_str(agent: HookAgent) -> &'static str {
    match agent {
        HookAgent::Claude => "claude",
        HookAgent::Codex => "codex",
        HookAgent::Gemini => "gemini",
        HookAgent::Copilot => "copilot",
        HookAgent::Vibe => "vibe",
        HookAgent::OpenCode => "opencode",
    }
}
