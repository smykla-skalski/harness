use std::path::PathBuf;

use clap::Args;

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::client::DaemonClient;
use crate::daemon::protocol::{AdoptSessionRequest, ObserveSessionRequest};
use crate::errors::CliError;
use crate::hooks::adapters::HookAgent;
use crate::session::types::SessionRole;
use crate::session::{observe, service};

use super::support::{agent_to_str, daemon_client, print_json, resolve_project_dir};

#[derive(Debug, Clone, Args)]
pub struct SessionStartArgs {
    /// Human-readable context or goal for this session.
    #[arg(long)]
    pub context: String,
    /// Short human-readable session name.
    #[arg(long, default_value = "")]
    pub title: String,
    /// Project directory (defaults to cwd).
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
    /// Explicit session ID (auto-generated if omitted).
    #[arg(long)]
    pub session_id: Option<String>,
    /// Session policy preset.
    #[arg(long)]
    pub policy_preset: Option<String>,
}

impl Execute for SessionStartArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let project = resolve_project_dir(self.project_dir.as_deref());
        let state = service::start_session_with_policy(
            &self.context,
            &self.title,
            project.as_ref(),
            self.session_id.as_deref(),
            self.policy_preset.as_deref(),
        )?;
        print_json(&state)?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct SessionJoinArgs {
    /// Session ID to join.
    pub session_id: String,
    /// Role to join as.
    #[arg(long, value_enum)]
    pub role: SessionRole,
    /// Agent runtime.
    #[arg(long, value_enum)]
    pub runtime: HookAgent,
    /// Fallback role to use when joining as leader and a leader already exists.
    #[arg(long, value_enum)]
    pub fallback_role: Option<SessionRole>,
    /// Comma-separated capability tags.
    #[arg(long)]
    pub capabilities: Option<String>,
    /// Human-readable agent display name.
    #[arg(long)]
    pub name: Option<String>,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
    /// Persona identifier to attach to the agent registration.
    #[arg(long)]
    pub persona: Option<String>,
}

impl Execute for SessionJoinArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, local_project.as_ref())?;
        let capabilities = self
            .capabilities
            .as_deref()
            .map(|value| {
                value
                    .split(',')
                    .map(str::trim)
                    .filter(|item| !item.is_empty())
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let state = service::join_session_with_fallback(
            &self.session_id,
            self.role,
            self.fallback_role,
            agent_to_str(self.runtime),
            &capabilities,
            self.name.as_deref(),
            &project,
            self.persona.as_deref(),
        )?;
        print_json(&state)?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct SessionEndArgs {
    /// Session ID.
    pub session_id: String,
    /// Agent ID of the caller.
    #[arg(long)]
    pub actor: String,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for SessionEndArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, local_project.as_ref())?;
        service::end_session(&self.session_id, &self.actor, &project)?;
        println!("session '{}' ended", self.session_id);
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct SessionAssignArgs {
    /// Session ID.
    pub session_id: String,
    /// Agent ID to assign.
    pub agent_id: String,
    /// New role.
    #[arg(long, value_enum)]
    pub role: SessionRole,
    /// Reason for the role change.
    #[arg(long)]
    pub reason: Option<String>,
    /// Agent ID of the caller.
    #[arg(long)]
    pub actor: String,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for SessionAssignArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, local_project.as_ref())?;
        service::assign_role(
            &self.session_id,
            &self.agent_id,
            self.role,
            self.reason.as_deref(),
            &self.actor,
            &project,
        )?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct SessionRemoveArgs {
    /// Session ID.
    pub session_id: String,
    /// Agent ID to remove.
    pub agent_id: String,
    /// Agent ID of the caller.
    #[arg(long)]
    pub actor: String,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for SessionRemoveArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, local_project.as_ref())?;
        service::remove_agent(&self.session_id, &self.agent_id, &self.actor, &project)?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct SessionTransferLeaderArgs {
    /// Session ID.
    pub session_id: String,
    /// Agent ID of the new leader.
    pub new_leader_id: String,
    /// Reason for transfer.
    #[arg(long)]
    pub reason: Option<String>,
    /// Agent ID of the caller.
    #[arg(long)]
    pub actor: String,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for SessionTransferLeaderArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, local_project.as_ref())?;
        service::transfer_leader(
            &self.session_id,
            &self.new_leader_id,
            self.reason.as_deref(),
            &self.actor,
            &project,
        )?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct SessionObserveArgs {
    /// Session ID.
    pub session_id: String,
    /// Poll interval in seconds for watch mode (0 = one-shot scan).
    #[arg(long, default_value = "0")]
    pub poll_interval: u64,
    /// Output as JSON.
    #[arg(long)]
    pub json: bool,
    /// Actor ID used for task creation; omit to keep observe read-only.
    #[arg(long)]
    pub actor: Option<String>,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for SessionObserveArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, local_project.as_ref())?;
        let actor = self.actor.as_deref().filter(|value| !value.trim().is_empty());
        if self.poll_interval > 0 {
            observe::execute_session_watch(
                &self.session_id,
                &project,
                self.poll_interval,
                self.json,
                actor,
            )
        } else if let (Some(actor), Some(client)) = (actor, DaemonClient::try_connect()) {
            // Daemon-backed observe tasks must go through the dedicated observe
            // mutation so issue metadata survives canonical persistence.
            let _ = client.observe_session(
                &self.session_id,
                &ObserveSessionRequest {
                    actor: Some(actor.to_string()),
                },
            )?;
            observe::execute_session_observe(&self.session_id, &project, self.json, None)
        } else {
            observe::execute_session_observe(&self.session_id, &project, self.json, actor)
        }
    }
}

