use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::ErrorKind;
use std::os::unix::fs::MetadataExt as _;
use std::path::{Component, Path, PathBuf};

use crate::errors::CliError;

use super::super::systemd_mount_namespace::ALTERNATE_MOUNT_PROPERTIES;
use super::{inventory_error, validate_unit_name};

#[path = "parser/exec.rs"]
mod exec;

use exec::{parse_exec_properties, parse_exec_search_path};

pub(super) const EXECUTABLE_PROPERTIES: [&str; 13] = [
    "ExecCondition",
    "ExecStartPre",
    "ExecStart",
    "ExecStartPost",
    "ExecReload",
    "ExecStopPre",
    "ExecStop",
    "ExecStopPost",
    "ExecMount",
    "ExecUnmount",
    "ExecRemount",
    "ExecActivate",
    "ExecDeactivate",
];

pub(super) const SHOW_PROPERTIES: [&str; 29] = [
    "Id",
    "Names",
    "LoadState",
    "FragmentPath",
    "DropInPaths",
    "ExecCondition",
    "ExecStartPre",
    "ExecStart",
    "ExecStartPost",
    "ExecReload",
    "ExecStopPre",
    "ExecStop",
    "ExecStopPost",
    "ExecMount",
    "ExecUnmount",
    "ExecRemount",
    "ExecActivate",
    "ExecDeactivate",
    "ExecSearchPath",
    "RootDirectory",
    "RootImage",
    "RootMStack",
    "BindPaths",
    "BindReadOnlyPaths",
    "ExtensionDirectories",
    "ExtensionImages",
    "MountImages",
    "TemporaryFileSystem",
    "PrivateTmp",
];

const REQUIRED_SHOW_PROPERTIES: [&str; 5] =
    ["Id", "Names", "LoadState", "FragmentPath", "DropInPaths"];

pub(super) struct ParsedService {
    pub(super) id: String,
    pub(super) names: BTreeSet<String>,
    pub(super) fragment_path: String,
    pub(super) drop_in_paths: String,
    pub(super) executables: Vec<PathBuf>,
    pub(super) exec_search_path: Vec<PathBuf>,
    pub(super) uses_alternate_mount_namespace: bool,
    pub(super) private_tmp: bool,
}

pub(super) fn parse_service_observation(stdout: &str) -> Result<ParsedService, CliError> {
    let properties = parse_show_properties(stdout)?;
    let id = required_property(&properties.singular, "Id")?;
    validate_unit_name(id, "systemctl show Id")?;
    let names = parse_names(required_property(&properties.singular, "Names")?)?;
    let load_state = required_property(&properties.singular, "LoadState")?;
    let fragment_path = required_property(&properties.singular, "FragmentPath")?;
    let drop_in_paths = required_property(&properties.singular, "DropInPaths")?;
    let executables = effective_executables(
        load_state,
        fragment_path,
        drop_in_paths,
        &properties.exec_commands,
    )?;
    let exec_search_path =
        parse_exec_search_path(optional_property(&properties.singular, "ExecSearchPath"))?;
    let uses_alternate_mount_namespace = ALTERNATE_MOUNT_PROPERTIES
        .iter()
        .any(|name| !optional_property(&properties.singular, name).is_empty());
    let private_tmp = parse_private_tmp(optional_property(&properties.singular, "PrivateTmp"))?;
    Ok(ParsedService {
        id: id.to_string(),
        names,
        fragment_path: fragment_path.to_string(),
        drop_in_paths: drop_in_paths.to_string(),
        executables,
        exec_search_path,
        uses_alternate_mount_namespace,
        private_tmp,
    })
}

fn effective_executables(
    load_state: &str,
    fragment_path: &str,
    drop_in_paths: &str,
    exec_commands: &BTreeMap<&str, Vec<&str>>,
) -> Result<Vec<PathBuf>, CliError> {
    match load_state {
        "loaded" => parse_exec_properties(exec_commands),
        "not-found" => {
            require_empty_effective_sources(
                load_state,
                fragment_path,
                drop_in_paths,
                exec_commands,
            )?;
            Ok(Vec::new())
        }
        "masked" => {
            if !drop_in_paths.is_empty() || has_nonempty_exec_property(exec_commands) {
                return Err(inventory_error(
                    "masked systemd service retained effective drop-ins or Exec commands",
                ));
            }
            validate_mask_fragment(fragment_path)?;
            Ok(Vec::new())
        }
        _ => Err(inventory_error(format!(
            "systemctl show returned uninspectable LoadState={load_state}"
        ))),
    }
}

