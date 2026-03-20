use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::Path;

use serde::Serialize;

use crate::errors::{CliError, CliErrorKind};

use super::application::ObserveFilter;
use super::classifier;
use super::output;
use super::session;
use super::types::{FocusPreset, Issue, IssueCategory, IssueCode, IssueSeverity, ScanState};

#[derive(Serialize)]
struct ScanStarted<'a> {
    status: &'static str,
    session: &'a str,
    from_line: usize,
}

/// One-shot scan returning all classified issues.
pub(super) fn scan(path: &Path, from_line: usize) -> Result<(Vec<Issue>, usize), CliError> {
    scan_with_limit(path, from_line, None)
}

/// One-shot scan with optional upper line bound.
fn scan_with_limit(
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

/// Apply focus/category filters, returning an error for invalid values.
fn apply_category_filter(
    filtered: &mut Vec<Issue>,
    filter: &ObserveFilter,
) -> Result<(), CliError> {
    if let Some(ref focus) = filter.focus {
        let Some(preset) = FocusPreset::from_label(focus) else {
            return Err(CliErrorKind::session_parse_error(format!(
                "unknown focus preset '{focus}'. Valid: harness, skills, all"
            ))
            .into());
        };
        let Some(focus_categories) = preset.categories() else {
            return Ok(());
        };
        if let Some(ref category) = filter.category {
            let explicit: Vec<IssueCategory> = category
                .split(',')
                .filter_map(|c| IssueCategory::from_label(c.trim()))
                .collect();
            filtered.retain(|issue| {
                focus_categories.contains(&issue.category) && explicit.contains(&issue.category)
            });
        } else {
            filtered.retain(|issue| focus_categories.contains(&issue.category));
        }
    } else if let Some(ref category) = filter.category {
        let categories: Vec<IssueCategory> = category
            .split(',')
            .filter_map(|c| IssueCategory::from_label(c.trim()))
            .collect();
        if categories.is_empty() {
            return Err(CliErrorKind::session_parse_error(format!(
                "no valid categories in '{category}'. Valid: {}",
                IssueCategory::ALL
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join(", ")
            ))
            .into());
        }
        filtered.retain(|issue| categories.contains(&issue.category));
    }
    Ok(())
}

/// Apply a YAML overrides file (mute list and severity overrides).
fn apply_overrides_file(filtered: &mut Vec<Issue>, overrides_path: &str) -> Result<(), CliError> {
    let content = fs::read_to_string(overrides_path).map_err(|e| {
        CliErrorKind::session_parse_error(format!("cannot read overrides file: {e}"))
    })?;
    let overrides: serde_json::Value = serde_yml::from_str(&content)
        .map_err(|e| CliErrorKind::session_parse_error(format!("invalid overrides YAML: {e}")))?;

    if let Some(mute_list) = overrides["mute"].as_array() {
        let muted: Vec<IssueCode> = mute_list
            .iter()
            .filter_map(|v| v.as_str().and_then(IssueCode::from_label))
            .collect();
        filtered.retain(|issue| !muted.contains(&issue.code));
    }

    if let Some(overrides_map) = overrides["severity_overrides"].as_object() {
        for issue in filtered.iter_mut() {
            let code_str = issue.code.to_string();
            if let Some(new_sev) = overrides_map
                .get(&code_str)
                .and_then(|v| v.as_str())
                .and_then(IssueSeverity::from_label)
            {
                issue.severity = new_sev;
            }
        }
    }
    Ok(())
}

/// Apply filters to a list of issues, validating filter values.
pub(super) fn apply_filters(
    issues: Vec<Issue>,
    filter: &ObserveFilter,
) -> Result<Vec<Issue>, CliError> {
    let mut filtered = issues;

    if let Some(ref severity) = filter.severity {
        let Some(min_severity) = IssueSeverity::from_label(severity) else {
            return Err(CliErrorKind::session_parse_error(format!(
                "unknown severity '{severity}'. Valid: low, medium, critical"
            ))
            .into());
        };
        filtered.retain(|issue| issue.severity >= min_severity);
    }

    apply_category_filter(&mut filtered, filter)?;

    if let Some(ref exclude) = filter.exclude {
        let excluded: Vec<IssueCategory> = exclude
            .split(',')
            .filter_map(|c| IssueCategory::from_label(c.trim()))
            .collect();
        filtered.retain(|issue| !excluded.contains(&issue.category));
    }

    if filter.fixable {
        filtered.retain(|issue| issue.fix_safety.is_fixable());
    }

    if let Some(ref mute) = filter.mute {
        let muted: Vec<IssueCode> = mute
            .split(',')
            .filter_map(|c| IssueCode::from_label(c.trim()))
            .collect();
        filtered.retain(|issue| !muted.contains(&issue.code));
    }

    if let Some(ref overrides_path) = filter.overrides {
        apply_overrides_file(&mut filtered, overrides_path)?;
    }

    Ok(filtered)
}

/// Resolve the effective `from_line`, taking `--from` into account.
pub(super) fn resolve_effective_from_line(
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
pub(super) fn resolve_from(session_path: &Path, value: &str) -> Result<usize, CliError> {
    // 1. Numeric
    if let Ok(line) = value.parse::<usize>() {
        return Ok(line);
    }

    // 2. ISO timestamp (starts with year, contains T)
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

    // 3. Prose substring search
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
fn resolve_effective_bounds(
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

/// Render scan results to stdout using the requested format.
fn render_scan_output(filter: &ObserveFilter, issues: &[Issue], last_line: usize) {
    render_scan_issues(filter, issues);
    render_scan_followups(filter, issues, last_line);
}

fn render_scan_issues(filter: &ObserveFilter, issues: &[Issue]) {
    match filter.format.as_deref().unwrap_or("") {
        "markdown" | "md" => println!("{}", output::render_markdown(issues)),
        "sarif" => println!("{}", output::render_sarif(issues)),
        _ if filter.json => {
            for issue in issues {
                println!("{}", output::render_json(issue));
            }
        }
        _ => {
            for issue in issues {
                println!("{}", output::render_human(issue));
            }
        }
    }
}

fn render_scan_followups(filter: &ObserveFilter, issues: &[Issue], last_line: usize) {
    if let Some(n) = filter.top_causes {
        println!("{}", output::render_top_causes(issues, n));
    }
    if filter.summary {
        println!("{}", output::render_summary(issues, last_line));
    }
}

/// Execute scan mode.
pub(super) fn execute_scan(session_id: &str, filter: &ObserveFilter) -> Result<i32, CliError> {
    let path = session::find_session(session_id, filter.project_hint.as_deref())?;
    let from_line = resolve_effective_from_line(filter, &path)?;

    if filter.json {
        let session = path.to_string_lossy();
        println!(
            "{}",
            serde_json::to_string(&ScanStarted {
                status: "started",
                session: session.as_ref(),
                from_line,
            })
            .expect("scan status serializes")
        );
    }

    let (effective_from, effective_until) = resolve_effective_bounds(&path, filter, from_line)?;

    let (issues, last_line) = scan_with_limit(&path, effective_from, effective_until)?;
    let filtered = apply_filters(issues, filter)?;

    if let Some(ref details_path) = filter.output_details {
        write_details_file(details_path, &filtered)?;
    }

    render_scan_output(filter, &filtered, last_line);

    Ok(0)
}

/// Write full untruncated issue details to a file.
fn write_details_file(path: &str, issues: &[Issue]) -> Result<(), CliError> {
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
pub(super) fn scan_range(
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
