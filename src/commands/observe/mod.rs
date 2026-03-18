pub mod classifier;
mod compare;
mod context_cmd;
mod doctor;
mod dump;
pub mod output;
pub mod patterns;
mod scan;
pub mod session;
pub mod types;
mod watch;

use std::collections::HashMap;
use std::fs;
use std::io::{self, Write};
use std::path::PathBuf;

use clap::{Args, Subcommand};
use serde_json::json;
use tracing::warn;

use crate::commands::{CommandContext, Execute};
use crate::core_defs::harness_data_root;
use crate::errors::{CliError, CliErrorKind};
use crate::io::{read_text, write_json_pretty};

impl Execute for ObserveArgs {
    fn execute(&self, _context: &CommandContext) -> Result<i32, CliError> {
        execute(self.mode.clone())
    }
}

use self::types::{FOCUS_PRESETS, IssueCategory, IssueCode, IssueSeverity, ObserverState};

// Re-exports consumed by classifier submodules via `super::`.
pub(crate) use self::dump::tool_result_text;

/// Minimum text length to bother displaying in dump mode.
const MIN_DUMP_TEXT_LENGTH: usize = 5;

/// Maximum characters shown per dump line.
const DUMP_TRUNCATE_LENGTH: usize = 500;

/// Maximum characters stored in issue detail fields.
const MAX_DETAIL_LENGTH: usize = 2000;

/// Shared filter arguments for observe scan/watch modes.
#[derive(Debug, Clone, Args)]
pub struct ObserveFilterArgs {
    /// Start scanning from this line number.
    #[arg(long, default_value = "0")]
    pub from_line: usize,
    /// Resolve start position: line number, ISO timestamp, or prose substring.
    #[arg(long)]
    pub from: Option<String>,
    /// Focus preset: harness, skills, or all.
    #[arg(long)]
    pub focus: Option<String>,
    /// Narrow session search to this project directory name.
    #[arg(long)]
    pub project_hint: Option<String>,
    /// Output as JSON lines.
    #[arg(long)]
    pub json: bool,
    /// Print summary at end.
    #[arg(long)]
    pub summary: bool,
    /// Filter by minimum severity: low, medium, critical.
    #[arg(long)]
    pub severity: Option<String>,
    /// Filter by category (comma-separated).
    #[arg(long)]
    pub category: Option<String>,
    /// Exclude categories (comma-separated).
    #[arg(long)]
    pub exclude: Option<String>,
    /// Only show fixable issues.
    #[arg(long)]
    pub fixable: bool,
    /// Mute specific issue codes (comma-separated).
    #[arg(long)]
    pub mute: Option<String>,
    /// Stop scanning at this line number.
    #[arg(long)]
    pub until_line: Option<usize>,
    /// Only include events at or after this ISO timestamp.
    #[arg(long)]
    pub since_timestamp: Option<String>,
    /// Only include events at or before this ISO timestamp.
    #[arg(long)]
    pub until_timestamp: Option<String>,
    /// Output format: json (default), markdown, sarif.
    #[arg(long)]
    pub format: Option<String>,
    /// Path to YAML overrides config file.
    #[arg(long)]
    pub overrides: Option<String>,
    /// Show top N root causes grouped by issue code.
    #[arg(long)]
    pub top_causes: Option<usize>,
    /// Write truncated issues to this file instead of stdout (watch mode).
    #[arg(long)]
    pub output: Option<String>,
    /// Write full untruncated issues to this file.
    #[arg(long)]
    pub output_details: Option<String>,
}

