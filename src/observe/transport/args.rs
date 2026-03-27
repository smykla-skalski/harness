use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::CliError;
use crate::hooks::adapters::HookAgent;

use super::super::application::execute;
use super::mode::ObserveMode;

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

/// Arguments for `harness observe`.
#[derive(Debug, Clone, Args)]
pub struct ObserveArgs {
    /// Narrow canonical session resolution to a specific agent runtime.
    #[arg(long, value_enum)]
    pub agent: Option<HookAgent>,
    /// Shared observer state ID under the harness project ledger.
    #[arg(long, default_value = "project-default")]
    pub observe_id: String,
    /// Observe subcommand.
    #[command(subcommand)]
    pub mode: ObserveMode,
}

impl Execute for ObserveArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        execute(
            self.mode
                .clone()
                .into_request(self.agent, self.observe_id.clone()),
        )
    }
}

impl ObserveFilterArgs {
    pub(crate) fn into_filter(
        self,
        agent: Option<HookAgent>,
        observe_id: String,
    ) -> super::super::application::ObserveFilter {
        super::super::application::ObserveFilter {
            from_line: self.from_line,
            from: self.from,
            focus: self.focus,
            project_hint: self.project_hint,
            json: self.json,
            summary: self.summary,
            severity: self.severity,
            category: self.category,
            exclude: self.exclude,
            fixable: self.fixable,
            mute: self.mute,
            until_line: self.until_line,
            since_timestamp: self.since_timestamp,
            until_timestamp: self.until_timestamp,
            format: self.format,
            overrides: self.overrides,
            top_causes: self.top_causes,
            output: self.output,
            output_details: self.output_details,
            agent,
            observe_id,
        }
    }
}

impl From<ObserveFilterArgs> for super::super::application::ObserveFilter {
    fn from(value: ObserveFilterArgs) -> Self {
        value.into_filter(None, "project-default".to_string())
    }
}
