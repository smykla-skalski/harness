mod application;
pub(crate) mod classifier;
mod compare;
mod context_cmd;
mod doctor;
mod dump;
pub mod output;
pub(crate) mod patterns;
mod scan;
pub(crate) mod session;
pub(crate) mod types;
mod watch;

use clap::{Args, Subcommand, ValueEnum};

use crate::app::command_context::{AppContext, Execute};
use crate::errors::CliError;

use self::application::{
    ObserveActionKind, ObserveDumpRequest, ObserveFilter, ObserveRequest, ObserveScanRequest,
    ObserveWatchRequest,
};

impl Execute for ObserveArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        application::execute(self.mode.clone().into_request())
    }
}

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
    /// One-shot scan of a session log, plus observer maintenance actions.
    Scan {
        /// Session ID to observe.
        session_id: Option<String>,
        /// Optional maintenance action to run instead of a normal scan.
        #[arg(long, value_enum)]
        action: Option<ObserveScanActionKind>,
        /// Issue ID used by `--action verify`.
        #[arg(long, value_name = "ISSUE_ID")]
        issue_id: Option<String>,
        /// Start verification from this line instead of the issue's first-seen line.
        #[arg(long)]
        since_line: Option<usize>,
        /// Value used by `--action resolve-from`.
        #[arg(long, value_name = "VALUE")]
        value: Option<String>,
        /// First comparison range for `--action compare`, using `FROM:TO` syntax.
        #[arg(long, value_name = "FROM:TO")]
        range_a: Option<String>,
        /// Second comparison range for `--action compare`, using `FROM:TO` syntax.
        #[arg(long, value_name = "FROM:TO")]
        range_b: Option<String>,
        /// Issue codes used by `--action mute` or `--action unmute`.
        #[arg(long, value_name = "CODES")]
        codes: Option<String>,
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
        /// Show context around a specific line instead of a generic dump.
        #[arg(long)]
        context_line: Option<usize>,
        /// Number of lines before and after `--context-line`.
        #[arg(long, default_value = "10")]
        context_window: usize,
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
}

impl ObserveMode {
    fn into_request(self) -> ObserveRequest {
        match self {
            Self::Scan {
                session_id,
                action,
                issue_id,
                since_line,
                value,
                range_a,
                range_b,
                codes,
                filter,
            } => ObserveRequest::Scan(ObserveScanRequest {
                session_id,
                action: action.map(Into::into),
                issue_id,
                since_line,
                value,
                range_a,
                range_b,
                codes,
                filter: filter.into(),
            }),
            Self::Watch {
                session_id,
                poll_interval,
                timeout,
                filter,
            } => ObserveRequest::Watch(ObserveWatchRequest {
                session_id,
                poll_interval,
                timeout,
                filter: filter.into(),
            }),
            Self::Dump {
                session_id,
                context_line,
                context_window,
                from_line,
                to_line,
                filter,
                role,
                tool_name,
                raw_json,
                project_hint,
            } => ObserveRequest::Dump(ObserveDumpRequest {
                session_id,
                context_line,
                context_window,
                from_line,
                to_line,
                filter,
                role,
                tool_name,
                raw_json,
                project_hint,
            }),
        }
    }
}