/// Observe subcommands.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum ObserveMode {
    /// One-shot scan of a session log.
    Scan {
        /// Session ID to observe.
        session_id: String,
        /// Filter arguments.
        #[command(flatten)]
        filter: ObserveFilterArgs,
    },
    /// Continuously poll for new events.
    Watch {
        /// Session ID to observe.
        session_id: String,
        /// Seconds between polls.
        #[arg(long, default_value = "3")]
        poll_interval: u64,
        /// Exit after this many seconds of no new events.
        #[arg(long, default_value = "90")]
        timeout: u64,
        /// Filter arguments.
        #[command(flatten)]
        filter: ObserveFilterArgs,
    },
    /// Raw event dump without classification.
    Dump {
        /// Session ID to observe.
        session_id: String,
        /// Start from this line number.
        #[arg(long)]
        from_line: Option<usize>,
        /// Stop at this line number.
        #[arg(long)]
        to_line: Option<usize>,
        /// Text filter (case-insensitive substring match).
        #[arg(long)]
        filter: Option<String>,
        /// Role filter (comma-separated: user,assistant).
        #[arg(long)]
        role: Option<String>,
        /// Filter by tool name (e.g. Bash, Read, Write).
        #[arg(long)]
        tool_name: Option<String>,
        /// Output raw JSON instead of formatted text.
        #[arg(long)]
        raw_json: bool,
        /// Narrow session search to this project directory name.
        #[arg(long)]
        project_hint: Option<String>,
    },
    /// Run one observer cycle: read cursor, scan, update cursor, report.
    Cycle {
        /// Session ID to observe.
        session_id: String,
        /// Narrow session search to this project directory name.
        #[arg(long)]
        project_hint: Option<String>,
    },
    /// Show events around a specific line.
    Context {
        /// Session ID to observe.
        session_id: String,
        /// Target line number.
        #[arg(long)]
        line: usize,
        /// Number of lines before/after.
        #[arg(long, default_value = "10")]
        window: usize,
        /// Narrow session search to this project directory name.
        #[arg(long)]
        project_hint: Option<String>,
    },
    /// Show observer state for a session.
    Status {
        /// Session ID to query.
        session_id: String,
        /// Narrow session search to this project directory name.
        #[arg(long)]
        project_hint: Option<String>,
    },
    /// Resume scanning from the last cursor position.
    Resume {
        /// Session ID to resume.
        session_id: String,
        /// Filter arguments.
        #[command(flatten)]
        filter: ObserveFilterArgs,
    },
    /// Verify whether a specific issue still reproduces.
    Verify {
        /// Session ID to check.
        session_id: String,
        /// Issue ID to verify.
        issue_id: String,
        /// Start verification from this line.
        #[arg(long)]
        since_line: Option<usize>,
        /// Narrow session search to this project directory name.
        #[arg(long)]
        project_hint: Option<String>,
    },
    /// Resolve a --from value to a concrete line number.
    ResolveStart {
        /// Session ID to search.
        session_id: String,
        /// Value to resolve: line number, ISO timestamp, or prose substring.
        value: String,
        /// Narrow session search to this project directory name.
        #[arg(long)]
        project_hint: Option<String>,
    },
    /// List all valid issue categories.
    ListCategories,
    /// List all focus presets.
    ListFocusPresets,
    /// Validate observer setup.
    Doctor,
    /// Add issue codes to the mute list.
    Mute {
        /// Session ID to update.
        session_id: String,
        /// Issue codes to mute (comma-separated).
        codes: String,
        /// Narrow session search to this project directory name.
        #[arg(long)]
        project_hint: Option<String>,
    },
    /// Remove issue codes from the mute list.
    Unmute {
        /// Session ID to update.
        session_id: String,
        /// Issue codes to unmute (comma-separated).
        codes: String,
        /// Narrow session search to this project directory name.
        #[arg(long)]
        project_hint: Option<String>,
    },
    /// Compare issues between two line ranges.
    Compare {
        /// Session ID to compare.
        session_id: String,
        /// First range start line.
        #[arg(long)]
        from_a: usize,
        /// First range end line.
        #[arg(long)]
        to_a: usize,
        /// Second range start line.
        #[arg(long)]
        from_b: usize,
        /// Second range end line.
        #[arg(long)]
        to_b: usize,
        /// Narrow session search to this project directory name.
        #[arg(long)]
        project_hint: Option<String>,
    },
}

/// Arguments for `harness observe`.
#[derive(Debug, Clone, Args)]
pub struct ObserveArgs {
    /// Observe subcommand.
    #[command(subcommand)]
    pub mode: ObserveMode,
}

/// Truncate text to at most `max_len` bytes at a valid UTF-8 char boundary.
fn truncate_at(text: &str, max_len: usize) -> &str {
    if text.len() <= max_len {
        text
    } else {
        &text[..text.floor_char_boundary(max_len)]
    }
}

/// Cap issue detail text at construction time.
pub(crate) fn truncate_details(text: &str) -> String {
    truncate_at(text, MAX_DETAIL_LENGTH).to_string()
}

/// Redact absolute paths and env var values from details text.
#[must_use]
pub(crate) fn redact_details(text: &str) -> String {
    use std::sync::LazyLock;
    static HOME_PATH_RE: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"/(?:Users|home)/[^/\s]+/").expect("valid regex"));
    static ENV_VALUE_RE: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"([A-Z_]{3,})=\S+").expect("valid regex"));

    let redacted = HOME_PATH_RE.replace_all(text, "<home>/");
    ENV_VALUE_RE
        .replace_all(&redacted, "$1=<redacted>")
        .into_owned()
}

