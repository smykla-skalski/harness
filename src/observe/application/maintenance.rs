use std::collections::HashMap;
use std::fs;
use std::io::{self, Write};
use std::path::PathBuf;

use serde_json::json;
use tracing::warn;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_text, write_json_pretty};
use crate::workspace::harness_data_root;

use super::super::ObserveFilterArgs;
use super::super::output;
use super::super::scan;
use super::super::session;
use super::super::types::{
    self, FOCUS_PRESETS, IssueCategory, IssueCode, IssueSeverity, ObserverState,
};

fn state_file_path(session_id: &str) -> PathBuf {
    let observe_dir = harness_data_root().join("observe");
    let _ = fs::create_dir_all(&observe_dir);
    observe_dir.join(format!("{session_id}.state"))
}

pub(super) fn execute_cycle(session_id: &str, project_hint: Option<&str>) -> Result<i32, CliError> {
    let mut observer_state = load_observer_state(session_id)?;
    let from_line = observer_state.cursor;

    let path = session::find_session(session_id, project_hint)?;
    let (issues, last_line) = scan::scan(&path, from_line)?;

    let now = chrono::Utc::now().to_rfc3339();
    observer_state.cursor = last_line;
    observer_state.last_scan_time.clone_from(&now);

    for issue in &issues {
        let existing = observer_state.open_issues.iter_mut().find(|open_issue| {
            open_issue.code == issue.code && open_issue.fingerprint == issue.fingerprint
        });
        if let Some(open_issue) = existing {
            open_issue.occurrence_count += 1;
            open_issue.last_seen_line = issue.line;
        } else {
            observer_state.open_issues.push(types::OpenIssue {
                issue_id: issue.issue_id.clone(),
                code: issue.code,
                fingerprint: issue.fingerprint.clone(),
                first_seen_line: issue.line,
                last_seen_line: issue.line,
                occurrence_count: 1,
                severity: issue.severity,
                category: issue.category,
                summary: issue.summary.clone(),
                fix_safety: issue.fix_safety,
            });
        }
    }

    observer_state.cycle_history.push(types::CycleRecord {
        timestamp: now,
        from_line,
        to_line: last_line,
        new_issues: issues.len(),
        resolved: 0,
    });

    if issues.is_empty() && observer_state.baseline_issue_ids.is_empty() {
        observer_state.baseline_issue_ids = observer_state
            .open_issues
            .iter()
            .map(|open_issue| open_issue.issue_id.clone())
            .collect();
    }

    save_observer_state(session_id, &observer_state)?;

    if issues.is_empty() {
        return Ok(0);
    }

    let critical_count = issues
        .iter()
        .filter(|issue| issue.severity == IssueSeverity::Critical)
        .count();
    let display_end = if last_line > 0 { last_line - 1 } else { 0 };
    println!(
        "Cycle: lines {from_line}-{display_end}, {} new issues ({critical_count} critical)",
        issues.len()
    );
    for issue in &issues {
        println!("{}", output::render_json(issue));
    }
    println!("{}", output::render_summary(&issues, last_line));

    Ok(0)
}

pub(in crate::observe) fn load_observer_state(session_id: &str) -> Result<ObserverState, CliError> {
    let state_path = state_file_path(session_id);
    if state_path.exists() {
        let content = read_text(&state_path).map_err(|error| -> CliError {
            CliErrorKind::session_parse_error(format!("cannot read state file: {error}")).into()
        })?;
        serde_json::from_str(&content).map_err(|error| {
            CliErrorKind::session_parse_error(format!("invalid state file JSON: {error}")).into()
        })
    } else {
        Ok(ObserverState::default_for_session(session_id))
    }
}

pub(in crate::observe) fn save_observer_state(
    session_id: &str,
    state: &ObserverState,
) -> Result<(), CliError> {
    let state_path = state_file_path(session_id);
    write_json_pretty(&state_path, state).map_err(|error| {
        CliErrorKind::session_parse_error(format!("cannot write state file: {error}")).into()
    })
}

pub(super) fn execute_status(
    session_id: &str,
    _project_hint: Option<&str>,
) -> Result<i32, CliError> {
    let state = load_observer_state(session_id)?;

    let by_severity: HashMap<String, usize> = {
        let mut map = HashMap::new();
        for issue in &state.open_issues {
            *map.entry(issue.severity.to_string()).or_default() += 1;
        }
        map
    };

    let recent_cycles: Vec<serde_json::Value> = state
        .cycle_history
        .iter()
        .rev()
        .take(5)
        .map(|cycle| {
            json!({
                "from": cycle.from_line,
                "to": cycle.to_line,
                "new_issues": cycle.new_issues,
                "resolved": cycle.resolved,
            })
        })
        .collect();

    let status = json!({
        "session_id": state.session_id,
        "cursor": state.cursor,
        "last_scan_time": state.last_scan_time,
        "open_issues": state.open_issues.len(),
        "open_issues_by_severity": by_severity,
        "resolved_issues": state.resolved_issue_ids.len(),
        "muted_codes": state.muted_codes.iter().map(ToString::to_string).collect::<Vec<_>>(),
        "has_baseline": state.has_baseline(),
        "handoff_safe": state.handoff_safe(),
        "active_workers": state.active_workers.iter().map(|worker| json!({
            "issue_id": worker.issue_id,
            "target_file": worker.target_file,
            "started_at": worker.started_at,
        })).collect::<Vec<_>>(),
        "cycles": state.cycle_history.len(),
        "recent_cycles": recent_cycles,
    });
    println!(
        "{}",
        serde_json::to_string_pretty(&status).expect("valid JSON")
    );
    Ok(0)
}

