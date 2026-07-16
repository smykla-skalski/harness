use std::collections::BTreeSet;
use std::path::{Component, Path, PathBuf};

use crate::errors::CliError;

use super::super::remote_systemd_lifecycle::RemoteSystemdCommandOutput;
use super::parser::{
    ParsedService, ResolvedExecutable, SHOW_PROPERTIES, normalize_absolute_path,
    parse_service_observation, resolve_executable, resolve_observed_executable,
    resolve_search_candidate,
};
use super::{inventory_error, validate_service_name, validate_unit_name};

const LIST_UNIT_FILES: [&str; 5] = [
    "list-unit-files",
    "--type=service,socket,mount,swap",
    "--all",
    "--no-legend",
    "--no-pager",
];
const LIST_UNITS: [&str; 6] = [
    "list-units",
    "--type=service,socket,mount,swap",
    "--all",
    "--no-legend",
    "--no-pager",
    "--plain",
];
pub(super) fn validate_exclusive_systemd_binary<RunSystemctl, DefaultSearchPath>(
    target_service: &str,
    target_binary: &Path,
    run_systemctl: &RunSystemctl,
    default_search_path: &DefaultSearchPath,
) -> Result<(), CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
    DefaultSearchPath: Fn() -> Result<Vec<PathBuf>, CliError>,
{
    validate_service_name(target_service, "target systemd service")?;
    let target_executable = resolve_executable(target_binary, "target systemd executable")?;
    let inventory = systemd_unit_inventory(run_systemctl)?;
    let mut cached_default_search_path = None;
    for inventory_name in inventory {
        let observations = inspect_units(&inventory_name, run_systemctl)?;
        for observation in &observations {
            validate_observed_identity(observation, target_service)?;
        }
        validate_template_stability(&inventory_name, &observations)?;
        for observation in &observations {
            reject_shared_executable(
                observation,
                &target_executable,
                target_service,
                &mut cached_default_search_path,
                default_search_path,
            )?;
        }
    }
    Ok(())
}

fn systemd_unit_inventory<RunSystemctl>(
    run_systemctl: &RunSystemctl,
) -> Result<BTreeSet<String>, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let unit_files = checked_systemctl(run_systemctl, &LIST_UNIT_FILES)?;
    let loaded_units = checked_systemctl(run_systemctl, &LIST_UNITS)?;
    let mut inventory = parse_inventory(&unit_files.stdout, InventoryKind::UnitFiles)?;
    inventory.extend(parse_inventory(
        &loaded_units.stdout,
        InventoryKind::LoadedUnits,
    )?);
    Ok(inventory)
}

#[derive(Clone, Copy)]
pub(super) enum InventoryKind {
    UnitFiles,
    LoadedUnits,
}

pub(super) fn parse_inventory(
    stdout: &str,
    kind: InventoryKind,
) -> Result<BTreeSet<String>, CliError> {
    stdout
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| parse_inventory_line(line, kind))
        .collect()
}

fn parse_inventory_line(line: &str, kind: InventoryKind) -> Result<String, CliError> {
    let mut columns = line.split_ascii_whitespace().collect::<Vec<_>>();
    if columns
        .first()
        .is_some_and(|column| is_status_marker(column))
    {
        columns.remove(0);
    }
    let minimum_columns = match kind {
        InventoryKind::UnitFiles => 2,
        InventoryKind::LoadedUnits => 4,
    };
    if columns.len() < minimum_columns {
        return Err(inventory_error(format!(
            "malformed systemd unit inventory line: {line}"
        )));
    }
    let name = columns[0];
    validate_unit_name(name, "systemd inventory entry")?;
    Ok(name.to_string())
}

fn is_status_marker(value: &str) -> bool {
    matches!(value, "●" | "○" | "×")
}

fn inspect_units<RunSystemctl>(
    inventory_name: &str,
    run_systemctl: &RunSystemctl,
) -> Result<Vec<ServiceObservation>, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    if let Some(query_names) = template_query_names(inventory_name) {
        query_names
            .into_iter()
            .map(|query_name| inspect_unit(inventory_name, query_name, run_systemctl))
            .collect()
    } else {
        Ok(vec![inspect_unit(
            inventory_name,
            inventory_name.to_string(),
            run_systemctl,
        )?])
    }
}

