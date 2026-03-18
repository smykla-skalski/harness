use clap::Args;

use crate::app::command_context::{CommandContext, Execute};
use crate::authoring::workflow::{ApprovalMode, AuthorWorkflowState, write_author_state};
use crate::core_defs::utc_now;
use crate::errors::{CliError, CliErrorKind};

impl Execute for ApprovalBeginArgs {
    fn execute(&self, _context: &CommandContext) -> Result<i32, CliError> {
        approval_begin(&self.mode, self.suite_dir.as_deref())
    }
}

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
            return Err(CliErrorKind::usage_error(format!("invalid approval mode: {mode}")).into());
        }
    };

    let state = AuthorWorkflowState::new(approval_mode, suite_dir.map(String::from), utc_now());

    write_author_state(&state)?;
    Ok(0)
}
