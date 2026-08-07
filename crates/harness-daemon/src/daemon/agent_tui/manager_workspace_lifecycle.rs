//! Start a terminal worker that belongs to a durable workspace.
//!
//! The Session-bound path injects an auto-join skill call so the agent registers
//! itself in a Session roster once the PTY is live. A workspace-owned worker has
//! no roster to join: the daemon records its membership directly when the start
//! succeeds, so the only prompt the process gets is the work it was started for.

use std::path::{Path, PathBuf};

use crate::daemon::bridge::{AgentTuiStartSpec, BridgeCapability, BridgeClient};
use crate::infra::io::validate_safe_segment;
use crate::workspace::project_context_dir;
use harness_kernel::errors::CliError;

use super::manager::{ActiveAgentTui, AgentTuiManagerHandle};
use super::model::{AgentTuiStartRequest, AgentTuiStartRequestExt};
use super::support::{record_started_prompt, transcript_path};
use harness_daemon_managed_agents::{
    AgentTuiSnapshot, AgentTuiSnapshotContext, ManagedTerminalOwner, spawn_agent_tui_process,
};

/// Where a workspace-owned terminal runs and who owns it.
pub(crate) struct WorkspaceTerminalOwner<'a> {
    pub(crate) workspace_id: &'a str,
    /// The working copy's checkout. Supplied directly because there is no
    /// Session row to read a worktree path off.
    pub(crate) project_dir: &'a str,
}

impl AgentTuiManagerHandle {
    /// Start a terminal worker in a workspace checkout, with a durable
    /// caller-reserved identity.
    ///
    /// Reusing an identity while its worker is attached returns the existing
    /// terminal, which is what makes a reclaimed Task Board dispatch claim
    /// idempotent.
    pub(crate) fn start_in_workspace_with_id(
        &self,
        owner: &WorkspaceTerminalOwner<'_>,
        request: &AgentTuiStartRequest,
        tui_id: String,
    ) -> Result<AgentTuiSnapshot, CliError> {
        validate_safe_segment(&tui_id)?;
        self.ensure_automation_kill_switch_clear()?;
        if self.is_tui_active(&tui_id)? {
            return ensure_terminal_workspace(self.load_snapshot(&tui_id)?, owner.workspace_id);
        }

        let profile = request.launch_profile()?;
        let size = request.size()?;
        let project_dir = PathBuf::from(owner.project_dir);
        let context_root = project_context_dir(&project_dir);
        let transcript_path = transcript_path(&context_root, &profile.runtime, &tui_id);
        if let Some(prompt) = request.prompt.as_deref().filter(|value| !value.is_empty()) {
            record_started_prompt(&transcript_path, prompt)?;
        }
        if self.state.sandboxed {
            return self.start_workspace_terminal_via_bridge(
                owner,
                request,
                tui_id,
                &project_dir,
                &transcript_path,
            );
        }
        let snapshot_context = AgentTuiSnapshotContext {
            session_id: owner.workspace_id,
            workspace_id: Some(owner.workspace_id),
            agent_id: "",
            tui_id: &tui_id,
            profile: &profile,
            project_dir: &project_dir,
            transcript_path: &transcript_path,
        };
        let process = spawn_agent_tui_process(
            ManagedTerminalOwner::Workspace(owner.workspace_id),
            &tui_id,
            profile.clone(),
            &project_dir,
            size,
            None,
            request.effort.as_deref(),
        )?;
        let snapshot = self.activate_tui(process, &snapshot_context)?;
        self.spawn_workspace_prompt_delivery(snapshot.clone(), profile.runtime.clone(), request);
        Ok(snapshot)
    }

    fn start_workspace_terminal_via_bridge(
        &self,
        owner: &WorkspaceTerminalOwner<'_>,
        request: &AgentTuiStartRequest,
        tui_id: String,
        project_dir: &Path,
        transcript_path: &Path,
    ) -> Result<AgentTuiSnapshot, CliError> {
        let bridge = BridgeClient::for_capability(BridgeCapability::AgentTui)?;
        // The bridge only spawns the PTY and reports what it made; ownership is
        // the daemon's to record, so the workspace is stamped on the way in to
        // persistence rather than sent across the bridge protocol.
        let mut snapshot = bridge.agent_tui_start(&AgentTuiStartSpec {
            session_id: owner.workspace_id.to_string(),
            workspace_id: Some(owner.workspace_id.to_string()),
            agent_id: String::new(),
            tui_id,
            profile: request.launch_profile()?,
            project_dir: project_dir.to_path_buf(),
            transcript_path: transcript_path.to_path_buf(),
            size: request.size()?,
            prompt: None,
            user_prompt: request
                .prompt
                .as_deref()
                .filter(|value| !value.is_empty())
                .map(ToString::to_string),
            effort: request.effort.clone(),
        })?;
        snapshot.workspace_id = Some(owner.workspace_id.to_string());
        self.register_started_snapshot(&snapshot, ActiveAgentTui::new(None))?;
        Ok(snapshot)
    }
}

/// A reclaimed identity has to belong to the workspace reclaiming it. Returning
/// a terminal owned by a different workspace would hand one dispatch another
/// dispatch's running worker.
fn ensure_terminal_workspace(
    snapshot: AgentTuiSnapshot,
    workspace_id: &str,
) -> Result<AgentTuiSnapshot, CliError> {
    if snapshot.workspace_id.as_deref() == Some(workspace_id) {
        return Ok(snapshot);
    }
    Err(harness_kernel::errors::CliErrorKind::session_agent_conflict(format!(
        "terminal agent '{}' belongs to '{}', not workspace '{workspace_id}'",
        snapshot.tui_id, snapshot.session_id
    ))
    .into())
}
