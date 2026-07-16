use std::path::{Path, PathBuf};
use std::process::Command;

use serde::Serialize;

use crate::errors::{CliError, CliErrorKind};

use super::remote_systemd::RemoteSystemdInstallPlan;

const SYSTEMCTL_OUTPUT_ENVIRONMENT: [(&str, &str); 9] = [
    ("LC_ALL", "C"),
    ("SYSTEMD_COLORS", "0"),
    ("SYSTEMD_LOG_COLOR", "0"),
    ("SYSTEMD_LOG_LEVEL", "info"),
    ("SYSTEMD_LOG_LOCATION", "0"),
    ("SYSTEMD_LOG_TARGET", "console"),
    ("SYSTEMD_LOG_TID", "0"),
    ("SYSTEMD_LOG_TIME", "0"),
    ("SYSTEMD_URLIFY", "0"),
];

mod install_files;
mod uninstall;
mod unit_name;

use install_files::{
    validate_install_binary, validate_install_environment, write_if_missing, write_unit_if_missing,
};
#[cfg(test)]
pub(crate) use uninstall::uninstall_remote_systemd_with_cgroup_root;
pub(crate) use uninstall::{preflight_uninstall_managed_binary, uninstall_remote_systemd_with};
pub(super) use unit_name::{
    CanonicalRemoteSystemdUnit, parse_remote_systemd_unit_arg, unit_service_name,
    validate_canonical_unit_name, validate_path_outside_unit_directory,
    validate_systemd_directive_path,
};

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

#[cfg(test)]
pub(crate) fn install_remote_systemd_with<RunSystemctl>(
    plan: &RemoteSystemdInstallPlan,
    run_systemctl: &RunSystemctl,
) -> Result<RemoteSystemdInstallReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    install_remote_systemd_with_pre_enable(plan, run_systemctl, &mut || Ok(()))
}

pub(crate) fn install_remote_systemd_with_pre_enable<RunSystemctl, BeforeEnable>(
    plan: &RemoteSystemdInstallPlan,
    run_systemctl: &RunSystemctl,
    before_enable: &mut BeforeEnable,
) -> Result<RemoteSystemdInstallReport, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    BeforeEnable: FnMut() -> Result<(), CliError>,
{
    validate_install_binary(&plan.binary_path)?;
    let unit_written =
        write_unit_if_missing(&plan.unit_path, &plan.unit_contents, &plan.unit, 0o644)?;
    let env_written = write_if_missing(&plan.env_path, &plan.env_contents, 0o600)?;
    validate_install_environment(&plan.env_path)?;
    run_checked(run_systemctl, &["daemon-reload".to_string()])?;
    validate_effective_install_unit(plan, run_systemctl)?;
    before_enable()?;
    run_checked(
        run_systemctl,
        &[
            "enable".to_string(),
            "--now".to_string(),
            "--".to_string(),
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

fn validate_effective_install_unit<RunSystemctl>(
    plan: &RemoteSystemdInstallPlan,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let output = run_systemctl(&[
        "show".to_string(),
        "--property=LoadState".to_string(),
        "--property=FragmentPath".to_string(),
        "--property=DropInPaths".to_string(),
        "--".to_string(),
        unit_service_name(&plan.unit),
    ])?;
    if output.exit_code != 0 {
        return Err(CliErrorKind::workflow_io(format!(
            "inspect effective systemd unit {} before start: {}",
            plan.unit,
            output.stderr.trim()
        ))
        .into());
    }
    let load_state = required_systemd_property(&output.stdout, "LoadState")?;
    let fragment_path = required_systemd_property(&output.stdout, "FragmentPath")?;
    let drop_ins = required_systemd_property(&output.stdout, "DropInPaths")?;
    if load_state == "loaded" && Path::new(fragment_path) == plan.unit_path && drop_ins.is_empty() {
        Ok(())
    } else {
        Err(CliErrorKind::workflow_io(format!(
            "refusing to start systemd unit {} with unexpected effective sources (LoadState={load_state}, FragmentPath={fragment_path}, DropInPaths={drop_ins})",
            plan.unit
        ))
        .into())
    }
}

fn required_systemd_property<'a>(output: &'a str, name: &str) -> Result<&'a str, CliError> {
    let mut values = output
        .lines()
        .filter_map(|line| line.strip_prefix(name)?.strip_prefix('='));
    let value = values.next().ok_or_else(|| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "systemctl show omitted {name}"
        )))
    })?;
    if values.next().is_some() {
        Err(CliErrorKind::workflow_io(format!("systemctl show returned duplicate {name}")).into())
    } else {
        Ok(value)
    }
}

#[cfg(test)]
pub(crate) fn effective_install_show_for_tests(plan: &RemoteSystemdInstallPlan) -> String {
    format!(
        "LoadState=loaded\nFragmentPath={}\nDropInPaths=\n",
        plan.unit_path.display()
    )
}

pub(super) fn run_systemctl(args: &[String]) -> Result<RemoteSystemdCommandOutput, CliError> {
    let mut command = systemctl_command();
    command.args(args);
    let output = command.output().map_err(|error| {
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

fn systemctl_command() -> Command {
    let mut command = Command::new("systemctl");
    command.envs(SYSTEMCTL_OUTPUT_ENVIRONMENT);
    command
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

#[cfg(test)]
mod tests {
    use std::ffi::OsStr;

    use super::{SYSTEMCTL_OUTPUT_ENVIRONMENT, systemctl_command};

    #[test]
    fn systemctl_command_normalizes_diagnostic_output() {
        let command = systemctl_command();
        for (expected_key, expected_value) in SYSTEMCTL_OUTPUT_ENVIRONMENT {
            let actual = command
                .get_envs()
                .find(|(key, _)| *key == OsStr::new(expected_key))
                .and_then(|(_, value)| value);
            assert_eq!(actual, Some(OsStr::new(expected_value)));
        }
    }
}
