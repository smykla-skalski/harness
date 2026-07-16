use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::errors::CliError;

use super::{EXECUTABLE_PROPERTIES, inventory_error, normalize_absolute_path};

pub(super) fn parse_exec_start(value: &str) -> Result<Vec<PathBuf>, CliError> {
    let value = value.trim();
    if value.is_empty() {
        return Ok(Vec::new());
    }
    Ok(vec![parse_exec_record(value)?])
}

pub(super) fn parse_exec_properties(
    properties: &BTreeMap<&str, Vec<&str>>,
) -> Result<Vec<PathBuf>, CliError> {
    EXECUTABLE_PROPERTIES
        .iter()
        .try_fold(Vec::new(), |mut paths, property| {
            let values = properties.get(property).map_or(&[][..], Vec::as_slice);
            paths.extend(parse_exec_property(property, values)?);
            Ok(paths)
        })
}

fn parse_exec_property(property: &str, values: &[&str]) -> Result<Vec<PathBuf>, CliError> {
    if values.len() > 1 && values.iter().any(|value| value.trim().is_empty()) {
        return Err(inventory_error(format!(
            "systemd {property} mixed empty and nonempty property values"
        )));
    }
    values.iter().try_fold(Vec::new(), |mut paths, value| {
        paths.extend(parse_exec_start(value)?);
        Ok(paths)
    })
}

pub(super) fn parse_exec_search_path(value: &str) -> Result<Vec<PathBuf>, CliError> {
    if value.trim().is_empty() {
        return Ok(Vec::new());
    }
    shell_words::split(value)
        .map_err(|error| inventory_error(format!("parse systemd ExecSearchPath: {error}")))?
        .into_iter()
        .map(|path| normalize_absolute_path(Path::new(&path), "systemd ExecSearchPath entry"))
        .collect()
}

fn parse_exec_record(record: &str) -> Result<PathBuf, CliError> {
    const RECORD_PREFIX: &str = "{ path=";
    const ARGV_DELIMITER: &str = " ; argv[]=";
    const METADATA_DELIMITER: &str = " ; ignore_errors=";

    let record = record.strip_prefix(RECORD_PREFIX).ok_or_else(|| {
        inventory_error(format!(
            "systemd Exec record omitted leading path: {record}"
        ))
    })?;
    let record = record
        .strip_suffix('}')
        .ok_or_else(|| inventory_error(format!("unterminated systemd Exec record: {record}")))?;
    let record = record.trim_end();
    let (path, command_and_metadata) = record.split_once(ARGV_DELIMITER).ok_or_else(|| {
        inventory_error(format!(
            "systemd Exec record omitted argv[] after path: {record}"
        ))
    })?;
    if command_and_metadata.contains(ARGV_DELIMITER) {
        return Err(inventory_error(format!(
            "systemd Exec record contained an ambiguous argv[] delimiter: {record}"
        )));
    }
    let (_, metadata) = command_and_metadata
        .rsplit_once(METADATA_DELIMITER)
        .ok_or_else(|| {
            inventory_error(format!(
                "systemd Exec record omitted generated metadata: {record}"
            ))
        })?;
    validate_exec_metadata(metadata)?;
    parse_exec_path(path)
}

fn validate_exec_metadata(metadata: &str) -> Result<(), CliError> {
    let mut fields = metadata.split(" ; ");
    let ignore_errors = fields.next().unwrap_or_default();
    if !matches!(ignore_errors, "yes" | "no") {
        return Err(inventory_error(format!(
            "systemd Exec has invalid ignore_errors metadata: {ignore_errors}"
        )));
    }
    for name in ["start_time", "stop_time", "pid", "code", "status"] {
        let field = fields
            .next()
            .ok_or_else(|| inventory_error(format!("systemd Exec omitted {name} metadata")))?;
        let value = field
            .strip_prefix(name)
            .and_then(|value| value.strip_prefix('='));
        validate_metadata_value(name, field, value)?;
    }
    if let Some(field) = fields.next() {
        Err(inventory_error(format!(
            "systemd Exec has unexpected trailing metadata: {field}"
        )))
    } else {
        Ok(())
    }
}

fn validate_metadata_value(name: &str, field: &str, value: Option<&str>) -> Result<(), CliError> {
    if value.is_none_or(|value| {
        value.is_empty()
            || value.contains('{')
            || value.contains('}')
            || value.chars().any(char::is_control)
    }) {
        return Err(invalid_metadata(name, field));
    }
    if name == "pid" && value.is_none_or(|value| value.parse::<u32>().is_err()) {
        return Err(invalid_metadata(name, field));
    }
    if matches!(name, "start_time" | "stop_time")
        && value.is_none_or(|value| !valid_exec_timestamp(value))
    {
        return Err(invalid_metadata(name, field));
    }
    if name == "status" && value.is_none_or(|value| !valid_exec_status(value)) {
        return Err(invalid_metadata(name, field));
    }
    Ok(())
}

fn invalid_metadata(name: &str, field: &str) -> CliError {
    inventory_error(format!("systemd Exec has invalid {name} metadata: {field}"))
}

fn valid_exec_timestamp(value: &str) -> bool {
    value
        .strip_prefix('[')
        .and_then(|value| value.strip_suffix(']'))
        .is_some_and(|value| !value.is_empty())
}

fn valid_exec_status(value: &str) -> bool {
    let (number, signal) = value
        .split_once('/')
        .map_or((value, None), |(number, signal)| (number, Some(signal)));
    number.parse::<u32>().is_ok()
        && signal.is_none_or(|signal| {
            !signal.is_empty()
                && !signal.contains('/')
                && signal.bytes().all(|byte| byte.is_ascii_graphic())
        })
}

fn parse_exec_path(value: &str) -> Result<PathBuf, CliError> {
    if value.is_empty() || value.chars().any(char::is_control) {
        return Err(inventory_error(format!(
            "systemd Exec path is empty or contains control characters: {value:?}"
        )));
    }
    Ok(PathBuf::from(value))
}
