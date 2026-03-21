use std::fs;
use std::io::{BufRead, BufReader};
use std::path::Path;

use crate::errors::{CliError, CliErrorKind};

use super::super::application::ObserveFilter;

/// Resolve the effective `from_line`, taking `--from` into account.
pub(crate) fn resolve_effective_from_line(
    filter: &ObserveFilter,
    session_path: &Path,
) -> Result<usize, CliError> {
    if let Some(ref from_value) = filter.from {
        resolve_from(session_path, from_value)
    } else {
        Ok(filter.from_line)
    }
}

/// Resolve a --from value to a concrete line number.
///
/// Resolution order:
/// 1. Parse as usize -> line number
/// 2. Starts with 4-digit year and contains T -> ISO timestamp
/// 3. Otherwise -> prose substring search
pub(crate) fn resolve_from(session_path: &Path, value: &str) -> Result<usize, CliError> {
    if let Ok(line) = value.parse::<usize>() {
        return Ok(line);
    }

    if value.len() >= 10 && value[..4].chars().all(|c| c.is_ascii_digit()) && value.contains('T') {
        let file = fs::File::open(session_path).map_err(|e| {
            CliErrorKind::session_parse_error(format!("cannot open session file: {e}"))
        })?;
        let reader = BufReader::new(file);
        for (index, line_result) in reader.lines().enumerate() {
            let Ok(line) = line_result else { continue };
            if let Ok(obj) = serde_json::from_str::<serde_json::Value>(line.trim())
                && let Some(ts) = obj["timestamp"].as_str()
                && ts >= value
            {
                return Ok(index);
            }
        }
        return Err(CliErrorKind::session_parse_error(format!(
            "no event at or after timestamp '{value}'"
        ))
        .into());
    }

    let lower_value = value.to_lowercase();
    let file = fs::File::open(session_path)
        .map_err(|e| CliErrorKind::session_parse_error(format!("cannot open session file: {e}")))?;
    let reader = BufReader::new(file);
    for (index, line_result) in reader.lines().enumerate() {
        let Ok(line) = line_result else { continue };
        if line.to_lowercase().contains(&lower_value) {
            return Ok(index);
        }
    }
    Err(CliErrorKind::session_parse_error(format!("no match for --from '{value}'")).into())
}

/// Resolve timestamp-based `--since` / `--until` to effective line bounds.
pub(crate) fn resolve_effective_bounds(
    path: &Path,
    filter: &ObserveFilter,
    from_line: usize,
) -> Result<(usize, Option<usize>), CliError> {
    let effective_from = if let Some(ref ts) = filter.since_timestamp {
        let resolved = resolve_from(path, ts)?;
        resolved.max(from_line)
    } else {
        from_line
    };
    let effective_until = if let Some(ref ts) = filter.until_timestamp {
        let resolved = resolve_from(path, ts)?;
        Some(filter.until_line.map_or(resolved, |ul| ul.min(resolved)))
    } else {
        filter.until_line
    };
    Ok((effective_from, effective_until))
}
