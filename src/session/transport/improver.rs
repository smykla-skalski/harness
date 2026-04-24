use std::path::{Path, PathBuf};

use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::read_text;
use crate::session::service::{self, ImproverTarget};
use crate::workspace::utc_now;

use super::support::{print_json, resolve_project_dir};

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
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let repo_root = PathBuf::from(&local_project);
        let new_contents = read_text(Path::new(&self.new_contents_file)).map_err(|error| {
            CliError::from(CliErrorKind::usage_error(format!(
                "failed to read --new-contents-file {}: {error}",
                self.new_contents_file
            )))
        })?;
        let rel = Path::new(&self.rel_path);
        let outcome = if self.dry_run {
            service::preview_improver_apply(&repo_root, self.target, rel, &new_contents)?
        } else {
            service::apply_improver_apply(
                &repo_root,
                self.target,
                rel,
                &new_contents,
                &self.issue_id,
                &utc_now(),
            )?
        };
        print_json(&outcome)?;
        Ok(0)
    }
}
