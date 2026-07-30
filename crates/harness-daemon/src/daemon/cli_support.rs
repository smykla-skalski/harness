//! Small CLI-output and root-adoption helpers shared by `harness-daemon`'s own
//! command dispatch (`harness-daemon-cli`, an ordinary downstream dependency
//! of this crate) and the remote-daemon subcommand tree
//! (`daemon::transport`, still inside this crate). Neither caller depends on
//! the other, so these live here instead of in either one - the same reason
//! `remote_redaction.rs` moved to `harness-kernel` rather than into either
//! side of the remote-trust split.

use harness_kernel::errors::{CliError, CliErrorKind};

use super::discovery::{self, AdoptionOutcome};

#[expect(
    clippy::cognitive_complexity,
    reason = "explicit outcome-specific logging keeps daemon root adoption auditable"
)]
pub fn adopt_daemon_root_for_transport_command(command: &'static str) {
    match discovery::adopt_running_daemon_root() {
        AdoptionOutcome::AlreadyCoherent { root } => {
            tracing::debug!(
                command,
                root = %root.display(),
                "daemon: root already coherent"
            );
        }
        AdoptionOutcome::Adopted { from, to } => {
            tracing::info!(
                command,
                from = %from.display(),
                to = %to.display(),
                "daemon: adopted running daemon root"
            );
        }
        AdoptionOutcome::NoRunningDaemon { default_root } => {
            tracing::debug!(
                command,
                default_root = %default_root.display(),
                "daemon: no running daemon found during root adoption"
            );
        }
    }
}

/// # Errors
/// Returns [`CliError`] when `json` is set and the response cannot be serialized.
pub fn print_daemon_control_response(
    response: &harness_protocol::daemon::summaries::DaemonControlResponse,
    json: bool,
) -> Result<(), CliError> {
    if json {
        print_json(response)
    } else {
        println!("{}", response.status);
        Ok(())
    }
}

/// # Errors
/// Returns [`CliError`] when `value` cannot be serialized to JSON.
pub fn print_json<T: serde::Serialize>(value: &T) -> Result<(), CliError> {
    let json = serde_json::to_string_pretty(value)
        .map_err(|error| CliErrorKind::workflow_serialize(error.to_string()))?;
    println!("{json}");
    Ok(())
}
