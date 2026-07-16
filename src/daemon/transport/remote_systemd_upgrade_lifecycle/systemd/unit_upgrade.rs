use std::path::Path;

use fs_err as fs;

use crate::errors::CliError;

use super::super::files::{io_error, write_bytes_atomic};
use super::super::model::{FileMetadata, SYSTEMD_START_TIMEOUT};

pub(crate) fn upgrade_unit_to_notify(path: &Path) -> Result<(), CliError> {
    let metadata = FileMetadata::read(path)?;
    let contents = fs::read_to_string(path)
        .map_err(|error| io_error(format!("read systemd unit {}: {error}", path.display())))?;
    let upgraded = notify_unit_contents(&contents)?;
    if upgraded != contents {
        write_bytes_atomic(path, upgraded.as_bytes(), metadata)?;
    }
    Ok(())
}

pub(crate) fn unit_requires_notify_upgrade(path: &Path) -> Result<bool, CliError> {
    let contents = fs::read_to_string(path)
        .map_err(|error| io_error(format!("read systemd unit {}: {error}", path.display())))?;
    notify_unit_contents(&contents).map(|normalized| normalized != contents)
}

fn notify_unit_contents(contents: &str) -> Result<String, CliError> {
    let newline = if contents.contains("\r\n") {
        "\r\n"
    } else {
        "\n"
    };
    let trailing_newline = contents.ends_with('\n');
    let mut lines = contents.lines().map(str::to_string).collect::<Vec<_>>();
    let (start, end) = service_section_range(&lines)?;
    let normalized = normalize_service_lines(&lines[start + 1..end])?;
    lines.splice(start + 1..end, normalized);
    let mut result = lines.join(newline);
    if trailing_newline {
        result.push_str(newline);
    }
    Ok(result)
}

fn service_section_range(lines: &[String]) -> Result<(usize, usize), CliError> {
    let mut sections = lines
        .iter()
        .enumerate()
        .filter_map(|(index, line)| (line.trim() == "[Service]").then_some(index));
    let start = sections
        .next()
        .ok_or_else(|| io_error("systemd unit is missing [Service]"))?;
    if sections.next().is_some() {
        return Err(io_error(
            "systemd unit must contain exactly one [Service] section",
        ));
    }
    let end = lines
        .iter()
        .enumerate()
        .skip(start + 1)
        .find_map(|(index, line)| {
            let trimmed = line.trim();
            (trimmed.starts_with('[') && trimmed.ends_with(']')).then_some(index)
        })
        .unwrap_or(lines.len());
    Ok((start, end))
}

fn normalize_service_lines(lines: &[String]) -> Result<Vec<String>, CliError> {
    let type_index = find_supported_type(lines)?;
    let mut normalized = Vec::with_capacity(lines.len() + 3);
    for (index, line) in lines.iter().enumerate() {
        if index == type_index {
            normalized.push("Type=notify".to_string());
            normalized.push("NotifyAccess=main".to_string());
            normalized.push(format!("TimeoutStartSec={SYSTEMD_START_TIMEOUT}"));
            normalized.push("KillMode=control-group".to_string());
        } else if !is_managed_runtime_directive(line) {
            normalized.push(line.clone());
        }
    }
    Ok(normalized)
}

fn is_managed_runtime_directive(line: &str) -> bool {
    directive(line).is_some_and(|(key, _)| {
        matches!(
            key,
            "Type" | "NotifyAccess" | "TimeoutStartSec" | "KillMode"
        )
    })
}

fn find_supported_type(lines: &[String]) -> Result<usize, CliError> {
    let mut found = None;
    for (index, line) in lines.iter().enumerate() {
        let Some(("Type", value)) = directive(line) else {
            continue;
        };
        if !matches!(value, "simple" | "notify") {
            return Err(io_error(format!(
                "systemd service Type must be simple or notify, found {value}"
            )));
        }
        if found.is_none() {
            found = Some(index);
        }
    }
    found.ok_or_else(|| io_error("systemd service must define Type=simple or Type=notify"))
}

fn directive(line: &str) -> Option<(&str, &str)> {
    let trimmed = line.trim();
    if trimmed.starts_with('#') || trimmed.starts_with(';') {
        return None;
    }
    trimmed
        .split_once('=')
        .map(|(key, value)| (key.trim(), value.trim()))
}

#[cfg(test)]
pub(crate) fn notify_unit_contents_for_tests(contents: &str) -> Result<String, CliError> {
    notify_unit_contents(contents)
}