fn require_empty_effective_sources(
    load_state: &str,
    fragment_path: &str,
    drop_in_paths: &str,
    exec_commands: &BTreeMap<&str, Vec<&str>>,
) -> Result<(), CliError> {
    if fragment_path.is_empty()
        && drop_in_paths.is_empty()
        && !has_nonempty_exec_property(exec_commands)
    {
        Ok(())
    } else {
        Err(inventory_error(format!(
            "LoadState={load_state} retained effective FragmentPath, DropInPaths, or Exec commands"
        )))
    }
}

fn has_nonempty_exec_property(exec_commands: &BTreeMap<&str, Vec<&str>>) -> bool {
    exec_commands
        .values()
        .flatten()
        .any(|value| !value.trim().is_empty())
}

fn validate_mask_fragment(fragment_path: &str) -> Result<(), CliError> {
    let path = normalize_absolute_path(Path::new(fragment_path), "masked unit FragmentPath")?;
    let metadata = fs::symlink_metadata(&path).map_err(|error| {
        inventory_error(format!(
            "inspect masked unit FragmentPath {}: {error}",
            path.display()
        ))
    })?;
    if !metadata.file_type().is_symlink() {
        return Err(inventory_error(format!(
            "masked unit FragmentPath is not a symlink: {}",
            path.display()
        )));
    }
    let resolved = fs::canonicalize(&path).map_err(|error| {
        inventory_error(format!(
            "resolve masked unit FragmentPath {}: {error}",
            path.display()
        ))
    })?;
    let null_device = fs::canonicalize("/dev/null")
        .map_err(|error| inventory_error(format!("resolve /dev/null: {error}")))?;
    if resolved == null_device {
        Ok(())
    } else {
        Err(inventory_error(format!(
            "masked unit FragmentPath does not resolve to /dev/null: {}",
            path.display()
        )))
    }
}

struct ShowProperties<'a> {
    singular: BTreeMap<&'a str, &'a str>,
    exec_commands: BTreeMap<&'a str, Vec<&'a str>>,
}

fn parse_show_properties(stdout: &str) -> Result<ShowProperties<'_>, CliError> {
    let mut singular = BTreeMap::new();
    let mut exec_commands = BTreeMap::<_, Vec<_>>::new();
    for line in stdout.lines() {
        let (name, value) = line
            .split_once('=')
            .ok_or_else(|| inventory_error(format!("malformed systemctl show line: {line}")))?;
        if !SHOW_PROPERTIES.contains(&name) {
            return Err(inventory_error(format!(
                "systemctl show returned unexpected property {name}"
            )));
        }
        if EXECUTABLE_PROPERTIES.contains(&name) {
            exec_commands.entry(name).or_default().push(value);
        } else if singular.insert(name, value).is_some() {
            return Err(inventory_error(format!(
                "systemctl show returned duplicate property {name}"
            )));
        }
    }
    for name in REQUIRED_SHOW_PROPERTIES {
        required_property(&singular, name)?;
    }
    Ok(ShowProperties {
        singular,
        exec_commands,
    })
}

fn optional_property<'a>(properties: &BTreeMap<&str, &'a str>, name: &str) -> &'a str {
    properties.get(name).copied().unwrap_or_default()
}

fn required_property<'a>(
    properties: &BTreeMap<&str, &'a str>,
    name: &str,
) -> Result<&'a str, CliError> {
    properties
        .get(name)
        .copied()
        .ok_or_else(|| inventory_error(format!("systemctl show omitted property {name}")))
}

fn parse_names(value: &str) -> Result<BTreeSet<String>, CliError> {
    let mut names = BTreeSet::new();
    let values = shell_words::split(value)
        .map_err(|error| inventory_error(format!("parse systemctl show Names: {error}")))?;
    for name in values {
        validate_unit_name(&name, "systemctl show Names entry")?;
        if !names.insert(name.clone()) {
            return Err(inventory_error(format!(
                "systemctl show returned duplicate Names entry {name}"
            )));
        }
    }
    if names.is_empty() {
        Err(inventory_error("systemctl show returned empty Names"))
    } else {
        Ok(names)
    }
}

fn parse_private_tmp(value: &str) -> Result<bool, CliError> {
    match value {
        "" | "no" => Ok(false),
        "yes" | "disconnected" => Ok(true),
        _ => Err(inventory_error(format!(
            "systemctl show returned invalid PrivateTmp={value}"
        ))),
    }
}

pub(super) struct ResolvedExecutable {
    pub(super) lexical: PathBuf,
    pub(super) resolved: PathBuf,
    pub(super) identity: FileIdentity,
}

