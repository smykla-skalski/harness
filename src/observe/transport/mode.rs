use clap::{Subcommand, ValueEnum};

use super::super::application::{
    ObserveActionKind, ObserveDoctorRequest, ObserveDumpRequest, ObserveRequest,
    ObserveScanRequest, ObserveWatchRequest,
};
use super::args::ObserveFilterArgs;

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
    /// Validate observe wiring, session pointers, and compact handoff state.
    Doctor {
        /// Output machine-readable JSON.
        #[arg(long)]
        json: bool,
        /// Project directory to inspect instead of the active environment project.
        #[arg(long)]
        project_dir: Option<String>,
    },
}

impl ObserveMode {
    pub(crate) fn into_request(self) -> ObserveRequest {
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
            Self::Doctor { json, project_dir } => {
                ObserveRequest::Doctor(ObserveDoctorRequest { json, project_dir })
            }
        }
    }
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
    Mute,
    Unmute,
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
            ObserveScanActionKind::Mute => Self::Mute,
            ObserveScanActionKind::Unmute => Self::Unmute,
        }
    }
}
