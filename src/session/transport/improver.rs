use std::path::Path;

use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::protocol::ImproverApplyRequest;
use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::read_text;
use crate::session::service::ImproverTarget;

use super::support::{daemon_client, print_json, resolve_project_dir};

#[derive(Debug, Clone, Args)]
pub struct SessionImproverApplyArgs {
    /// Session ID.
    pub session_id: String,
    /// Agent ID of the improver.
    #[arg(long)]
    pub actor: String,
    /// Observer-issue ID the improver is addressing.
    #[arg(long)]
    pub issue_id: String,
    /// Target root (`skill`, `plugin`, `local_skill_claude`).
    #[arg(long, value_enum)]
    pub target: ImproverTarget,
    /// Repo-relative path under the target root.
    #[arg(long)]
    pub rel_path: String,
    /// Path to a local file whose contents will replace the target file.
    #[arg(long)]
    pub new_contents_file: String,
    /// Compute the diff without writing.
    #[arg(long)]
    pub dry_run: bool,
    /// Project directory (canonical harness checkout).
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for SessionImproverApplyArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let project_dir = resolve_project_dir(self.project_dir.as_deref());
        let new_contents = read_text(Path::new(&self.new_contents_file)).map_err(|error| {
            CliError::from(CliErrorKind::usage_error(format!(
                "failed to read --new-contents-file {}: {error}",
                self.new_contents_file
            )))
        })?;
        let request = ImproverApplyRequest {
            actor: self.actor.clone(),
            issue_id: self.issue_id.clone(),
            target: self.target,
            rel_path: self.rel_path.clone(),
            new_contents,
            project_dir,
            dry_run: self.dry_run,
        };
        let outcome = daemon_client()?.improver_apply(&self.session_id, &request)?;
        print_json(&outcome)?;
        Ok(0)
    }
}