pub(super) struct ObservedExecutable {
    pub(super) resolved: PathBuf,
    pub(super) identity: FileIdentity,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) struct FileIdentity {
    device: u64,
    inode: u64,
}

pub(super) fn resolve_executable(path: &Path, label: &str) -> Result<ResolvedExecutable, CliError> {
    let lexical = normalize_absolute_path(path, label)?;
    let resolved = fs::canonicalize(&lexical).map_err(|error| {
        inventory_error(format!("resolve {label} {}: {error}", lexical.display()))
    })?;
    let metadata = fs::metadata(&resolved).map_err(|error| {
        inventory_error(format!("inspect {label} {}: {error}", resolved.display()))
    })?;
    if !metadata.is_file() {
        return Err(inventory_error(format!(
            "{label} is not a regular file: {}",
            resolved.display()
        )));
    }
    Ok(ResolvedExecutable {
        lexical,
        resolved,
        identity: file_identity(&metadata),
    })
}

pub(super) fn resolve_observed_executable(
    lexical: &Path,
) -> Result<Option<ObservedExecutable>, CliError> {
    let label = "observed systemd executable";
    let resolved = match fs::canonicalize(lexical) {
        Ok(resolved) => resolved,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(inventory_error(format!(
                "resolve {label} {}: {error}",
                lexical.display()
            )));
        }
    };
    let metadata = match fs::metadata(&resolved) {
        Ok(metadata) if metadata.is_file() => metadata,
        Ok(_) => {
            return Err(inventory_error(format!(
                "{label} is not a regular file: {}",
                resolved.display()
            )));
        }
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(inventory_error(format!(
                "inspect {label} {}: {error}",
                resolved.display()
            )));
        }
    };
    Ok(Some(ObservedExecutable {
        resolved,
        identity: file_identity(&metadata),
    }))
}

pub(super) fn resolve_search_candidate(
    lexical: &Path,
) -> Result<Option<ObservedExecutable>, CliError> {
    let label = "systemd executable search candidate";
    let resolved = match fs::canonicalize(lexical) {
        Ok(resolved) => resolved,
        Err(error) if matches!(error.kind(), ErrorKind::NotFound | ErrorKind::NotADirectory) => {
            return Ok(None);
        }
        Err(error) => {
            return Err(inventory_error(format!(
                "resolve {label} {}: {error}",
                lexical.display()
            )));
        }
    };
    let metadata = match fs::metadata(&resolved) {
        Ok(metadata) if metadata.is_file() => metadata,
        Ok(_) => return Ok(None),
        Err(error) if matches!(error.kind(), ErrorKind::NotFound | ErrorKind::NotADirectory) => {
            return Ok(None);
        }
        Err(error) => {
            return Err(inventory_error(format!(
                "inspect {label} {}: {error}",
                resolved.display()
            )));
        }
    };
    Ok(Some(ObservedExecutable {
        resolved,
        identity: file_identity(&metadata),
    }))
}

fn file_identity(metadata: &fs::Metadata) -> FileIdentity {
    FileIdentity {
        device: metadata.dev(),
        inode: metadata.ino(),
    }
}

pub(super) fn normalize_absolute_path(path: &Path, label: &str) -> Result<PathBuf, CliError> {
    if !path.is_absolute() || path.to_str().is_none() {
        return Err(inventory_error(format!(
            "{label} must be an absolute UTF-8 path: {}",
            path.display()
        )));
    }
    let mut normalized = PathBuf::from("/");
    for component in path.components() {
        match component {
            Component::RootDir => {}
            Component::Normal(value) => normalized.push(value),
            Component::CurDir | Component::ParentDir | Component::Prefix(_) => {
                return Err(inventory_error(format!(
                    "{label} contains a noncanonical component: {}",
                    path.display()
                )));
            }
        }
    }
    Ok(normalized)
}

pub(super) fn parse_colon_search_path(value: &str, label: &str) -> Result<Vec<PathBuf>, CliError> {
    if value.is_empty() {
        return Err(inventory_error(format!("{label} is empty")));
    }
    value
        .split(':')
        .map(|path| {
            if path.is_empty() {
                return Err(inventory_error(format!(
                    "{label} contains an empty directory"
                )));
            }
            normalize_absolute_path(Path::new(path), label)
        })
        .collect()
}

#[cfg(test)]
pub(super) fn parse_exec_start(value: &str) -> Result<Vec<PathBuf>, CliError> {
    exec::parse_exec_start(value)
}
