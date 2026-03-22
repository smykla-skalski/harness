use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::CliError;
use crate::run::application::{RunApplication, StartRunRequest};
use crate::workspace::shorten_path;

impl Execute for StartArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let result = RunApplication::start(&StartRunRequest {
            suite: &self.suite,
            run_id: self.run_id.as_deref(),
            profile: &self.profile,
            repo_root: self.repo_root.as_deref(),
            run_root: self.run_root.as_deref(),
        })?;
        println!("{}", shorten_path(&result.run_dir));
        Ok(0)
    }
}

/// Arguments for `harness run start`.
#[derive(Debug, Clone, Args)]
pub struct StartArgs {
    /// Suite Markdown path or name.
    #[arg(long)]
    pub suite: String,
    /// Run ID override. Defaults to a timestamp-based manual run id.
    #[arg(long)]
    pub run_id: Option<String>,
    /// Suite profile to run (e.g. single-zone or multi-zone).
    #[arg(long)]
    pub profile: String,
    /// Repo root to record in run metadata.
    #[arg(long)]
    pub repo_root: Option<String>,
    /// Parent directory to create the run in.
    #[arg(long)]
    pub run_root: Option<String>,
}