fn inspect_unit<RunSystemctl>(
    inventory_name: &str,
    query_name: String,
    run_systemctl: &RunSystemctl,
) -> Result<ServiceObservation, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let mut args = vec!["show".to_string()];
    args.extend(
        SHOW_PROPERTIES
            .iter()
            .map(|property| format!("--property={property}")),
    );
    args.extend(["--".to_string(), query_name.clone()]);
    let output = checked_systemctl_owned(run_systemctl, &args)?;
    let service = parse_service_observation(&output.stdout)?;
    let inventory_identity = if query_name == inventory_name {
        service.id.clone()
    } else {
        inventory_name.to_string()
    };
    Ok(ServiceObservation {
        service,
        query_name,
        inventory_identity,
    })
}

fn template_query_names(inventory_name: &str) -> Option<[String; 2]> {
    let (prefix, suffix) = inventory_name.rsplit_once("@.")?;
    if prefix.is_empty() || suffix.is_empty() {
        return None;
    }
    Some([
        format!("{prefix}@harness-inventory-a.{suffix}"),
        format!("{prefix}@harness-inventory-b.{suffix}"),
    ])
}

struct ServiceObservation {
    service: ParsedService,
    query_name: String,
    inventory_identity: String,
}

fn validate_template_stability(
    inventory_name: &str,
    observations: &[ServiceObservation],
) -> Result<(), CliError> {
    let [first, second] = observations else {
        return Ok(());
    };
    if first.service.fragment_path == second.service.fragment_path
        && first.service.drop_in_paths == second.service.drop_in_paths
        && first.service.executables == second.service.executables
        && first.service.exec_search_path == second.service.exec_search_path
        && first.service.uses_alternate_mount_namespace
            == second.service.uses_alternate_mount_namespace
        && first.service.private_tmp == second.service.private_tmp
    {
        Ok(())
    } else {
        Err(inventory_error(format!(
            "cannot prove systemd executable exclusivity for instance-dependent template {inventory_name}"
        )))
    }
}

fn validate_observed_identity(
    observation: &ServiceObservation,
    target_service: &str,
) -> Result<(), CliError> {
    if !observation.service.names.contains(&observation.service.id) {
        return Err(inventory_error(format!(
            "systemctl identity {} does not include its Id in Names",
            observation.service.id
        )));
    }
    if !observation.service.names.contains(&observation.query_name) {
        return Err(inventory_error(format!(
            "systemctl identity {} does not include queried inventory identity {}",
            observation.service.id, observation.query_name
        )));
    }
    if observation.service.id != target_service
        && observation.service.names.contains(target_service)
    {
        return Err(inventory_error(format!(
            "target service {target_service} is an alias of unexpected systemd Id {}",
            observation.service.id
        )));
    }
    Ok(())
}

fn reject_shared_executable<DefaultSearchPath>(
    observation: &ServiceObservation,
    target: &ResolvedExecutable,
    target_service: &str,
    cached_default_search_path: &mut Option<Vec<PathBuf>>,
    default_search_path: &DefaultSearchPath,
) -> Result<(), CliError>
where
    DefaultSearchPath: Fn() -> Result<Vec<PathBuf>, CliError>,
{
    if observation.inventory_identity == target_service {
        return Ok(());
    }
    if observation.service.uses_alternate_mount_namespace
        && !observation.service.executables.is_empty()
    {
        return Err(inventory_error(format!(
            "cannot prove systemd executable exclusivity for {} with an alternate mount namespace",
            observation.inventory_identity
        )));
    }
    if observation.service.private_tmp
        && (observation
            .service
            .executables
            .iter()
            .any(|path| path.is_absolute() && is_private_tmp_path(path))
            || observation
                .service
                .exec_search_path
                .iter()
                .any(|path| is_private_tmp_path(path)))
    {
        return Err(private_tmp_error(observation));
    }
    for path in &observation.service.executables {
        if path.is_absolute() {
            reject_absolute_executable(path, observation, target, target_service)?;
        } else {
            reject_simple_executable(
                path,
                observation,
                target,
                target_service,
                cached_default_search_path,
                default_search_path,
            )?;
        }
    }
    Ok(())
}

fn reject_absolute_executable(
    path: &Path,
    observation: &ServiceObservation,
    target: &ResolvedExecutable,
    target_service: &str,
) -> Result<(), CliError> {
    let lexical = normalize_absolute_path(path, "observed systemd executable")?;
    if lexical == target.lexical {
        return Err(shared_executable_error(observation, target, target_service));
    }
    if let Some(observed) = resolve_observed_executable(&lexical)?
        && (observed.resolved == target.resolved || observed.identity == target.identity)
    {
        return Err(shared_executable_error(observation, target, target_service));
    }
    Ok(())
}

