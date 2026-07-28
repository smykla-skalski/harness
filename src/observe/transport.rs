use clap::Args;
use harness_kernel::errors::CliError;
use harness_workspace::command_context::{AppContext, Execute};

pub use harness_observe::transport::{ObserveFilterArgs, ObserveMode, ObserveScanActionKind};

use crate::hooks::adapters::HookAgent;

use super::application::{
    self, ObserveActionKind, ObserveDoctorRequest, ObserveDumpRequest, ObserveFilter,
    ObserveRequest, ObserveScanRequest, ObserveWatchRequest,
};

/// Arguments for `harness observe`.
///
/// Stays here rather than in `harness-observe`: its `Execute` impl and the
/// `build_request`/`build_filter` conversions below read this crate's own
/// `application::ObserveRequest`/`ObserveFilter`, which stay root-private.
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
        application::execute(build_request(
            self.mode.clone(),
            self.agent,
            self.observe_id.clone(),
        ))
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
            ObserveScanActionKind::Mute => Self::Mute,
            ObserveScanActionKind::Unmute => Self::Unmute,
        }
    }
}

fn build_filter(
    args: ObserveFilterArgs,
    agent: Option<HookAgent>,
    observe_id: String,
) -> ObserveFilter {
    ObserveFilter {
        from_line: args.from_line,
        from: args.from,
        focus: args.focus,
        project_hint: args.project_hint,
        json: args.json,
        summary: args.summary,
        severity: args.severity,
        category: args.category,
        exclude: args.exclude,
        fixable: args.fixable,
        mute: args.mute,
        until_line: args.until_line,
        since_timestamp: args.since_timestamp,
        until_timestamp: args.until_timestamp,
        format: args.format,
        overrides: args.overrides,
        top_causes: args.top_causes,
        output: args.output,
        output_details: args.output_details,
        agent,
        observe_id,
    }
}

impl From<ObserveFilterArgs> for ObserveFilter {
    fn from(value: ObserveFilterArgs) -> Self {
        build_filter(value, None, "project-default".to_string())
    }
}

fn build_request(
    mode: ObserveMode,
    agent: Option<HookAgent>,
    observe_id: String,
) -> ObserveRequest {
    match mode {
        ObserveMode::Scan {
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
            filter: build_filter(filter, agent, observe_id),
        }),
        ObserveMode::Watch {
            session_id,
            poll_interval,
            timeout,
            filter,
        } => ObserveRequest::Watch(ObserveWatchRequest {
            session_id,
            poll_interval,
            timeout,
            filter: build_filter(filter, agent, observe_id),
        }),
        ObserveMode::Dump {
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
            agent,
        }),
        ObserveMode::Doctor { json, project_dir } => ObserveRequest::Doctor(ObserveDoctorRequest {
            json,
            project_dir,
            agent,
        }),
        // `ObserveMode` is `#[non_exhaustive]` from this crate's perspective
        // now that it lives in `harness-observe`; the four variants above are
        // its complete set today.
        _ => unreachable!("ObserveMode has no variants beyond Scan/Watch/Dump/Doctor"),
    }
}
