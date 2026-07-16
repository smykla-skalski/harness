use std::os::unix::fs::MetadataExt as _;
use std::path::Path;

use fs_err as fs;
#[cfg(test)]
use nix::unistd::{Gid, Uid};

use crate::errors::CliError;

use super::super::remote_systemd_inhibitor::{inhibitor_is_installed, inhibitor_path};
use super::super::remote_systemd_lifecycle::RemoteSystemdCommandOutput;
use super::super::remote_systemd_start_permit::{
    RuntimeStartPermit, require_runtime_start_permit_absent,
};
use super::files::{io_error, regular_file_metadata};
use super::model::RemoteSystemdOperationPlan;
#[path = "unit_contract/identity.rs"]
mod identity;
#[path = "unit_contract/mount_namespace.rs"]
mod mount_namespace;
use runtime::validate_source_runtime_contract;
use sources::validate_effective_unit_sources;

#[path = "unit_contract/effective.rs"]
mod effective;
#[path = "unit_contract/paths.rs"]
mod paths;
#[path = "unit_contract/runtime.rs"]
mod runtime;
#[path = "unit_contract/sources.rs"]
mod sources;

#[cfg(test)]
#[path = "unit_contract/tests.rs"]
mod tests;

pub(super) fn validate_managed_unit_contract<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let service_type = validate_managed_unit_source(plan)?;
    validate_effective_unit_sources(plan, service_type, None, run_systemctl)
}

pub(super) fn validate_inhibited_managed_unit_contract<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let service_type = validate_managed_unit_source(plan)?;
    require_inhibitor_installed(plan)?;
    require_runtime_start_permit_absent(&plan.unit_path)?;
    let inhibitor = inhibitor_path(&plan.unit_path)?;
    validate_effective_unit_sources(plan, service_type, Some(&inhibitor), run_systemctl)
}

pub(super) fn validate_permitted_managed_unit_contract<RunSystemctl>(
    plan: &RemoteSystemdOperationPlan,
    permit: &RuntimeStartPermit,
    run_systemctl: &RunSystemctl,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let service_type = validate_managed_unit_source(plan)?;
    require_inhibitor_installed(plan)?;
    permit.require_live(&plan.unit_path)?;
    validate_effective_unit_sources(plan, service_type, Some(permit.path()), run_systemctl)
}

pub(super) fn validate_managed_unit_source_contract(
    plan: &RemoteSystemdOperationPlan,
) -> Result<(), CliError> {
    validate_managed_unit_source(plan).map(|_| ())
}

fn validate_managed_unit_source(
    plan: &RemoteSystemdOperationPlan,
) -> Result<runtime::ServiceType, CliError> {
    validate_managed_file(&plan.unit_path, "systemd unit", false)?;
    validate_managed_file(&plan.environment_path, "systemd environment", false)?;
    validate_managed_file(&plan.binary_path, "installed binary", true)?;
    let contents = fs::read_to_string(&plan.unit_path).map_err(|error| {
        io_error(format!(
            "read managed systemd unit {}: {error}",
            plan.unit_path.display()
        ))
    })?;
    let service = service_directives(&contents)?;
    let service_type = validate_source_runtime_contract(&service)?;
    require_exact_directive(&service, "StateDirectory", &plan.unit)?;
    require_exact_directive(&service, "StateDirectoryMode", "0700")?;
    require_exact_directive(&service, "DynamicUser", "yes")?;
    require_absent_directive(&service, "User")?;
    require_absent_directive(&service, "Group")?;
    require_optional_exact_directive(&service, "KillMode", "control-group")?;
    mount_namespace::reject_source_remaps(&service)?;
    reject_privileged_exec_auxiliaries(&service)?;
    reject_protected_unset_environment(&service)?;
    let environment_path = plan.environment_path.to_str().ok_or_else(|| {
        io_error(format!(
            "managed environment path is not UTF-8: {}",
            plan.environment_path.display()
        ))
    })?;
    require_exact_directive(&service, "EnvironmentFile", environment_path)?;
    let data_home = format!("%S/{}", plan.unit);
    require_environment(&service, "HARNESS_DAEMON_DATA_HOME", &data_home)?;
    require_environment(&service, "XDG_DATA_HOME", &data_home)?;
    require_environment(&service, "HARNESS_DAEMON_OWNERSHIP", "external")?;
    reject_environment_assignment(&service, "STATE_DIRECTORY")?;
    validate_environment_file(&plan.environment_path)?;
    require_exec_start(&service, &plan.binary_path)?;
    Ok(service_type)
}

