use harness_daemon::app::{AppContext, Execute};
use harness_daemon::daemon::state;
use harness_kernel::errors::CliError;

use crate::{DaemonRemoteCommand, systemd_state};

/// Apply any systemd daemon-root override and execute a remote command.
///
/// # Errors
/// Returns an error when the unit name is invalid or command execution fails.
pub fn execute_remote_command(
    command: &DaemonRemoteCommand,
    systemd_unit: Option<&str>,
    context: &AppContext,
) -> Result<i32, CliError> {
    let _root_override = systemd_unit
        .map(systemd_state::daemon_root)
        .transpose()?
        .map(|root| state::ScopedDaemonRootOverride::set(Some(root)));
    command.execute(context)
}
