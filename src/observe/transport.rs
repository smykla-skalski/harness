use clap::{Args, Subcommand, ValueEnum};

use crate::app::command_context::{AppContext, Execute};
use crate::errors::CliError;

use super::application::{
    ObserveActionKind, ObserveDumpRequest, ObserveFilter, ObserveRequest, ObserveScanRequest,
    ObserveWatchRequest, execute,
};

impl Execute for ObserveArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        execute(self.mode.clone().into_request())
    }
}

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
