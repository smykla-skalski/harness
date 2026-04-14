use std::process::Command;

use uzers::get_current_uid;

use crate::errors::{CliError, CliErrorKind};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct CommandOutput {
    pub(super) exit_code: i32,
    pub(super) stdout: String,
    pub(super) stderr: String,
}

pub(super) fn run_launchctl(args: &[String]) -> Result<CommandOutput, CliError> {
    let output = Command::new("launchctl")
        .args(args)
        .output()
        .map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "run launchctl {}: {error}",
                args.join(" ")
            )))
        })?;
    Ok(CommandOutput {
        exit_code: output.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    })
}

pub(super) fn command_message(output: &CommandOutput) -> String {
    let stderr = output.stderr.trim();
    if !stderr.is_empty() {
        return stderr.to_string();
    }
    let stdout = output.stdout.trim();
    if !stdout.is_empty() {
        return stdout.to_string();
    }
    format!("launchctl exited with status {}", output.exit_code)
}

pub(super) fn launchctl_reports_missing_service(message: &str) -> bool {
    let lowercase = message.to_ascii_lowercase();
    lowercase.contains("could not find service")
        || lowercase.contains("service could not be found")
        || lowercase.contains("no such process")
        || lowercase.contains("not loaded")
}

pub(super) fn launchd_domain_target() -> String {
    format!("gui/{}", get_current_uid())
}

pub(super) fn launchd_service_target() -> String {
    launchd_service_target_for(super::LAUNCH_AGENT_LABEL)
}

pub(super) fn launchd_service_target_for(label: &str) -> String {
    format!("{}/{}", launchd_domain_target(), label)
}
