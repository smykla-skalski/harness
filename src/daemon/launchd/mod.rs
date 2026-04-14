use std::env::current_dir;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};

use super::state;

mod operations;
mod status;
mod support;
#[cfg(test)]
mod tests;

pub const LAUNCH_AGENT_LABEL: &str = "io.harness.daemon";
const LEGACY_LAUNCH_AGENT_LABEL: &str = "io.harness.monitor.daemon";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LaunchAgentStatus {
    pub installed: bool,
    pub loaded: bool,
    pub label: String,
    pub path: String,
    pub domain_target: String,
    pub service_target: String,
    pub state: Option<String>,
    pub pid: Option<i32>,
    pub last_exit_status: Option<i32>,
    pub status_error: Option<String>,
}

#[must_use]
pub fn render_launch_agent_plist(binary_path: &Path) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{binary}</string>
    <string>daemon</string>
    <string>serve</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>WorkingDirectory</key>
  <string>{cwd}</string>
  <key>StandardOutPath</key>
  <string>{stdout}</string>
  <key>StandardErrorPath</key>
  <string>{stderr}</string>
</dict>
</plist>
"#,
        label = LAUNCH_AGENT_LABEL,
        binary = binary_path.display(),
        cwd = current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .display(),
        stdout = state::daemon_root().join("launchd.stdout.log").display(),
        stderr = state::daemon_root().join("launchd.stderr.log").display(),
    )
}

/// Boot out the user `LaunchAgent` runtime if it is currently loaded.
///
/// When `sandboxed` is `true`, returns a `SandboxFeatureDisabled` error
/// immediately without touching `launchctl`.
///
/// # Errors
/// Returns `CliError` when sandbox mode is on, or when `launchctl bootout`
/// fails for a reason other than a missing service.
pub fn bootout_launch_agent(sandboxed: bool) -> Result<bool, CliError> {
    if sandboxed {
        return Err(CliError::from(CliErrorKind::sandbox_feature_disabled(
            "launch-agent-bootout",
        )));
    }
    operations::best_effort_bootout(&support::run_launchctl)
}

/// Restart the installed user `LaunchAgent` without rewriting the plist.
///
/// When `sandboxed` is `true`, returns a `SandboxFeatureDisabled` error
/// immediately without touching `launchctl`.
///
/// # Errors
/// Returns `CliError` when sandbox mode is on, when the plist is missing,
/// or when `launchctl` operations fail.
pub fn restart_launch_agent(sandboxed: bool) -> Result<(), CliError> {
    if sandboxed {
        return Err(CliError::from(CliErrorKind::sandbox_feature_disabled(
            "launch-agent-restart",
        )));
    }
    operations::restart_launch_agent_with(&support::run_launchctl)
}

/// Install the user `LaunchAgent` plist for the harness daemon.
///
/// When `sandboxed` is `true`, returns a `SandboxFeatureDisabled` error
/// immediately without writing the plist or calling `launchctl`.
///
/// # Errors
/// Returns `CliError` when sandbox mode is on, or on filesystem failures.
pub fn install_launch_agent(sandboxed: bool, binary_path: &Path) -> Result<PathBuf, CliError> {
    if sandboxed {
        return Err(CliError::from(CliErrorKind::sandbox_feature_disabled(
            "launch-agent-install",
        )));
    }
    operations::install_launch_agent_with(binary_path, &support::run_launchctl)
}

/// Remove the user `LaunchAgent` plist if present.
///
/// When `sandboxed` is `true`, returns a `SandboxFeatureDisabled` error
/// immediately without touching the filesystem or `launchctl`.
///
/// # Errors
/// Returns `CliError` when sandbox mode is on, or on filesystem failures.
pub fn remove_launch_agent(sandboxed: bool) -> Result<bool, CliError> {
    if sandboxed {
        return Err(CliError::from(CliErrorKind::sandbox_feature_disabled(
            "launch-agent-remove",
        )));
    }
    operations::remove_launch_agent_with(&support::run_launchctl)
}

#[must_use]
pub fn launch_agent_status() -> LaunchAgentStatus {
    status::launch_agent_status_with(&support::run_launchctl)
}