fn validate_environment_file(path: &Path) -> Result<(), CliError> {
    let contents = fs::read_to_string(path).map_err(|error| {
        io_error(format!(
            "read managed systemd environment {}: {error}",
            path.display()
        ))
    })?;
    for line in contents.lines() {
        let trimmed = line.trim_start();
        if trimmed.is_empty() || trimmed.starts_with('#') || trimmed.starts_with(';') {
            continue;
        }
        let Some((name, _)) = trimmed.split_once('=') else {
            return Err(io_error(format!(
                "managed systemd environment contains an invalid assignment: {trimmed}"
            )));
        };
        let name = name.trim();
        if matches!(
            name,
            "HARNESS_DAEMON_DATA_HOME"
                | "XDG_DATA_HOME"
                | "STATE_DIRECTORY"
                | "HARNESS_DAEMON_OWNERSHIP"
        ) {
            return Err(io_error(format!(
                "managed systemd environment must not override protected variable {name}"
            )));
        }
    }
    Ok(())
}

fn validate_managed_file(path: &Path, label: &str, executable: bool) -> Result<(), CliError> {
    paths::validate_trusted_ancestors(path, label)?;
    let metadata = regular_file_metadata(path)?;
    let (owner_id, group_id) = trusted_owner();
    if metadata.uid() != owner_id || metadata.gid() != group_id {
        return Err(io_error(format!(
            "managed {label} {} must be root-owned (expected {owner_id}:{group_id}, found {}:{})",
            path.display(),
            metadata.uid(),
            metadata.gid()
        )));
    }
    if metadata.mode() & 0o022 != 0 {
        return Err(io_error(format!(
            "managed {label} {} must not be group- or world-writable (mode {:04o})",
            path.display(),
            metadata.mode() & 0o7777
        )));
    }
    if executable && metadata.mode() & 0o111 == 0 {
        return Err(io_error(format!(
            "managed installed binary {} must be executable",
            path.display()
        )));
    }
    Ok(())
}

fn require_inhibitor_installed(plan: &RemoteSystemdOperationPlan) -> Result<(), CliError> {
    if inhibitor_is_installed(&plan.unit_path)? {
        Ok(())
    } else {
        Err(io_error(format!(
            "persistent systemd inhibitor is not installed for {}",
            plan.service()
        )))
    }
}

fn trusted_owner() -> (u32, u32) {
    #[cfg(test)]
    {
        (Uid::effective().as_raw(), Gid::effective().as_raw())
    }
    #[cfg(not(test))]
    {
        (0, 0)
    }
}

pub(super) fn required_property<'a>(stdout: &'a str, key: &str) -> Result<&'a str, CliError> {
    let values = stdout
        .lines()
        .filter_map(|line| line.split_once('=').filter(|(name, _)| *name == key))
        .map(|(_, value)| value)
        .collect::<Vec<_>>();
    let [value] = values.as_slice() else {
        return Err(io_error(format!(
            "systemctl show must return exactly one {key} property, found {}",
            values.len()
        )));
    };
    Ok(value)
}

pub(super) fn require_effective_value(
    stdout: &str,
    key: &str,
    expected: &str,
) -> Result<(), CliError> {
    let value = required_property(stdout, key)?;
    if value == expected {
        Ok(())
    } else {
        Err(io_error(format!(
            "effective systemd unit requires {key}={expected}, found {value}"
        )))
    }
}

fn reject_effective_unset_environment(stdout: &str) -> Result<(), CliError> {
    let values = shell_words::split(required_property(stdout, "UnsetEnvironment")?)
        .map_err(|error| io_error(format!("parse effective systemd UnsetEnvironment: {error}")))?;
    if let Some(name) = values
        .iter()
        .map(|value| {
            value
                .split_once('=')
                .map_or(value.as_str(), |(name, _)| name)
        })
        .find(|name| protected_environment_names().contains(name))
    {
        Err(io_error(format!(
            "effective systemd unit must not unset protected variable {name}"
        )))
    } else {
        Ok(())
    }
}

fn service_directives(contents: &str) -> Result<Vec<(String, String)>, CliError> {
    let mut service_sections = 0_u8;
    let mut in_service = false;
    let mut directives = Vec::new();
    for line in contents.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') && trimmed.ends_with(']') {
            in_service = trimmed == "[Service]";
            if in_service {
                service_sections = service_sections.saturating_add(1);
            }
            continue;
        }
        if !in_service || trimmed.starts_with('#') || trimmed.starts_with(';') {
            continue;
        }
        if let Some((key, value)) = trimmed.split_once('=') {
            directives.push((key.trim().to_string(), value.trim().to_string()));
        }
    }
    if service_sections == 1 {
        Ok(directives)
    } else {
        Err(io_error(format!(
            "managed systemd unit must contain exactly one [Service] section, found {service_sections}"
        )))
    }
}

fn require_exact_directive(
    directives: &[(String, String)],
    key: &str,
    expected: &str,
) -> Result<(), CliError> {
    let observed = directives
        .iter()
        .filter_map(|(candidate, value)| (candidate == key).then_some(value.as_str()))
        .collect::<Vec<_>>();
    if observed == [expected] {
        Ok(())
    } else {
        Err(io_error(format!(
            "managed systemd unit requires exactly {key}={expected}, found {observed:?}"
        )))
    }
}