#[derive(Debug, Clone, Args)]
pub struct SessionSyncArgs {
    /// Session ID.
    pub session_id: String,
    /// Output as JSON.
    #[arg(long)]
    pub json: bool,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for SessionSyncArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, local_project.as_ref())?;
        let result = service::sync_agent_liveness(&self.session_id, &project)?;
        if self.json {
            print_json(&serde_json::json!({
                "disconnected": result.disconnected,
                "idled": result.idled,
            }))?;
        } else if result.disconnected.is_empty() && result.idled.is_empty() {
            println!("All agents are alive");
        } else {
            for agent_id in &result.disconnected {
                println!("{agent_id}: disconnected");
            }
            for agent_id in &result.idled {
                println!("{agent_id}: idle");
            }
        }
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct SessionLeaveArgs {
    /// Session ID.
    pub session_id: String,
    /// Agent ID of the agent leaving.
    pub agent_id: String,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for SessionLeaveArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, local_project.as_ref())?;
        service::leave_session(&self.session_id, &self.agent_id, &project)?;
        println!("{} left session {}", self.agent_id, self.session_id);
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct SessionTitleArgs {
    /// Session ID.
    pub session_id: String,
    /// New session title.
    #[arg(long)]
    pub title: String,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for SessionTitleArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let project = resolve_project_dir(self.project_dir.as_deref());
        let state = service::update_session_title(&self.session_id, &self.title, project.as_ref())?;
        print_json(&state)?;
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct SessionStatusArgs {
    /// Session ID.
    pub session_id: String,
    /// Output as JSON.
    #[arg(long)]
    pub json: bool,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for SessionStatusArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let local_project = resolve_project_dir(self.project_dir.as_deref());
        let project =
            service::resolve_session_project_dir(&self.session_id, local_project.as_ref())?;
        let state = service::session_status(&self.session_id, &project)?;
        if self.json {
            print_json(&state)?;
        } else {
            let title_display = if state.title.is_empty() {
                "(untitled)"
            } else {
                &state.title
            };
            println!(
                "{} \"{}\" [{:?}] - {} (agents: {}, active: {}, tasks: {} open / {} in flight / {} done)",
                state.session_id,
                title_display,
                state.status,
                state.context,
                state.metrics.agent_count,
                state.metrics.active_agent_count,
                state.metrics.open_task_count,
                state.metrics.in_progress_task_count + state.metrics.blocked_task_count,
                state.metrics.completed_task_count,
            );
            if !state.branch_ref.is_empty() {
                println!("  branch:   {}", state.branch_ref);
            }
            if !state.worktree_path.as_os_str().is_empty() {
                println!("  worktree: {}", state.worktree_path.display());
            }
            if !state.shared_path.as_os_str().is_empty() {
                println!("  shared:   {}", state.shared_path.display());
            }
        }
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct SessionListArgs {
    /// Include archived sessions.
    #[arg(long)]
    pub all: bool,
    /// Output as JSON.
    #[arg(long)]
    pub json: bool,
    /// Project directory.
    #[arg(long, env = "CLAUDE_PROJECT_DIR")]
    pub project_dir: Option<String>,
}

impl Execute for SessionListArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let sessions = if self.project_dir.is_some() {
            let project = resolve_project_dir(self.project_dir.as_deref());
            service::list_sessions(project.as_ref(), self.all)?
        } else {
            service::list_sessions_global(self.all)?
        };
        if self.json {
            print_json(&sessions)?;
        } else {
            for session in &sessions {
                let title_display = if session.title.is_empty() {
                    "(untitled)"
                } else {
                    &session.title
                };
                let branch_suffix = if session.branch_ref.is_empty() {
                    String::new()
                } else {
                    format!(" [{}]", session.branch_ref)
                };
                println!(
                    "{}{} \"{}\" [{:?}] - {} (agents: {}, active: {}, tasks: {} open / {} in flight / {} done)",
                    session.session_id,
                    branch_suffix,
                    title_display,
                    session.status,
                    session.context,
                    session.metrics.agent_count,
                    session.metrics.active_agent_count,
                    session.metrics.open_task_count,
                    session.metrics.in_progress_task_count + session.metrics.blocked_task_count,
                    session.metrics.completed_task_count,
                );
            }
        }
        Ok(0)
    }
}

#[derive(Debug, Clone, Args)]
pub struct SessionAdoptArgs {
    /// Filesystem path to the on-disk session directory to adopt.
    pub path: PathBuf,
    /// Optional security-scoped bookmark id (used when the daemon runs sandboxed).
    #[arg(long = "bookmark-id")]
    pub bookmark_id: Option<String>,
}

impl Execute for SessionAdoptArgs {
    fn execute(&self, _context: &AppContext) -> Result<i32, CliError> {
        let request = AdoptSessionRequest {
            bookmark_id: self.bookmark_id.clone(),
            session_root: self.path.to_string_lossy().into_owned(),
        };
        let state = daemon_client()?.adopt_session(&request)?;
        println!("Attached session {}", state.session_id);
        print_json(&state)?;
        Ok(0)
    }
}

#[cfg(test)]
#[path = "session_commands/tests.rs"]
mod tests;
