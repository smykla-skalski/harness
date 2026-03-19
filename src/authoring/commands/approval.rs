use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::authoring::application::AuthoringApplication;
use crate::errors::{CliError, CliErrorKind};

impl Execute for ApprovalBeginArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
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
    #[arg(long, value_parser = clap::builder::PossibleValuesParser::new([crate::kernel::skills::SKILL_NEW]))]
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
    if !matches!(mode, "interactive" | "bypass") {
        return Err(CliErrorKind::usage_error(format!("invalid approval mode: {mode}")).into());
    }
    AuthoringApplication::begin_approval_flow(mode, suite_dir)?;
    Ok(0)
}