fn require_optional_exact_directive(
    directives: &[(String, String)],
    key: &str,
    expected: &str,
) -> Result<(), CliError> {
    let observed = directives
        .iter()
        .filter_map(|(candidate, value)| (candidate == key).then_some(value.as_str()))
        .collect::<Vec<_>>();
    if observed.is_empty() || observed == [expected] {
        Ok(())
    } else {
        Err(io_error(format!(
            "managed systemd unit permits only {key}={expected}, found {observed:?}"
        )))
    }
}

fn require_absent_directive(directives: &[(String, String)], key: &str) -> Result<(), CliError> {
    if directives.iter().any(|(candidate, _)| candidate == key) {
        Err(io_error(format!(
            "managed systemd unit must not define {key}; DynamicUser=yes owns the unprivileged identity"
        )))
    } else {
        Ok(())
    }
}

fn reject_privileged_exec_auxiliaries(directives: &[(String, String)]) -> Result<(), CliError> {
    if let Some((key, value)) = directives
        .iter()
        .find(|(key, _)| key.starts_with("Exec") && key != "ExecStart")
    {
        Err(io_error(format!(
            "managed systemd unit must not define privileged auxiliary {key}={value}"
        )))
    } else {
        Ok(())
    }
}

fn reject_protected_unset_environment(directives: &[(String, String)]) -> Result<(), CliError> {
    for value in directives
        .iter()
        .filter_map(|(key, value)| (key == "UnsetEnvironment").then_some(value))
    {
        let assignments = shell_words::split(value).map_err(|error| {
            io_error(format!(
                "parse managed systemd UnsetEnvironment directive: {error}"
            ))
        })?;
        if let Some(name) = assignments
            .iter()
            .map(|assignment| {
                assignment
                    .split_once('=')
                    .map_or(assignment.as_str(), |(name, _)| name)
            })
            .find(|name| protected_environment_names().contains(name))
        {
            return Err(io_error(format!(
                "managed systemd unit must not unset protected variable {name}"
            )));
        }
    }
    Ok(())
}

fn protected_environment_names() -> [&'static str; 4] {
    [
        "HARNESS_DAEMON_DATA_HOME",
        "XDG_DATA_HOME",
        "STATE_DIRECTORY",
        "HARNESS_DAEMON_OWNERSHIP",
    ]
}

fn auxiliary_exec_names() -> [&'static str; 6] {
    [
        "ExecStartPre",
        "ExecStartPost",
        "ExecCondition",
        "ExecReload",
        "ExecStop",
        "ExecStopPost",
    ]
}

fn require_environment(
    directives: &[(String, String)],
    key: &str,
    expected_value: &str,
) -> Result<(), CliError> {
    let prefix = format!("{key}=");
    let mut observed = Vec::new();
    for value in directives
        .iter()
        .filter_map(|(candidate, value)| (candidate == "Environment").then_some(value))
    {
        let assignments = shell_words::split(value).map_err(|error| {
            io_error(format!(
                "parse managed systemd Environment directive: {error}"
            ))
        })?;
        observed.extend(
            assignments
                .into_iter()
                .filter(|assignment| assignment.starts_with(&prefix)),
        );
    }
    let expected = format!("{key}={expected_value}");
    if observed == [expected.as_str()] {
        Ok(())
    } else {
        Err(io_error(format!(
            "managed systemd unit requires exactly Environment={expected}, found {observed:?}"
        )))
    }
}

fn reject_environment_assignment(
    directives: &[(String, String)],
    key: &str,
) -> Result<(), CliError> {
    let prefix = format!("{key}=");
    for value in directives
        .iter()
        .filter_map(|(candidate, value)| (candidate == "Environment").then_some(value))
    {
        let assignments = shell_words::split(value).map_err(|error| {
            io_error(format!(
                "parse managed systemd Environment directive: {error}"
            ))
        })?;
        if assignments
            .iter()
            .any(|assignment| assignment.starts_with(&prefix))
        {
            return Err(io_error(format!(
                "managed systemd unit must not override manager-owned variable {key}"
            )));
        }
    }
    Ok(())
}

fn require_exec_start(directives: &[(String, String)], binary_path: &Path) -> Result<(), CliError> {
    let values = directives
        .iter()
        .filter_map(|(candidate, value)| (candidate == "ExecStart").then_some(value))
        .collect::<Vec<_>>();
    let [value] = values.as_slice() else {
        return Err(io_error(format!(
            "managed systemd unit requires exactly one ExecStart, found {}",
            values.len()
        )));
    };
    let arguments = shell_words::split(value)
        .map_err(|error| io_error(format!("parse managed systemd ExecStart: {error}")))?;
    let expected = binary_path.to_str().ok_or_else(|| {
        io_error(format!(
            "managed binary path is not UTF-8: {}",
            binary_path.display()
        ))
    })?;
    let expected_prefix = [expected, "remote", "serve"];
    if arguments
        .iter()
        .map(String::as_str)
        .take(expected_prefix.len())
        .eq(expected_prefix)
    {
        Ok(())
    } else {
        Err(io_error(format!(
            "managed systemd ExecStart must reference {}, found {arguments:?}",
            binary_path.display()
        )))
    }
}