/// Execute the observe command in the given mode.
///
/// # Errors
/// Returns `CliError` on session lookup or parse failures.
pub fn execute(mode: ObserveMode) -> Result<i32, CliError> {
    match mode {
        ObserveMode::Scan { session_id, filter } => scan::execute_scan(&session_id, &filter),
        ObserveMode::Watch {
            session_id,
            poll_interval,
            timeout,
            filter,
        } => watch::execute_watch(&session_id, poll_interval, timeout, &filter),
        ObserveMode::Dump {
            session_id,
            from_line,
            to_line,
            filter,
            role,
            tool_name,
            raw_json,
            project_hint,
        } => dump::execute_dump(
            &session_id,
            &dump::DumpOptions {
                from_line: from_line.unwrap_or(0),
                to_line,
                text_filter: filter.as_deref(),
                roles: role.as_deref(),
                tool_name: tool_name.as_deref(),
                raw_json,
            },
            project_hint.as_deref(),
        ),
        ObserveMode::Cycle {
            session_id,
            project_hint,
        } => execute_cycle(&session_id, project_hint.as_deref()),
        ObserveMode::Context {
            session_id,
            line,
            window,
            project_hint,
        } => context_cmd::execute_context(&session_id, line, window, project_hint.as_deref()),
        ObserveMode::Status {
            session_id,
            project_hint,
        } => execute_status(&session_id, project_hint.as_deref()),
        ObserveMode::Resume { session_id, filter } => execute_resume(&session_id, &filter),
        ObserveMode::Verify {
            session_id,
            issue_id,
            since_line,
            project_hint,
        } => execute_verify(&session_id, &issue_id, since_line, project_hint.as_deref()),
        ObserveMode::ResolveStart {
            session_id,
            value,
            project_hint,
        } => execute_resolve_start(&session_id, &value, project_hint.as_deref()),
        ObserveMode::ListCategories => execute_list_categories(),
        ObserveMode::ListFocusPresets => execute_list_focus_presets(),
        ObserveMode::Doctor => doctor::execute_doctor(),
        ObserveMode::Mute {
            session_id,
            codes,
            project_hint,
        } => execute_mute(&session_id, &codes, project_hint.as_deref()),
        ObserveMode::Unmute {
            session_id,
            codes,
            project_hint,
        } => execute_unmute(&session_id, &codes, project_hint.as_deref()),
        ObserveMode::Compare {
            session_id,
            from_a,
            to_a,
            from_b,
            to_b,
            project_hint,
        } => compare::execute_compare(
            &session_id,
            from_a,
            to_a,
            from_b,
            to_b,
            project_hint.as_deref(),
        ),
    }
}

/// State file path for a session observer.
fn state_file_path(session_id: &str) -> PathBuf {
    let observe_dir = harness_data_root().join("observe");
    let _ = fs::create_dir_all(&observe_dir);
    observe_dir.join(format!("{session_id}.state"))
}

