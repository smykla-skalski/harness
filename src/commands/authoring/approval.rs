use clap::Args;

use crate::core_defs::utc_now;
use crate::errors::{CliError, CliErrorKind, cow};
use crate::workflow::author::{ApprovalMode, AuthorWorkflowState, write_author_state};

// =========================================================================
// approval_begin
// =========================================================================

/// Arguments for `harness approval-begin`.
#[derive(Debug, Clone, Args)]
pub struct ApprovalBeginArgs {
    /// Managed skill to initialize.
    #[arg(long, value_parser = clap::builder::PossibleValuesParser::new([crate::rules::SKILL_NEW]))]
    pub skill: String,
    /// Approval mode.
    #[arg(long, value_parser = ["interactive", "bypass"])]
    pub mode: String,
    /// Optional suite directory for the approval state.
    #[arg(long)]
    pub suite_dir: Option<String>,
}

/// Begin suite:new approval flow.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn approval_begin(mode: &str, suite_dir: Option<&str>) -> Result<i32, CliError> {
    let approval_mode = match mode {
        "interactive" => ApprovalMode::Interactive,
        "bypass" => ApprovalMode::Bypass,
        _ => {
            return Err(CliErrorKind::usage_error(cow!("invalid approval mode: {mode}")).into());
        }
    };

    let state = AuthorWorkflowState::new(approval_mode, suite_dir.map(String::from), utc_now());

    write_author_state(&state)?;
    Ok(0)
}
