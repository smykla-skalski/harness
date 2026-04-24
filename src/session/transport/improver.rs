use std::path::{Path, PathBuf};

use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::client::DaemonClient;
use crate::daemon::protocol::ImproverApplyRequest;
use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::read_text;
use crate::session::service::{self, ImproverApplyOutcome, ImproverTarget};
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
    /// Project directory hint used only to help locate the session on disk
    /// when the daemon is not running. The actual write always targets the
    /// session's own project directory, so a bogus `--project-dir` cannot
    /// escape the session's repo root.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for SessionImproverApplyArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let new_contents = read_text(Path::new(&self.new_contents_file)).map_err(|error| {
            CliError::from(CliErrorKind::usage_error(format!(
                "failed to read --new-contents-file {}: {error}",
                self.new_contents_file
            )))
        })?;
        let outcome = if let Some(client) = DaemonClient::try_connect() {
            let request = ImproverApplyRequest {
                actor: self.actor.clone(),
                issue_id: self.issue_id.clone(),
                target: self.target,
                rel_path: self.rel_path.clone(),
                new_contents,
                project_dir: local_project,
                dry_run: self.dry_run,
            };
            client.improver_apply(&self.session_id, &request)?
        } else {
            improver_apply_local(self, &PathBuf::from(&local_project), &new_contents)?
        };
        print_json(&outcome)?;
        Ok(0)
    }
}

fn improver_apply_local(
    args: &SessionImproverApplyArgs,
    local_project: &Path,
    new_contents: &str,
) -> Result<ImproverApplyOutcome, CliError> {
    let rel = Path::new(&args.rel_path);
    service::improver_apply(
        &args.session_id,
        &args.actor,
        args.target,
        rel,
        new_contents,
        &args.issue_id,
        args.dry_run,
        local_project,
        &utc_now(),
    )
}