/// Execute one observer cycle: read cursor, scan, update cursor, report.
fn execute_cycle(session_id: &str, project_hint: Option<&str>) -> Result<i32, CliError> {
    let mut observer_state = load_observer_state(session_id)?;
    let from_line = observer_state.cursor;

    let path = session::find_session(session_id, project_hint)?;
    let (issues, last_line) = scan::scan(&path, from_line)?;

    // Update observer state
    let now = chrono::Utc::now().to_rfc3339();
    observer_state.cursor = last_line;
    observer_state.last_scan_time.clone_from(&now);

    // Update open issues
    for issue in &issues {
        let existing = observer_state
            .open_issues
            .iter_mut()
            .find(|oi| oi.code == issue.code && oi.fingerprint == issue.fingerprint);
        if let Some(oi) = existing {
            oi.occurrence_count += 1;
            oi.last_seen_line = issue.line;
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

    // Record cycle
    observer_state.cycle_history.push(types::CycleRecord {
        timestamp: now,
        from_line,
        to_line: last_line,
        new_issues: issues.len(),
        resolved: 0,
    });

    // Save baseline on first clean scan
    if issues.is_empty() && observer_state.baseline_issue_ids.is_empty() {
        observer_state.baseline_issue_ids = observer_state
            .open_issues
            .iter()
            .map(|oi| oi.issue_id.clone())
            .collect();
    }

    save_observer_state(session_id, &observer_state)?;

    if issues.is_empty() {
        return Ok(0);
    }

    // Report
    let critical_count = issues
        .iter()
        .filter(|i| i.severity == IssueSeverity::Critical)
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

/// Load or create observer state for a session.
fn load_observer_state(session_id: &str) -> Result<ObserverState, CliError> {
    let state_path = state_file_path(session_id);
    if state_path.exists() {
        let content = read_text(&state_path).map_err(|e| -> CliError {
            CliErrorKind::session_parse_error(format!("cannot read state file: {e}")).into()
        })?;
        serde_json::from_str(&content).map_err(|e| {
            CliErrorKind::session_parse_error(format!("invalid state file JSON: {e}")).into()
        })
    } else {
        Ok(ObserverState::default_for_session(session_id))
    }
}

/// Save observer state via shared atomic JSON persistence.
fn save_observer_state(session_id: &str, state: &ObserverState) -> Result<(), CliError> {
    let state_path = state_file_path(session_id);
    write_json_pretty(&state_path, state).map_err(|e| {
        CliErrorKind::session_parse_error(format!("cannot write state file: {e}")).into()
    })
}

/// Show observer state for a session.
fn execute_status(session_id: &str, _project_hint: Option<&str>) -> Result<i32, CliError> {
    let state = load_observer_state(session_id)?;

    // Group open issues by severity for the summary
    let by_severity: HashMap<String, usize> = {
        let mut map = HashMap::new();
        for issue in &state.open_issues {
            *map.entry(issue.severity.to_string()).or_default() += 1;
        }
        map
    };

    // Recent cycle trend
    let recent_cycles: Vec<serde_json::Value> = state
        .cycle_history
        .iter()
        .rev()
        .take(5)
        .map(|c| {
            json!({
                "from": c.from_line,
                "to": c.to_line,
                "new_issues": c.new_issues,
                "resolved": c.resolved,
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
        "active_workers": state.active_workers.iter().map(|w| json!({
            "issue_id": w.issue_id,
            "target_file": w.target_file,
            "started_at": w.started_at,
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

/// Resume scanning from the last cursor position.
fn execute_resume(session_id: &str, filter: &ObserveFilterArgs) -> Result<i32, CliError> {
    let state = load_observer_state(session_id)?;
    let mut resumed_filter = filter.clone();
    resumed_filter.from_line = state.cursor;
    scan::execute_scan(session_id, &resumed_filter)
}

/// Verify whether a specific issue still reproduces.
fn execute_verify(
    session_id: &str,
    issue_id: &str,
    since_line: Option<usize>,
    project_hint: Option<&str>,
) -> Result<i32, CliError> {
    let observer_state = load_observer_state(session_id)?;
    let open_issue = observer_state
        .open_issues
        .iter()
        .find(|i| i.issue_id == issue_id);

    let from_line = since_line.unwrap_or_else(|| open_issue.map_or(0, |i| i.first_seen_line));

    let path = session::find_session(session_id, project_hint)?;
    let (issues, _last_line) = scan::scan(&path, from_line)?;

    let still_reproducing = open_issue.is_some_and(|oi| {
        issues
            .iter()
            .any(|i| i.code == oi.code && i.fingerprint == oi.fingerprint)
    });

    let status = if still_reproducing {
        "still_reproducing"
    } else {
        "potentially_resolved"
    };

    let evidence_lines: Vec<usize> = if let Some(oi) = open_issue {
        issues
            .iter()
            .filter(|i| i.code == oi.code && i.fingerprint == oi.fingerprint)
            .map(|i| i.line)
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

/// Resolve a --from value to a concrete line number and print it.
fn execute_resolve_start(
    session_id: &str,
    value: &str,
    project_hint: Option<&str>,
) -> Result<i32, CliError> {
    let path = session::find_session(session_id, project_hint)?;
    let resolved = scan::resolve_from(&path, value)?;

    let method = if value.parse::<usize>().is_ok() {
        "numeric"
    } else if value.len() >= 10
        && value[..4].chars().all(|c| c.is_ascii_digit())
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

/// List all valid issue categories with descriptions.
///
/// # Errors
/// Returns `CliError` if stdout is not writable.
fn execute_list_categories() -> Result<i32, CliError> {
    let stdout = io::stdout();
    let mut out = stdout.lock();
    for cat in IssueCategory::ALL {
        writeln!(out, "{}: {}", cat, cat.description())
            .map_err(|e| CliErrorKind::session_parse_error(format!("write error: {e}")))?;
    }
    Ok(0)
}

/// List all focus presets with descriptions.
///
/// # Errors
/// Returns `CliError` if stdout is not writable.
fn execute_list_focus_presets() -> Result<i32, CliError> {
    let stdout = io::stdout();
    let mut out = stdout.lock();
    for preset in FOCUS_PRESETS {
        writeln!(out, "{}: {}", preset.name, preset.description)
            .map_err(|e| CliErrorKind::session_parse_error(format!("write error: {e}")))?;
    }
    Ok(0)
}

/// Add issue codes to the mute list.
fn execute_mute(
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

/// Remove issue codes from the mute list.
fn execute_unmute(
    session_id: &str,
    codes: &str,
    _project_hint: Option<&str>,
) -> Result<i32, CliError> {
    let mut state = load_observer_state(session_id)?;
    for code_str in codes.split(',') {
        if let Some(code) = IssueCode::from_label(code_str.trim()) {
            state.muted_codes.retain(|c| *c != code);
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

#[cfg(test)]
mod tests {
    #![allow(clippy::absolute_paths, clippy::cognitive_complexity)]

    use std::path::{Path, PathBuf};

    use super::types::Issue;
    use super::*;
    use super::{classifier, output};

    fn write_session_file(dir: &Path, lines: &[&str]) -> PathBuf {
        let path = dir.join("test-session.jsonl");
        let mut file = fs::File::create(&path).unwrap();
        for line in lines {
            writeln!(file, "{line}").unwrap();
        }
        path
    }

    #[test]
    fn resolve_from_numeric() {
        let tmp = tempfile::tempdir().unwrap();
        let path = write_session_file(tmp.path(), &["{}", "{}"]);
        let result = scan::resolve_from(&path, "500");
        assert_eq!(result.unwrap(), 500);
    }

    #[test]
    fn resolve_from_timestamp() {
        let tmp = tempfile::tempdir().unwrap();
        let lines = [
            r#"{"timestamp":"2026-03-15T10:00:00Z","message":{"role":"user","content":"hello"}}"#,
            r#"{"timestamp":"2026-03-15T11:00:00Z","message":{"role":"user","content":"world"}}"#,
            r#"{"timestamp":"2026-03-15T12:00:00Z","message":{"role":"user","content":"end"}}"#,
        ];
        let path = write_session_file(tmp.path(), &lines);
        let result = scan::resolve_from(&path, "2026-03-15T11:00:00Z");
        assert_eq!(result.unwrap(), 1);
    }

    #[test]
    fn resolve_from_prose() {
        let tmp = tempfile::tempdir().unwrap();
        let lines = [
            r#"{"message":{"role":"user","content":"starting bootstrap"}}"#,
            r#"{"message":{"role":"user","content":"running tests now"}}"#,
        ];
        let path = write_session_file(tmp.path(), &lines);
        let result = scan::resolve_from(&path, "running tests");
        assert_eq!(result.unwrap(), 1);
    }

    #[test]
    fn resolve_from_no_match() {
        let tmp = tempfile::tempdir().unwrap();
        let path = write_session_file(
            tmp.path(),
            &[r#"{"message":{"role":"user","content":"hello"}}"#],
        );
        let result = scan::resolve_from(&path, "nonexistent phrase");
        assert!(result.is_err());
    }

    #[test]
    fn filter_validation_unknown_severity() {
        let filter = ObserveFilterArgs {
            from_line: 0,
            from: None,
            focus: None,
            project_hint: None,
            json: false,
            summary: false,
            severity: Some("extreme".into()),
            category: None,
            exclude: None,
            fixable: false,
            mute: None,
            output: None,
            format: None,
            overrides: None,
            top_causes: None,
            output_details: None,
            since_timestamp: None,
            until_line: None,
            until_timestamp: None,
        };
        let result = scan::apply_filters(Vec::new(), &filter);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(err.to_string().contains("unknown severity"));
    }

    #[test]
    fn filter_validation_unknown_focus() {
        let filter = ObserveFilterArgs {
            from_line: 0,
            from: None,
            focus: Some("invalid_preset".into()),
            project_hint: None,
            json: false,
            summary: false,
            severity: None,
            category: None,
            exclude: None,
            fixable: false,
            mute: None,
            format: None,
            overrides: None,
            top_causes: None,
            output: None,
            output_details: None,
            since_timestamp: None,
            until_line: None,
            until_timestamp: None,
        };
        let result = scan::apply_filters(Vec::new(), &filter);
        assert!(result.is_err());
    }

    #[test]
    fn filter_mute_suppresses_issues() {
        let issue = Issue {
            issue_id: "abc123".into(),
            line: 1,
            code: IssueCode::BuildOrLintFailure,
            category: types::IssueCategory::BuildError,
            severity: IssueSeverity::Critical,
            confidence: types::Confidence::High,
            fix_safety: types::FixSafety::AutoFixSafe,
            summary: "test".into(),
            details: String::new(),
            fingerprint: "test".into(),
            source_role: types::MessageRole::Assistant,
            source_tool: None,
            fix_target: None,
            fix_hint: None,
            evidence_excerpt: None,
        };
        let filter = ObserveFilterArgs {
            from_line: 0,
            from: None,
            focus: None,
            project_hint: None,
            json: false,
            summary: false,
            severity: None,
            category: None,
            exclude: None,
            fixable: false,
            mute: Some("build_or_lint_failure".into()),
            format: None,
            overrides: None,
            top_causes: None,
            output: None,
            output_details: None,
            since_timestamp: None,
            until_line: None,
            until_timestamp: None,
        };
        let result = scan::apply_filters(vec![issue], &filter).unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn redact_details_strips_home_paths() {
        let text = "Error in /Users/alice/Projects/foo/src/main.rs";
        let redacted = redact_details(text);
        assert!(redacted.contains("<home>/"));
        assert!(!redacted.contains("alice"));
    }

    #[test]
    fn redact_details_strips_env_values() {
        let text = "KUBECONFIG=/data/k3d-config SECRET_KEY=abc123 other text";
        let redacted = redact_details(text);
        assert!(redacted.contains("KUBECONFIG=<redacted>"));
        assert!(redacted.contains("SECRET_KEY=<redacted>"));
    }

    #[test]
    fn state_file_lifecycle_two_cycles() {
        let session_id = "lifecycle-test-session";
        let tmp_dir = tempfile::tempdir().unwrap();
        let session_file = write_session_file(
            tmp_dir.path(),
            &[
                r#"{"timestamp":"2026-03-15T10:00:00Z","message":{"role":"user","content":"hello"}}"#,
                r#"{"timestamp":"2026-03-15T10:01:00Z","message":{"role":"user","content":"world"}}"#,
            ],
        );

        // Use XDG isolation for state files
        let data_dir = tmp_dir.path().join("xdg_data");
        fs::create_dir_all(&data_dir).unwrap();
        temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(data_dir.to_str().unwrap())),
                ("HOME", Some(tmp_dir.path().to_str().unwrap())),
            ],
            || {
                // First scan
                let (issues, last_line) = scan::scan(&session_file, 0).unwrap();
                assert_eq!(last_line, 2);

                // Save state after first cycle
                let mut state = ObserverState::default_for_session(session_id);
                state.cursor = last_line;
                state.last_scan_time = "2026-03-15T10:02:00Z".to_string();
                save_observer_state(session_id, &state).unwrap();

                // Load and verify cursor advanced
                let loaded = load_observer_state(session_id).unwrap();
                assert_eq!(loaded.cursor, 2);
                assert_eq!(loaded.session_id, session_id);

                // Second cycle from cursor
                let (issues2, last_line2) = scan::scan(&session_file, loaded.cursor).unwrap();
                assert!(issues2.is_empty());
                assert_eq!(last_line2, 2);

                // Verify state file is atomic (exists, not corrupted)
                let loaded2 = load_observer_state(session_id).unwrap();
                assert_eq!(loaded2.cursor, 2);

                drop(issues);
            },
        );
    }

    #[test]
    fn golden_scan_json_output() {
        let mut state = types::ScanState::default();
        let issues = classifier::check_text_for_issues(
            42,
            types::MessageRole::User,
            "error[E0308]: mismatched types\n  expected u32, found &str",
            Some(types::SourceTool::Bash),
            &mut state,
        );
        assert!(!issues.is_empty());

        let rendered = output::render_json(&issues[0]);
        let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();

        // Verify exact JSON shape
        assert!(parsed["issue_id"].is_string());
        assert!(parsed["line"].is_number());
        assert!(parsed["code"].is_string());
        assert!(parsed["category"].is_string());
        assert!(parsed["severity"].is_string());
        assert!(parsed["confidence"].is_string());
        assert!(parsed["fix_safety"].is_string());
        assert!(parsed["summary"].is_string());
        assert!(parsed["details"].is_string());
        assert!(parsed["fingerprint"].is_string());
        assert!(parsed["fixable"].is_boolean());
    }

    #[test]
    fn golden_human_output_format() {
        let issue = Issue {
            issue_id: "abc123def456".into(),
            line: 42,
            code: IssueCode::BuildOrLintFailure,
            category: types::IssueCategory::BuildError,
            severity: IssueSeverity::Critical,
            confidence: types::Confidence::High,
            fix_safety: types::FixSafety::AutoFixSafe,
            summary: "Build failed".into(),
            details: "error[E0308]".into(),
            fingerprint: "build_or_lint_failure".into(),
            source_role: types::MessageRole::Assistant,
            source_tool: None,
            fix_target: Some("src/main.rs".into()),
            fix_hint: Some("Fix the type".into()),
            evidence_excerpt: None,
        };
        let rendered = output::render_human(&issue);
        assert!(rendered.contains("[CRITICAL/high]"));
        assert!(rendered.contains("L42"));
        assert!(rendered.contains("build_error/build_or_lint_failure"));
        assert!(rendered.contains("fix: src/main.rs"));
        assert!(rendered.contains("hint: Fix the type"));
    }

    #[test]
    fn golden_summary_json_shape() {
        let issue = Issue {
            issue_id: "abc123".into(),
            line: 1,
            code: IssueCode::BuildOrLintFailure,
            category: types::IssueCategory::BuildError,
            severity: IssueSeverity::Critical,
            confidence: types::Confidence::High,
            fix_safety: types::FixSafety::AutoFixSafe,
            summary: "test".into(),
            details: String::new(),
            fingerprint: "test".into(),
            source_role: types::MessageRole::Assistant,
            source_tool: None,
            fix_target: None,
            fix_hint: None,
            evidence_excerpt: None,
        };
        let rendered = output::render_summary(&[issue], 100);
        let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();
        assert_eq!(parsed["status"], "done");
        assert_eq!(parsed["last_line"], 100);
        assert_eq!(parsed["total_issues"], 1);
        assert!(parsed["by_severity"].is_object());
        assert!(parsed["by_category"].is_object());
    }

    #[test]
    fn markdown_output_contains_table() {
        let issue = Issue {
            issue_id: "abc123".into(),
            line: 42,
            code: IssueCode::BuildOrLintFailure,
            category: types::IssueCategory::BuildError,
            severity: IssueSeverity::Critical,
            confidence: types::Confidence::High,
            fix_safety: types::FixSafety::AutoFixSafe,
            summary: "Build failed".into(),
            details: String::new(),
            fingerprint: "test".into(),
            source_role: types::MessageRole::Assistant,
            source_tool: None,
            fix_target: None,
            fix_hint: None,
            evidence_excerpt: None,
        };
        let rendered = output::render_markdown(&[issue]);
        assert!(rendered.contains("# Observe report"));
        assert!(rendered.contains("Build failed"));
        assert!(rendered.contains("Total: 1 issues"));
    }

    #[test]
    fn top_causes_groups_by_code() {
        let make_issue = |code: IssueCode, summary: &str| Issue {
            issue_id: "x".into(),
            line: 1,
            code,
            category: types::IssueCategory::BuildError,
            severity: IssueSeverity::Critical,
            confidence: types::Confidence::High,
            fix_safety: types::FixSafety::AutoFixSafe,
            summary: summary.into(),
            details: String::new(),
            fingerprint: "x".into(),
            source_role: types::MessageRole::Assistant,
            source_tool: None,
            fix_target: None,
            fix_hint: None,
            evidence_excerpt: None,
        };
        let issues = vec![
            make_issue(IssueCode::BuildOrLintFailure, "Build 1"),
            make_issue(IssueCode::BuildOrLintFailure, "Build 2"),
            make_issue(IssueCode::HookDeniedToolCall, "Hook denied"),
        ];
        let rendered = output::render_top_causes(&issues, 2);
        let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();
        let causes = parsed["top_causes"].as_array().unwrap();
        assert_eq!(causes.len(), 2);
        assert_eq!(causes[0]["count"], 2);
    }

    #[test]
    fn scan_with_limit_stops_at_bound() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_session_file(
            dir.path(),
            &[
                r#"{"message":{"role":"user","content":"line zero"}}"#,
                r#"{"message":{"role":"user","content":"line one"}}"#,
                r#"{"message":{"role":"user","content":"line two"}}"#,
                r#"{"message":{"role":"user","content":"line three"}}"#,
            ],
        );
        let (_, last_line) = scan::scan_range(&path, 0, 1).unwrap();
        assert_eq!(last_line, 2); // scanned lines 0 and 1
    }

    #[test]
    fn sarif_output_has_correct_shape() {
        let issue = Issue {
            issue_id: "abc123".into(),
            line: 42,
            code: IssueCode::BuildOrLintFailure,
            category: types::IssueCategory::BuildError,
            severity: IssueSeverity::Critical,
            confidence: types::Confidence::High,
            fix_safety: types::FixSafety::AutoFixSafe,
            summary: "Build failed".into(),
            details: String::new(),
            fingerprint: "test".into(),
            source_role: types::MessageRole::Assistant,
            source_tool: None,
            fix_target: Some("src/main.rs".into()),
            fix_hint: None,
            evidence_excerpt: None,
        };
        let rendered = output::render_sarif(&[issue]);
        let parsed: serde_json::Value = serde_json::from_str(&rendered).unwrap();
        assert_eq!(parsed["version"], "2.1.0");
        let runs = parsed["runs"].as_array().unwrap();
        assert_eq!(runs.len(), 1);
        let results = runs[0]["results"].as_array().unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0]["ruleId"], "build_or_lint_failure");
        assert_eq!(results[0]["level"], "error");
    }

    #[test]
    fn scan_range_returns_bounded_results() {
        let dir = tempfile::tempdir().unwrap();
        let path = write_session_file(
            dir.path(),
            &[
                r#"{"message":{"role":"user","content":"line zero"}}"#,
                r#"{"message":{"role":"user","content":"line one"}}"#,
                r#"{"message":{"role":"user","content":"line two"}}"#,
            ],
        );
        let (_, last) = scan::scan_range(&path, 1, 1).unwrap();
        assert_eq!(last, 2); // scanned only line 1
    }

    #[test]
    fn observer_state_active_workers_tracks() {
        let mut state = ObserverState::default_for_session("test");
        assert!(!state.handoff_safe()); // no scan done yet
        state.last_scan_time = "2026-03-16T00:00:00Z".into();
        assert!(state.handoff_safe()); // no workers, scan done
        state.active_workers.push(types::ActiveWorker {
            issue_id: "abc".into(),
            target_file: "src/main.rs".into(),
            started_at: "2026-03-16T00:00:00Z".into(),
        });
        assert!(!state.handoff_safe()); // worker active
    }

    #[test]
    fn overrides_yaml_mutes_and_adjusts_severity() {
        let dir = tempfile::tempdir().unwrap();
        let overrides_path = dir.path().join("overrides.yaml");
        fs::write(
            &overrides_path,
            "mute:\n  - hook_denied_tool_call\nseverity_overrides:\n  build_or_lint_failure: low\n",
        )
        .unwrap();

        let hook_issue = Issue {
            issue_id: "h1".into(),
            line: 1,
            code: IssueCode::HookDeniedToolCall,
            category: types::IssueCategory::HookFailure,
            severity: IssueSeverity::Medium,
            confidence: types::Confidence::High,
            fix_safety: types::FixSafety::TriageRequired,
            summary: "hook denied".into(),
            details: String::new(),
            fingerprint: "test".into(),
            source_role: types::MessageRole::User,
            source_tool: None,
            fix_target: None,
            fix_hint: None,
            evidence_excerpt: None,
        };
        let build_issue = Issue {
            issue_id: "b1".into(),
            line: 2,
            code: IssueCode::BuildOrLintFailure,
            category: types::IssueCategory::BuildError,
            severity: IssueSeverity::Critical,
            confidence: types::Confidence::High,
            fix_safety: types::FixSafety::AutoFixSafe,
            summary: "build fail".into(),
            details: String::new(),
            fingerprint: "test".into(),
            source_role: types::MessageRole::Assistant,
            source_tool: None,
            fix_target: None,
            fix_hint: None,
            evidence_excerpt: None,
        };

        let filter = ObserveFilterArgs {
            from_line: 0,
            from: None,
            focus: None,
            project_hint: None,
            json: false,
            summary: false,
            severity: None,
            category: None,
            exclude: None,
            fixable: false,
            mute: None,
            format: None,
            overrides: Some(overrides_path.to_string_lossy().into_owned()),
            top_causes: None,
            output: None,
            output_details: None,
            since_timestamp: None,
            until_line: None,
            until_timestamp: None,
        };

        let result = scan::apply_filters(vec![hook_issue, build_issue], &filter).unwrap();
        // hook_denied_tool_call should be muted
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].code, IssueCode::BuildOrLintFailure);
        // severity should be overridden to low
        assert_eq!(result[0].severity, IssueSeverity::Low);
    }
}
