use std::path::Path;

use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::CliError;
use crate::hooks::adapters::HookAgent;
use crate::session::service;

use super::support::{agent_to_str, daemon_client, print_json, resolve_project_dir};

#[derive(Debug, Clone, Args)]
pub struct SessionRecoverLeaderArgs {
    /// Session ID.
    pub session_id: String,
    /// Session policy preset used for managed leader recovery.
    #[arg(long)]
    pub preset: String,
    /// Agent runtime to launch.
    #[arg(long, value_enum)]
    pub runtime: HookAgent,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for SessionRecoverLeaderArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, Path::new(&local_project))?;
        let request = service::build_recovery_tui_request(
            &self.session_id,
            &self.preset,
            agent_to_str(self.runtime),
            &project,
        )?;
        let snapshot = daemon_client()?.start_terminal_managed_agent(&self.session_id, &request)?;
        print_json(&snapshot)?;
        Ok(0)
    }
}
