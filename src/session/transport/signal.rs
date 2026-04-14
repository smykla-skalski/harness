use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::errors::CliError;
use crate::session::service;

use super::support::{print_json, resolve_project_dir};

#[derive(Debug, Clone, Args)]
pub struct SignalSendArgs {
    /// Session ID.
    pub session_id: String,
    /// Agent ID receiving the signal.
    pub agent_id: String,
    /// Runtime command name for the signal.
    #[arg(long)]
    pub command: String,
    /// Human-readable message payload.
    #[arg(long)]
    pub message: String,
    /// Optional action hint for the target agent.
    #[arg(long)]
    pub action_hint: Option<String>,
    /// Agent ID of the caller.
    #[arg(long)]
    pub actor: String,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for SignalSendArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, local_project.as_ref())?;
        let signal = service::send_signal(
            &self.session_id,
            &self.agent_id,
            &self.command,
            &self.message,
            self.action_hint.as_deref(),
            &self.actor,
            &project,
        )?;
        print_json(&signal)?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct SignalListArgs {
    /// Session ID.
    pub session_id: String,
    /// Filter to a single agent.
    #[arg(long)]
    pub agent: Option<String>,
    /// Output as JSON.
    #[arg(long)]
    pub json: bool,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for SignalListArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, local_project.as_ref())?;
        let signals = service::list_signals(&self.session_id, self.agent.as_deref(), &project)?;
        if self.json {
            print_json(&signals)?;
        } else {
            for signal in &signals {
                println!(
                    "[{:?}] {} -> {} ({}) {}",
                    signal.status,
                    signal.signal.source_agent,
                    signal.agent_id,
                    signal.runtime,
                    signal.signal.command,
                );
            }
        }
        Ok(0)
    }
}
