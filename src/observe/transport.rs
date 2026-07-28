use clap::Args;
use harness_kernel::errors::CliError;
use harness_workspace::command_context::{AppContext, Execute};

pub use harness_observe::transport::{ObserveFilterArgs, ObserveMode, ObserveScanActionKind};

use harness_observe::application::{
    ObserveDumpRequest, ObserveFilter, ObserveScanRequest, ObserveWatchRequest,
};

use harness_protocol::agent::HookAgent;

use super::application::{self, ObserveDoctorRequest, ObserveRequest};

/// Arguments for `harness observe`.
///
/// Stays here rather than in `harness-observe`: its `Execute` impl reads this
/// crate's own `application::ObserveRequest`, which stays root-private
/// because doctor mode reads `crate::setup`, which `harness-observe` cannot
/// see. `ObserveFilter`/`ObserveScanRequest`/etc moved to `harness-observe`
/// alongside the scan/watch/dump code that reads them.
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
    }
}
