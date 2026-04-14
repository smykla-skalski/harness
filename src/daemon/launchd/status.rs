use std::path::Path;

use super::state;
use super::support::{
    CommandOutput, command_message, launchctl_reports_missing_service, launchd_domain_target,
    launchd_service_target_for,
};
use super::{LAUNCH_AGENT_LABEL, LEGACY_LAUNCH_AGENT_LABEL, LaunchAgentStatus};
use crate::errors::CliError;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(super) struct LaunchctlPrintStatus {
    pub(super) state: Option<String>,
    pub(super) pid: Option<i32>,
    pub(super) last_exit_status: Option<i32>,
}

pub(super) fn launch_agent_status_with<F>(runner: &F) -> LaunchAgentStatus
where
    F: Fn(&[String]) -> Result<CommandOutput, CliError>,
{
    let current_path = state::launch_agent_path();
    let mut status = launch_agent_status_template(LAUNCH_AGENT_LABEL, &current_path);
    if !cfg!(target_os = "macos") {
        status.status_error = Some("launchd is only supported on macOS".to_string());
        return status;
    }

    let current_status = inspect_launch_agent_status(LAUNCH_AGENT_LABEL, &current_path, runner);
    if current_status.loaded || current_status.installed || current_status.status_error.is_some() {
        return current_status;
    }

    let legacy_status = inspect_launch_agent_status(
        LEGACY_LAUNCH_AGENT_LABEL,
        &state::legacy_launch_agent_path(),
        runner,
    );
    if legacy_status.loaded || legacy_status.installed || legacy_status.status_error.is_some() {
        status.installed = legacy_status.installed;
        status.loaded = legacy_status.loaded;
        status.state = legacy_status.state;
        status.pid = legacy_status.pid;
        status.last_exit_status = legacy_status.last_exit_status;
        status.status_error = legacy_status.status_error;
    }

    status
}

fn launch_agent_status_template(label: &str, path: &Path) -> LaunchAgentStatus {
    let domain_target = launchd_domain_target();
    let service_target = launchd_service_target_for(label);
    LaunchAgentStatus {
        installed: path.is_file(),
        loaded: false,
        label: label.to_string(),
        path: path.display().to_string(),
        domain_target,
        service_target,
        state: None,
        pid: None,
        last_exit_status: None,
        status_error: None,
    }
}

fn inspect_launch_agent_status<F>(label: &str, path: &Path, runner: &F) -> LaunchAgentStatus
where
    F: Fn(&[String]) -> Result<CommandOutput, CliError>,
{
    let mut status = launch_agent_status_template(label, path);
    let args = vec!["print".to_string(), launchd_service_target_for(label)];
    match runner(&args) {
        Ok(output) => apply_launchctl_status(&mut status, &output),
        Err(error) => {
            status.status_error = Some(error.to_string());
        }
    }
    status
}

fn apply_launchctl_status(status: &mut LaunchAgentStatus, output: &CommandOutput) {
    if output.exit_code == 0 {
        let parsed = parse_launchctl_print(&output.stdout);
        status.loaded = true;
        status.state = parsed.state;
        status.pid = parsed.pid;
        status.last_exit_status = parsed.last_exit_status;
        return;
    }
    let combined = command_message(output);
    if launchctl_reports_missing_service(&combined) {
        return;
    }
    status.status_error = Some(combined);
}

pub(super) fn parse_launchctl_print(output: &str) -> LaunchctlPrintStatus {
    let mut status = LaunchctlPrintStatus::default();
    for line in output.lines().map(str::trim) {
        if let Some(value) = line.strip_prefix("state = ") {
            status.state = Some(value.to_string());
        } else if let Some(value) = line.strip_prefix("pid = ") {
            status.pid = value.parse::<i32>().ok();
        } else if let Some(value) = line.strip_prefix("last exit code = ") {
            status.last_exit_status = value.parse::<i32>().ok();
        }
    }
    status
}
