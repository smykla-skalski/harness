use std::path::{Path, PathBuf};
use std::process::Command;
use std::str::from_utf8;

use crate::errors::{CliError, CliErrorKind};

use super::remote_systemd_lifecycle::{
    RemoteSystemdCommandOutput, unit_service_name, validate_canonical_unit_name,
};

#[path = "binary_exclusivity/inventory.rs"]
mod inventory;
#[path = "binary_exclusivity/parser.rs"]
mod parser;

#[cfg(test)]
#[path = "binary_exclusivity/tests.rs"]
mod tests;

pub(crate) fn validate_exclusive_systemd_binary<RunSystemctl>(
    unit: &str,
    binary_path: &Path,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let default_search_path = || compiled_systemd_search_path(run_systemctl);
    validate_exclusive_systemd_binary_with_search_path(
        unit,
        binary_path,
        run_systemctl,
        &default_search_path,
    )
}

fn validate_exclusive_systemd_binary_with_search_path<RunSystemctl, DefaultSearchPath>(
    unit: &str,
    binary_path: &Path,
    run_systemctl: &RunSystemctl,
    default_search_path: &DefaultSearchPath,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    DefaultSearchPath: Fn() -> Result<Vec<PathBuf>, CliError>,
{
    validate_canonical_unit_name(unit)?;
    inventory::validate_exclusive_systemd_binary(
        &unit_service_name(unit),
        binary_path,
        run_systemctl,
        default_search_path,
    )
}

fn compiled_systemd_search_path<RunSystemctl>(
    run_systemctl: &RunSystemctl,
) -> Result<Vec<PathBuf>, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    const SYSTEMD_PATH: &str = "/usr/bin/systemd-path";

    let manager_version = systemd_manager_version(run_systemctl)?;
    let output = Command::new(SYSTEMD_PATH)
        .arg("--version")
        .output()
        .map_err(|error| inventory_error(format!("run {SYSTEMD_PATH} --version: {error}")))?;
    if !output.status.success() {
        return Err(inventory_error(format!(
            "{SYSTEMD_PATH} --version failed with exit code {}: {}",
            output.status.code().unwrap_or(1),
            String::from_utf8_lossy(&output.stderr).trim()
        )));
    }
    let version_stdout = from_utf8(&output.stdout).map_err(|error| {
        inventory_error(format!(
            "parse {SYSTEMD_PATH} --version output as UTF-8: {error}"
        ))
    })?;
    let version_line = version_stdout.lines().next().unwrap_or_default();
    if !version_line.starts_with("systemd ")
        || !version_line.ends_with(&format!(" ({manager_version})"))
    {
        return Err(inventory_error(format!(
            "systemd manager version {manager_version} does not match {SYSTEMD_PATH}: {version_line}"
        )));
    }
    let output = Command::new(SYSTEMD_PATH)
        .arg("search-binaries-default")
        .output()
        .map_err(|error| {
            inventory_error(format!(
                "run {SYSTEMD_PATH} search-binaries-default: {error}"
            ))
        })?;
    if !output.status.success() {
        return Err(inventory_error(format!(
            "{SYSTEMD_PATH} search-binaries-default failed with exit code {}: {}",
            output.status.code().unwrap_or(1),
            String::from_utf8_lossy(&output.stderr).trim()
        )));
    }
    let stdout = from_utf8(&output.stdout).map_err(|error| {
        inventory_error(format!("parse {SYSTEMD_PATH} output as UTF-8: {error}"))
    })?;
    let value = stdout
        .strip_suffix("\r\n")
        .or_else(|| stdout.strip_suffix('\n'))
        .unwrap_or(stdout);
    if value.contains('\n') || value.contains('\r') {
        return Err(inventory_error(format!(
            "{SYSTEMD_PATH} returned multiple output lines"
        )));
    }
    parser::parse_colon_search_path(value, "systemd compiled executable search path")
}

fn systemd_manager_version<RunSystemctl>(run_systemctl: &RunSystemctl) -> Result<String, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let args = ["show".to_string(), "--property=Version".to_string()];
    let output = run_systemctl(&args)?;
    if output.exit_code != 0 {
        return Err(inventory_error(format!(
            "systemctl show --property=Version failed with exit code {}: {}",
            output.exit_code,
            output.stderr.trim()
        )));
    }
    let lines = output
        .stdout
        .lines()
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>();
    let [line] = lines.as_slice() else {
        return Err(inventory_error(
            "systemctl show returned malformed manager Version output",
        ));
    };
    let version = line
        .strip_prefix("Version=")
        .filter(|version| !version.is_empty())
        .ok_or_else(|| inventory_error("systemctl show omitted manager Version"))?;
    Ok(version.to_string())
}

fn validate_service_name(name: &str, label: &str) -> Result<(), CliError> {
    validate_unit_name(name, label)?;
    if name.ends_with(".service") {
        Ok(())
    } else {
        Err(inventory_error(format!("invalid {label}: {name:?}")))
    }
}

fn validate_unit_name(name: &str, label: &str) -> Result<(), CliError> {
    const UNIT_SUFFIXES: [&str; 11] = [
        ".service",
        ".socket",
        ".target",
        ".device",
        ".mount",
        ".automount",
        ".swap",
        ".timer",
        ".path",
        ".slice",
        ".scope",
    ];

    if UNIT_SUFFIXES.iter().any(|suffix| {
        name.strip_suffix(suffix)
            .is_some_and(|stem| !stem.is_empty())
    }) && name.bytes().all(|byte| byte.is_ascii_graphic())
    {
        Ok(())
    } else {
        Err(inventory_error(format!("invalid {label}: {name:?}")))
    }
}

fn inventory_error(message: impl Into<String>) -> CliError {
    CliErrorKind::workflow_io(message.into()).into()
}
