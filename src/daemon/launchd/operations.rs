use std::path::{Path, PathBuf};

use fs_err as fs;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::write_text;

use super::state;
use super::support::{
    CommandOutput, command_message, launchctl_reports_missing_service, launchd_domain_target,
    launchd_service_target, launchd_service_target_for,
};
use super::{LAUNCH_AGENT_LABEL, LEGACY_LAUNCH_AGENT_LABEL, render_launch_agent_plist};

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
pub(super) fn restart_launch_agent_with<F>(runner: &F) -> Result<(), CliError>
where
    F: Fn(&[String]) -> Result<CommandOutput, CliError>,
{
    if !cfg!(target_os = "macos") {
        return Err(CliError::from(CliErrorKind::workflow_io(
            "launchd is only supported on macOS",
        )));
    }

    let path = state::launch_agent_path();
    if !path.is_file() {
        return Err(CliError::from(CliErrorKind::workflow_io(format!(
            "launch agent plist not installed: {}",
            path.display()
        ))));
    }

    tracing::info!("launchd: bootout");
    best_effort_bootout(runner)?;
    tracing::info!("launchd: bootstrap");
    bootstrap_launch_agent(&path, runner)?;
    tracing::info!("launchd: restart complete");
    Ok(())
}

pub(super) fn install_launch_agent_with<F>(
    binary_path: &Path,
    runner: &F,
) -> Result<PathBuf, CliError>
where
    F: Fn(&[String]) -> Result<CommandOutput, CliError>,
{
    state::ensure_daemon_dirs()?;
    remove_legacy_launch_agent_with(runner)?;
    let path = state::launch_agent_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "create launch agent dir: {error}"
            )))
        })?;
    }
    write_text(&path, &render_launch_agent_plist(binary_path))?;
    if cfg!(target_os = "macos") {
        best_effort_bootout(runner)?;
        bootstrap_launch_agent(&path, runner)?;
        kickstart_launch_agent(runner)?;
    }
    Ok(path)
}

pub(super) fn remove_launch_agent_with<F>(runner: &F) -> Result<bool, CliError>
where
    F: Fn(&[String]) -> Result<CommandOutput, CliError>,
{
    let mut removed = remove_legacy_launch_agent_with(runner)?;
    let path = state::launch_agent_path();
    removed |= if cfg!(target_os = "macos") {
        best_effort_bootout(runner)?
    } else {
        false
    };
    if !path.exists() {
        return Ok(removed);
    }
    fs::remove_file(path).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "remove launch agent plist: {error}"
        )))
    })?;
    Ok(true)
}

fn bootstrap_launch_agent<F>(path: &Path, runner: &F) -> Result<(), CliError>
where
    F: Fn(&[String]) -> Result<CommandOutput, CliError>,
{
    let args = vec![
        "bootstrap".to_string(),
        launchd_domain_target(),
        path.display().to_string(),
    ];
    let output = runner(&args)?;
    ensure_launchctl_success("bootstrap launch agent", &output)
}

fn kickstart_launch_agent<F>(runner: &F) -> Result<(), CliError>
where
    F: Fn(&[String]) -> Result<CommandOutput, CliError>,
{
    let args = vec![
        "kickstart".to_string(),
        "-k".to_string(),
        launchd_service_target(),
    ];
    let output = runner(&args)?;
    ensure_launchctl_success("kickstart launch agent", &output)
}

fn remove_legacy_launch_agent_with<F>(runner: &F) -> Result<bool, CliError>
where
    F: Fn(&[String]) -> Result<CommandOutput, CliError>,
{
    let mut removed = if cfg!(target_os = "macos") {
        best_effort_bootout_for(LEGACY_LAUNCH_AGENT_LABEL, runner)?
    } else {
        false
    };

    let path = state::legacy_launch_agent_path();
    if !path.exists() {
        return Ok(removed);
    }

    fs::remove_file(path).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "remove legacy launch agent plist: {error}"
        )))
    })?;
    removed = true;
    Ok(removed)
}

pub(super) fn best_effort_bootout<F>(runner: &F) -> Result<bool, CliError>
where
    F: Fn(&[String]) -> Result<CommandOutput, CliError>,
{
    best_effort_bootout_for(LAUNCH_AGENT_LABEL, runner)
}

fn best_effort_bootout_for<F>(label: &str, runner: &F) -> Result<bool, CliError>
where
    F: Fn(&[String]) -> Result<CommandOutput, CliError>,
{
    let args = vec!["bootout".to_string(), launchd_service_target_for(label)];
    let output = runner(&args)?;
    if output.exit_code == 0 {
        return Ok(true);
    }
    let message = command_message(&output);
    if launchctl_reports_missing_service(&message) {
        return Ok(false);
    }
    Err(CliError::from(CliErrorKind::workflow_io(format!(
        "bootout launch agent: {message}"
    ))))
}

fn ensure_launchctl_success(action: &str, output: &CommandOutput) -> Result<(), CliError> {
    if output.exit_code == 0 {
        return Ok(());
    }
    Err(CliError::from(CliErrorKind::workflow_io(format!(
        "{action}: {}",
        command_message(output)
    ))))
}
