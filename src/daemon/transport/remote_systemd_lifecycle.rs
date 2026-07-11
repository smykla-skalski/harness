use std::io::ErrorKind;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::Command;

use fs_err as fs;
use serde::Serialize;

use crate::errors::{CliError, CliErrorKind};

use super::remote_systemd::RemoteSystemdInstallPlan;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct RemoteSystemdCommandOutput {
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[expect(
    clippy::struct_excessive_bools,
    reason = "CLI JSON report exposes independent systemd operation flags"
)]
pub(crate) struct RemoteSystemdInstallReport {
    pub unit_path: PathBuf,
    pub env_path: PathBuf,
    pub unit_written: bool,
    pub env_written: bool,
    pub daemon_reloaded: bool,
    pub enabled: bool,
    pub started: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[expect(
    clippy::struct_excessive_bools,
    reason = "CLI JSON report exposes independent systemd operation flags"
)]
pub(crate) struct RemoteSystemdUninstallReport {
    pub unit: String,
    pub unit_path: PathBuf,
    pub env_path: PathBuf,
    pub unit_removed: bool,
    pub env_removed: bool,
    pub disabled: bool,
    pub disable_exit_code: Option<i32>,
    pub disable_error: Option<String>,
    pub daemon_reloaded: bool,
}

pub(crate) fn install_remote_systemd_with<RunSystemctl>(
    plan: &RemoteSystemdInstallPlan,
    run_systemctl: &RunSystemctl,
) -> Result<RemoteSystemdInstallReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let unit_written = write_if_changed(&plan.unit_path, &plan.unit_contents, 0o644)?;
    let env_written = write_if_changed(&plan.env_path, &plan.env_contents, 0o600)?;
    run_checked(run_systemctl, &["daemon-reload".to_string()])?;
    run_checked(
        run_systemctl,
        &[
            "enable".to_string(),
            "--now".to_string(),
            unit_service_name(&plan.unit),
        ],
    )?;
    Ok(RemoteSystemdInstallReport {
        unit_path: plan.unit_path.clone(),
        env_path: plan.env_path.clone(),
        unit_written,
        env_written,
        daemon_reloaded: true,
        enabled: true,
        started: true,
    })
}

pub(crate) fn uninstall_remote_systemd_with<RunSystemctl>(
    unit: &str,
    unit_path: &Path,
    env_path: &Path,
    run_systemctl: &RunSystemctl,
) -> Result<RemoteSystemdUninstallReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    validate_unit_name(unit)?;
    let service = unit_service_name(unit);
    let disable_result = run_systemctl(&["disable".to_string(), "--now".to_string(), service]);
    let unit_removed = remove_if_exists(unit_path)?;
    let env_removed = remove_if_exists(env_path)?;
    run_checked(run_systemctl, &["daemon-reload".to_string()])?;
    let (disabled, disable_exit_code, disable_error) = disable_report(disable_result);
    Ok(RemoteSystemdUninstallReport {
        unit: unit.to_string(),
        unit_path: unit_path.to_path_buf(),
        env_path: env_path.to_path_buf(),
        unit_removed,
        env_removed,
        disabled,
        disable_exit_code,
        disable_error,
        daemon_reloaded: true,
    })
}

pub(super) fn run_systemctl(args: &[String]) -> Result<RemoteSystemdCommandOutput, CliError> {
    let output = Command::new("systemctl")
        .args(args)
        .output()
        .map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "run systemctl {}: {error}",
                shell_words::join(args.iter().map(String::as_str))
            )))
        })?;
    Ok(RemoteSystemdCommandOutput {
        exit_code: output.status.code().unwrap_or(1),
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    })
}

pub(super) fn unit_service_name(unit: &str) -> String {
    if unit.ends_with(".service") {
        unit.to_string()
    } else {
        format!("{unit}.service")
    }
}

pub(super) fn normalize_unit_name(unit: &str) -> &str {
    unit.strip_suffix(".service").unwrap_or(unit)
}

pub(super) fn validate_unit_name(unit: &str) -> Result<(), CliError> {
    if !unit.is_empty()
        && !unit.contains('/')
        && !unit.contains('\\')
        && !unit.contains("..")
        && unit
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
    {
        return Ok(());
    }
    Err(CliErrorKind::workflow_parse(format!("unsafe systemd unit name '{unit}'")).into())
}

fn write_if_changed(path: &Path, contents: &str, mode: u32) -> Result<bool, CliError> {
    if matches!(fs::read_to_string(path), Ok(existing) if existing == contents) {
        set_file_mode(path, mode)?;
        return Ok(false);
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "create directory {}: {error}",
                parent.display()
            )))
        })?;
    }
    write_atomic(path, contents, mode)?;
    Ok(true)
}

fn write_atomic(path: &Path, contents: &str, mode: u32) -> Result<(), CliError> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let mut temp = tempfile::NamedTempFile::new_in(parent).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "create temp file for {}: {error}",
            path.display()
        )))
    })?;
    set_file_mode(temp.path(), mode)?;
    temp.write_all(contents.as_bytes()).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "write temp file for {}: {error}",
            path.display()
        )))
    })?;
    temp.flush().map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "flush temp file for {}: {error}",
            path.display()
        )))
    })?;
    temp.persist(path)
        .map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "persist {}: {}",
                path.display(),
                error.error
            )))
        })
        .map(|_| ())
}

fn remove_if_exists(path: &Path) -> Result<bool, CliError> {
    match fs::remove_file(path) {
        Ok(()) => Ok(true),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(false),
        Err(error) => {
            Err(CliErrorKind::workflow_io(format!("remove {}: {error}", path.display())).into())
        }
    }
}

fn disable_report(
    result: Result<RemoteSystemdCommandOutput, CliError>,
) -> (bool, Option<i32>, Option<String>) {
    match result {
        Ok(output) => {
            let error = if output.exit_code == 0 {
                None
            } else {
                Some(output.stderr.trim().to_string())
            };
            (output.exit_code == 0, Some(output.exit_code), error)
        }
        Err(error) => (false, None, Some(error.to_string())),
    }
}

#[cfg(unix)]
fn set_file_mode(path: &Path, mode: u32) -> Result<(), CliError> {
    use std::fs::Permissions;
    use std::os::unix::fs::PermissionsExt;

    fs::set_permissions(path, Permissions::from_mode(mode)).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "set permissions {}: {error}",
            path.display()
        )))
    })
}

#[cfg(not(unix))]
fn set_file_mode(_path: &Path, _mode: u32) -> Result<(), CliError> {
    Ok(())
}

fn run_checked<RunSystemctl>(runner: &RunSystemctl, args: &[String]) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let output = runner(args)?;
    if output.exit_code == 0 {
        return Ok(());
    }
    Err(CliErrorKind::workflow_io(format!(
        "systemctl {} failed with exit code {}: {}",
        shell_words::join(args.iter().map(String::as_str)),
        output.exit_code,
        output.stderr.trim()
    ))
    .into())
}
