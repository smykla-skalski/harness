use std::path::Path;

use crate::errors::CliError;

use super::super::files::io_error;
use super::super::model::RemoteSystemdOperationPlan;
use super::{
    auxiliary_exec_names, reject_effective_unset_environment, require_effective_value,
    required_property,
};

const SYSTEM_STATE_DIRECTORY_ROOT: &str = "/var/lib";

pub(super) fn require_effective_storage(
    stdout: &str,
    plan: &RemoteSystemdOperationPlan,
) -> Result<(), CliError> {
    require_effective_value(stdout, "StateDirectory", &plan.unit)?;
    require_effective_value(stdout, "StateDirectoryMode", "0700")
}

pub(super) fn require_effective_environment(
    stdout: &str,
    plan: &RemoteSystemdOperationPlan,
) -> Result<(), CliError> {
    let environment = shell_words::split(required_property(stdout, "Environment")?)
        .map_err(|error| io_error(format!("parse effective systemd Environment: {error}")))?;
    let data_home = format!("{SYSTEM_STATE_DIRECTORY_ROOT}/{}", plan.unit);
    for (name, expected_value) in [
        ("HARNESS_DAEMON_DATA_HOME", data_home.as_str()),
        ("XDG_DATA_HOME", data_home.as_str()),
        ("HARNESS_DAEMON_OWNERSHIP", "external"),
    ] {
        require_effective_assignment(&environment, name, expected_value)?;
    }
    reject_effective_assignment(&environment, "STATE_DIRECTORY")?;
    require_effective_environment_file(stdout, &plan.environment_path)?;
    reject_effective_unset_environment(stdout)
}

fn reject_effective_assignment(environment: &[String], name: &str) -> Result<(), CliError> {
    if environment.iter().any(|assignment| {
        assignment
            .split_once('=')
            .is_some_and(|(key, _)| key == name)
    }) {
        Err(io_error(format!(
            "effective systemd Environment must not override manager-owned variable {name}"
        )))
    } else {
        Ok(())
    }
}

fn require_effective_assignment(
    environment: &[String],
    name: &str,
    expected_value: &str,
) -> Result<(), CliError> {
    let observed = environment
        .iter()
        .filter(|assignment| {
            assignment
                .split_once('=')
                .is_some_and(|(key, _)| key == name)
        })
        .map(String::as_str)
        .collect::<Vec<_>>();
    let expected = format!("{name}={expected_value}");
    if observed == [expected.as_str()] {
        Ok(())
    } else {
        Err(io_error(format!(
            "effective systemd Environment must define {name} exactly once as {expected}, found {observed:?}"
        )))
    }
}

fn require_effective_environment_file(stdout: &str, path: &Path) -> Result<(), CliError> {
    let expected = path.to_str().ok_or_else(|| {
        io_error(format!(
            "managed environment path is not UTF-8: {}",
            path.display()
        ))
    })?;
    let values = shell_words::split(required_property(stdout, "EnvironmentFiles")?)
        .map_err(|error| io_error(format!("parse effective systemd EnvironmentFiles: {error}")))?;
    if values
        .iter()
        .map(String::as_str)
        .eq([expected, "(ignore_errors=no)"])
    {
        Ok(())
    } else {
        Err(io_error(format!(
            "effective systemd EnvironmentFiles requires exactly {}, found {values:?}",
            path.display()
        )))
    }
}

pub(super) fn require_effective_exec_contract(
    stdout: &str,
    binary_path: &Path,
) -> Result<(), CliError> {
    let exec_start = parse_exec_start(required_property(stdout, "ExecStart")?)?;
    let expected = binary_path.to_str().ok_or_else(|| {
        io_error(format!(
            "managed binary path is not UTF-8: {}",
            binary_path.display()
        ))
    })?;
    let expected_prefix = [expected, "remote", "serve"];
    if exec_start.path != expected
        || !exec_start
            .arguments
            .iter()
            .map(String::as_str)
            .take(expected_prefix.len())
            .eq(expected_prefix)
    {
        return Err(io_error(format!(
            "effective systemd ExecStart must run {} remote serve, found path={:?} argv={:?}",
            binary_path.display(),
            exec_start.path,
            exec_start.arguments
        )));
    }
    for key in auxiliary_exec_names() {
        require_effective_auxiliary_absent(stdout, key)?;
    }
    Ok(())
}

fn require_effective_auxiliary_absent(stdout: &str, key: &str) -> Result<(), CliError> {
    let values = stdout
        .lines()
        .filter_map(|line| line.split_once('=').filter(|(name, _)| *name == key))
        .map(|(_, value)| value)
        .collect::<Vec<_>>();
    match values.as_slice() {
        [] | [""] => Ok(()),
        [value] if value.trim().is_empty() => Ok(()),
        [value] => Err(io_error(format!(
            "effective systemd unit must not define privileged auxiliary {key}, found {value}"
        ))),
        _ => Err(io_error(format!(
            "systemctl show must return at most one {key} property, found {}",
            values.len()
        ))),
    }
}

struct ParsedExecStart {
    path: String,
    arguments: Vec<String>,
}

fn parse_exec_start(value: &str) -> Result<ParsedExecStart, CliError> {
    let body = value
        .trim()
        .strip_prefix('{')
        .and_then(|value| value.strip_suffix('}'))
        .ok_or_else(|| io_error(format!("parse effective systemd ExecStart record: {value}")))?;
    if body.contains('{') || body.contains('}') {
        return Err(io_error(format!(
            "effective systemd ExecStart must contain exactly one command record: {value}"
        )));
    }
    let mut path = None;
    let mut arguments = None;
    for field in body
        .split(';')
        .map(str::trim)
        .filter(|field| !field.is_empty())
    {
        let Some((key, value)) = field.split_once('=') else {
            return Err(io_error(format!(
                "parse effective systemd ExecStart field: {field}"
            )));
        };
        match key.trim() {
            "path" => set_single_field(&mut path, parse_path(value)?, "path")?,
            "argv[]" => set_single_field(
                &mut arguments,
                shell_words::split(value).map_err(|error| {
                    io_error(format!("parse effective systemd ExecStart argv: {error}"))
                })?,
                "argv[]",
            )?,
            _ => {}
        }
    }
    Ok(ParsedExecStart {
        path: path.ok_or_else(|| io_error("effective systemd ExecStart omitted path"))?,
        arguments: arguments
            .ok_or_else(|| io_error("effective systemd ExecStart omitted argv[]"))?,
    })
}

fn parse_path(value: &str) -> Result<String, CliError> {
    let values = shell_words::split(value)
        .map_err(|error| io_error(format!("parse effective systemd ExecStart path: {error}")))?;
    let [path] = values.as_slice() else {
        return Err(io_error(format!(
            "effective systemd ExecStart path must contain one value, found {values:?}"
        )));
    };
    Ok(path.clone())
}

fn set_single_field<T>(slot: &mut Option<T>, value: T, name: &str) -> Result<(), CliError> {
    if slot.replace(value).is_some() {
        Err(io_error(format!(
            "effective systemd ExecStart contains duplicate {name}"
        )))
    } else {
        Ok(())
    }
}

#[cfg(test)]
pub(super) fn parse_exec_start_for_tests(value: &str) -> Result<(String, Vec<String>), CliError> {
    parse_exec_start(value).map(|parsed| (parsed.path, parsed.arguments))
}
