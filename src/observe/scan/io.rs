use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::Path;

use crate::errors::{CliError, CliErrorKind};

use super::super::classifier;
use super::super::types::{Issue, ScanState};

/// One-shot scan with optional upper line bound.
pub(crate) fn scan_with_limit(
    path: &Path,
    from_line: usize,
    until_line: Option<usize>,
) -> Result<(Vec<Issue>, usize), CliError> {
    let file = fs::File::open(path)
        .map_err(|e| CliErrorKind::session_parse_error(format!("cannot open session file: {e}")))?;
    let reader = BufReader::new(file);
    let mut state = ScanState::default();
    let mut issues = Vec::new();
    let mut last_line = from_line;

    for (index, line_result) in reader.lines().enumerate() {
        if index < from_line {
            continue;
        }
        if until_line.is_some_and(|ul| index > ul) {
            break;
        }
        let line = line_result.map_err(|e| {
            CliErrorKind::session_parse_error(format!("read error at line {index}: {e}"))
        })?;
        last_line = index + 1;
        issues.extend(classifier::classify_line(index, &line, &mut state));
    }

    Ok((issues, last_line))
}

/// Write full untruncated issue details to a file.
pub(crate) fn write_details_file(path: &str, issues: &[Issue]) -> Result<(), CliError> {
    let mut file = fs::File::create(path).map_err(|e| {
        CliErrorKind::session_parse_error(format!("cannot create details file: {e}"))
    })?;
    for issue in issues {
        if let Ok(json_str) = serde_json::to_string(issue) {
            let _ = writeln!(file, "{json_str}");
        }
    }
    Ok(())
}

/// Scan a specific line range (`from_line..=to_line`).
pub(crate) fn scan_range(
    path: &Path,
    from_line: usize,
    to_line: usize,
) -> Result<(Vec<Issue>, usize), CliError> {
    let file = fs::File::open(path)
        .map_err(|e| CliErrorKind::session_parse_error(format!("cannot open session file: {e}")))?;
    let reader = BufReader::new(file);
    let mut state = ScanState::default();
    let mut issues = Vec::new();
    let mut last_line = from_line;

    for (index, line_result) in reader.lines().enumerate() {
        if index < from_line {
            continue;
        }
        if index > to_line {
            break;
        }
        let line = line_result.map_err(|e| {
            CliErrorKind::session_parse_error(format!("read error at line {index}: {e}"))
        })?;
        last_line = index + 1;
        issues.extend(classifier::classify_line(index, &line, &mut state));
    }

    Ok((issues, last_line))
}