pub(super) fn execute_resume(
    session_id: &str,
    filter: &ObserveFilterArgs,
) -> Result<i32, CliError> {
    let state = load_observer_state(session_id)?;
    let mut resumed_filter = filter.clone();
    resumed_filter.from_line = state.cursor;
    scan::execute_scan(session_id, &resumed_filter)
}

pub(super) fn execute_verify(
    session_id: &str,
    issue_id: &str,
    since_line: Option<usize>,
    project_hint: Option<&str>,
) -> Result<i32, CliError> {
    let observer_state = load_observer_state(session_id)?;
    let open_issue = observer_state
        .open_issues
        .iter()
        .find(|issue| issue.issue_id == issue_id);

    let from_line =
        since_line.unwrap_or_else(|| open_issue.map_or(0, |issue| issue.first_seen_line));

    let path = session::find_session(session_id, project_hint)?;
    let (issues, _last_line) = scan::scan(&path, from_line)?;

    let still_reproducing = open_issue.is_some_and(|open_issue| {
        issues.iter().any(|issue| {
            issue.code == open_issue.code && issue.fingerprint == open_issue.fingerprint
        })
    });

    let status = if still_reproducing {
        "still_reproducing"
    } else {
        "potentially_resolved"
    };

    let evidence_lines: Vec<usize> = if let Some(open_issue) = open_issue {
        issues
            .iter()
            .filter(|issue| {
                issue.code == open_issue.code && issue.fingerprint == open_issue.fingerprint
            })
            .map(|issue| issue.line)
            .collect()
    } else {
        Vec::new()
    };

    let result = json!({
        "issue_id": issue_id,
        "status": status,
        "evidence_lines": evidence_lines,
    });
    println!("{result}");
    Ok(0)
}

pub(super) fn execute_resolve_start(
    session_id: &str,
    value: &str,
    project_hint: Option<&str>,
) -> Result<i32, CliError> {
    let path = session::find_session(session_id, project_hint)?;
    let resolved = scan::resolve_from(&path, value)?;

    let method = if value.parse::<usize>().is_ok() {
        "numeric"
    } else if value.len() >= 10
        && value[..4]
            .chars()
            .all(|character| character.is_ascii_digit())
        && value.contains('T')
    {
        "timestamp"
    } else {
        "prose"
    };

    let result = json!({
        "resolved_line": resolved,
        "method": method,
    });
    println!("{result}");
    Ok(0)
}

pub(super) fn execute_list_categories() -> Result<i32, CliError> {
    let stdout = io::stdout();
    let mut out = stdout.lock();
    for category in IssueCategory::ALL {
        writeln!(out, "{}: {}", category, category.description())
            .map_err(|error| CliErrorKind::session_parse_error(format!("write error: {error}")))?;
    }
    Ok(0)
}

pub(super) fn execute_list_focus_presets() -> Result<i32, CliError> {
    let stdout = io::stdout();
    let mut out = stdout.lock();
    for preset in FOCUS_PRESETS {
        writeln!(out, "{}: {}", preset.name, preset.description)
            .map_err(|error| CliErrorKind::session_parse_error(format!("write error: {error}")))?;
    }
    Ok(0)
}

pub(super) fn execute_mute(
    session_id: &str,
    codes: &str,
    _project_hint: Option<&str>,
) -> Result<i32, CliError> {
    let mut state = load_observer_state(session_id)?;
    for code_str in codes.split(',') {
        if let Some(code) = IssueCode::from_label(code_str.trim()) {
            if !state.muted_codes.contains(&code) {
                state.muted_codes.push(code);
            }
        } else {
            warn!(code = code_str.trim(), "unknown issue code");
        }
    }
    save_observer_state(session_id, &state)?;
    println!(
        "Muted codes: {}",
        state
            .muted_codes
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join(", ")
    );
    Ok(0)
}

pub(super) fn execute_unmute(
    session_id: &str,
    codes: &str,
    _project_hint: Option<&str>,
) -> Result<i32, CliError> {
    let mut state = load_observer_state(session_id)?;
    for code_str in codes.split(',') {
        if let Some(code) = IssueCode::from_label(code_str.trim()) {
            state.muted_codes.retain(|muted| *muted != code);
        }
    }
    save_observer_state(session_id, &state)?;
    println!(
        "Muted codes: {}",
        state
            .muted_codes
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join(", ")
    );
    Ok(0)
}