fn reject_simple_executable<DefaultSearchPath>(
    path: &Path,
    observation: &ServiceObservation,
    target: &ResolvedExecutable,
    target_service: &str,
    cached_default_search_path: &mut Option<Vec<PathBuf>>,
    default_search_path: &DefaultSearchPath,
) -> Result<(), CliError>
where
    DefaultSearchPath: Fn() -> Result<Vec<PathBuf>, CliError>,
{
    let name = simple_executable_name(path)?;
    let search_path =
        effective_search_path(observation, cached_default_search_path, default_search_path)?;
    if observation.service.private_tmp && search_path.iter().any(|path| is_private_tmp_path(path)) {
        return Err(private_tmp_error(observation));
    }
    for directory in search_path {
        let lexical =
            normalize_absolute_path(&directory.join(name), "systemd executable search candidate")?;
        if lexical == target.lexical {
            return Err(shared_executable_error(observation, target, target_service));
        }
        if let Some(observed) = resolve_search_candidate(&lexical)?
            && (observed.resolved == target.resolved || observed.identity == target.identity)
        {
            return Err(shared_executable_error(observation, target, target_service));
        }
    }
    Ok(())
}

fn is_private_tmp_path(path: &Path) -> bool {
    path.starts_with("/tmp") || path.starts_with("/var/tmp")
}

fn private_tmp_error(observation: &ServiceObservation) -> CliError {
    inventory_error(format!(
        "cannot prove systemd executable exclusivity for {} inside PrivateTmp",
        observation.inventory_identity
    ))
}

fn simple_executable_name(path: &Path) -> Result<&str, CliError> {
    let value = path.to_str().ok_or_else(|| {
        inventory_error(format!(
            "observed systemd executable name is not UTF-8: {}",
            path.display()
        ))
    })?;
    let mut components = path.components();
    if value.is_empty()
        || value.contains('/')
        || !matches!(components.next(), Some(Component::Normal(_)))
        || components.next().is_some()
    {
        return Err(inventory_error(format!(
            "observed systemd executable must be absolute or one simple name: {}",
            path.display()
        )));
    }
    Ok(value)
}

fn effective_search_path<DefaultSearchPath>(
    observation: &ServiceObservation,
    cached_default_search_path: &mut Option<Vec<PathBuf>>,
    default_search_path: &DefaultSearchPath,
) -> Result<Vec<PathBuf>, CliError>
where
    DefaultSearchPath: Fn() -> Result<Vec<PathBuf>, CliError>,
{
    if !observation.service.exec_search_path.is_empty() {
        return Ok(observation.service.exec_search_path.clone());
    }
    if cached_default_search_path.is_none() {
        let search_path = default_search_path()?;
        if search_path.is_empty() {
            return Err(inventory_error(
                "systemd compiled executable search path is empty",
            ));
        }
        *cached_default_search_path = Some(search_path);
    }
    cached_default_search_path.clone().ok_or_else(|| {
        inventory_error("systemd compiled executable search path was not initialized")
    })
}

fn shared_executable_error(
    observation: &ServiceObservation,
    target: &ResolvedExecutable,
    target_service: &str,
) -> CliError {
    inventory_error(format!(
        "systemd unit {} shares target executable {} with {target_service}",
        observation.inventory_identity,
        target.lexical.display()
    ))
}

fn checked_systemctl<RunSystemctl>(
    run_systemctl: &RunSystemctl,
    args: &[&str],
) -> Result<RemoteSystemdCommandOutput, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let owned = args
        .iter()
        .map(|arg| (*arg).to_string())
        .collect::<Vec<_>>();
    checked_systemctl_owned(run_systemctl, &owned)
}

fn checked_systemctl_owned<RunSystemctl>(
    run_systemctl: &RunSystemctl,
    args: &[String],
) -> Result<RemoteSystemdCommandOutput, CliError>
where
    RunSystemctl: Fn(&[String]) -> Result<RemoteSystemdCommandOutput, CliError>,
{
    let output = run_systemctl(args)?;
    if output.exit_code == 0 {
        Ok(output)
    } else {
        Err(inventory_error(format!(
            "systemctl {} failed with exit code {}: {}",
            shell_words::join(args.iter().map(String::as_str)),
            output.exit_code,
            output.stderr.trim()
        )))
    }
}