/// Arguments for `harness observe`.
#[derive(Debug, Clone, Args)]
pub struct ObserveArgs {
    /// Observe subcommand.
    #[command(subcommand)]
    pub mode: ObserveMode,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum ObserveScanActionKind {
    Cycle,
    Status,
    Resume,
    Verify,
    ResolveFrom,
    Compare,
    ListCategories,
    ListFocusPresets,
    Doctor,
    Mute,
    Unmute,
}

impl From<ObserveFilterArgs> for ObserveFilter {
    fn from(value: ObserveFilterArgs) -> Self {
        Self {
            from_line: value.from_line,
            from: value.from,
            focus: value.focus,
            project_hint: value.project_hint,
            json: value.json,
            summary: value.summary,
            severity: value.severity,
            category: value.category,
            exclude: value.exclude,
            fixable: value.fixable,
            mute: value.mute,
            until_line: value.until_line,
            since_timestamp: value.since_timestamp,
            until_timestamp: value.until_timestamp,
            format: value.format,
            overrides: value.overrides,
            top_causes: value.top_causes,
            output: value.output,
            output_details: value.output_details,
        }
    }
}

impl From<ObserveScanActionKind> for ObserveActionKind {
    fn from(value: ObserveScanActionKind) -> Self {
        match value {
            ObserveScanActionKind::Cycle => Self::Cycle,
            ObserveScanActionKind::Status => Self::Status,
            ObserveScanActionKind::Resume => Self::Resume,
            ObserveScanActionKind::Verify => Self::Verify,
            ObserveScanActionKind::ResolveFrom => Self::ResolveFrom,
            ObserveScanActionKind::Compare => Self::Compare,
            ObserveScanActionKind::ListCategories => Self::ListCategories,
            ObserveScanActionKind::ListFocusPresets => Self::ListFocusPresets,
            ObserveScanActionKind::Doctor => Self::Doctor,
            ObserveScanActionKind::Mute => Self::Mute,
            ObserveScanActionKind::Unmute => Self::Unmute,
        }
    }
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

#[cfg(test)]
mod tests {
    #![allow(clippy::absolute_paths, clippy::cognitive_complexity)]

    use std::fs;
    use std::io::Write;
    use std::path::{Path, PathBuf};

    use super::application::ObserveFilter;
    use super::application::maintenance::{load_observer_state, save_observer_state};
    use super::types::{Issue, IssueCode, IssueSeverity, ObserverState};
    use super::{ObserveFilterArgs, classifier, output, redact_details, scan, types};

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
        let filter: ObserveFilter = ObserveFilterArgs {
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
        }
        .into();
        let result = scan::apply_filters(Vec::new(), &filter);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(err.to_string().contains("unknown severity"));
    }

    #[test]
    fn filter_validation_unknown_focus() {
        let filter: ObserveFilter = ObserveFilterArgs {
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
        }
        .into();
        let result = scan::apply_filters(Vec::new(), &filter);
        assert!(result.is_err());
    }

    #[test]
    fn filter_mute_suppresses_issues() {
        let issue = Issue {
            id: "abc123".into(),
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
        let filter: ObserveFilter = ObserveFilterArgs {
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
        }
        .into();
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

        assert!(parsed["id"].is_string());
        assert!(parsed["location"]["line"].is_number());
        assert!(parsed["classification"]["code"].is_string());
        assert!(parsed["classification"]["category"].is_string());
        assert!(parsed["classification"]["severity"].is_string());
        assert!(parsed["classification"]["confidence"].is_string());
        assert!(parsed["classification"]["fingerprint"].is_string());
        assert!(parsed["source"]["role"].is_string());
        assert!(parsed["message"]["summary"].is_string());
        assert!(parsed["message"]["details"].is_string());
        assert!(parsed["remediation"]["safety"].is_string());
        assert!(parsed["remediation"]["available"].is_boolean());
    }

    #[test]
    fn golden_human_output_format() {
        let issue = Issue {
            id: "abc123def456".into(),
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
            id: "abc123".into(),
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
        assert_eq!(parsed["cursor"]["last_line"], 100);
        assert_eq!(parsed["issues"]["total"], 1);
        assert!(parsed["issues"]["by_severity"].is_array());
        assert!(parsed["issues"]["by_category"].is_array());
    }

    #[test]
    fn markdown_output_contains_table() {
        let issue = Issue {
            id: "abc123".into(),
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
            id: "x".into(),
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
        let causes = parsed["causes"].as_array().unwrap();
        assert_eq!(causes.len(), 2);
        assert_eq!(causes[0]["occurrences"], 2);
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
            id: "abc123".into(),
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
        assert_eq!(
            results[0]["properties"]["harnessObserve"]["classification"]["code"],
            "build_or_lint_failure"
        );
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
            id: "h1".into(),
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
            id: "b1".into(),
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

        let filter: ObserveFilter = ObserveFilterArgs {
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
        }
        .into();

        let result = scan::apply_filters(vec![hook_issue, build_issue], &filter).unwrap();
        // hook_denied_tool_call should be muted
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].code, IssueCode::BuildOrLintFailure);
        // severity should be overridden to low
        assert_eq!(result[0].severity, IssueSeverity::Low);
    }
}
