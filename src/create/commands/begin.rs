use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::create::application::CreateApplication;
use crate::errors::CliError;
use crate::kernel::skills::SKILL_CREATE;

impl Execute for CreateBeginArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        begin(
            &self.repo_root,
            &self.feature,
            &self.mode,
            &self.suite_dir,
            &self.suite_name,
        )
    }
}

/// Arguments for `harness create-begin`.
#[derive(Debug, Clone, Args)]
pub struct CreateBeginArgs {
    /// Managed skill to initialize.
    #[arg(long, value_parser = clap::builder::PossibleValuesParser::new([SKILL_CREATE]))]
    pub skill: String,
    /// Repository worktree for source discovery and validation.
    #[arg(long)]
    pub repo_root: String,
    /// Feature or capability being authored.
    #[arg(long)]
    pub feature: String,
    /// Create mode.
    #[arg(long, value_parser = ["interactive", "bypass"])]
    pub mode: String,
    /// Suite directory for this session.
    #[arg(long)]
    pub suite_dir: String,
    /// Suite name recorded in state and defaults.
    #[arg(long)]
    pub suite_name: String,
}

// =========================================================================
// begin
// =========================================================================

/// Begin a suite:create workspace session.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn begin(
    repo_root: &str,
    feature: &str,
    mode: &str,
    suite_dir: &str,
    suite_name: &str,
) -> Result<i32, CliError> {
    CreateApplication::begin_session(repo_root, feature, mode, suite_dir, suite_name)?;
    Ok(0)
}
