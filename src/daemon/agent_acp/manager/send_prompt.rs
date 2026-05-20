use std::path::PathBuf;
use std::thread;

use super::{AcpAgentManagerHandle, AcpAgentSnapshot};
use crate::daemon::service;
use crate::errors::{CliError, CliErrorKind};

impl AcpAgentManagerHandle {
    /// Send a user-initiated follow-up prompt to an existing ACP session.
    ///
    /// The prompt is dispatched on a dedicated OS thread so the caller is not
    /// blocked while the agent streams its response; streaming updates arrive
    /// via the broadcast channel as the agent emits them. The returned
    /// snapshot reflects the session state at acceptance time.
    ///
    /// # Errors
    /// Returns [`CliError`] when the ACP session is unknown, already
    /// disconnected, or the prompt thread cannot be spawned.
    pub fn send_prompt(
        &self,
        acp_id: &str,
        prompt: &str,
    ) -> Result<AcpAgentSnapshot, CliError> {
        let trimmed = prompt.trim();
        if trimmed.is_empty() {
            return Err(CliErrorKind::session_not_active(format!(
                "prompt_empty: ACP managed agent '{acp_id}' cannot accept an empty prompt"
            ))
            .into());
        }
        if service::sandboxed_from_env() {
            return Err(CliErrorKind::workflow_io(format!(
                "acp_prompt_unsupported_in_sandbox: ACP managed agent '{acp_id}' follow-up prompts \
                 require an unsandboxed daemon"
            ))
            .into());
        }
        let session = self.session(acp_id)?;
        let snapshot = session.snapshot_with_live_counts();
        if snapshot.status.is_disconnected() {
            return Err(CliErrorKind::session_not_active(format!(
                "acp_session_disconnected: ACP managed agent '{acp_id}' is not connected"
            ))
            .into());
        }
        let acp_id_owned = acp_id.to_string();
        let session_id_owned = snapshot.session_id.clone();
        let project_dir = PathBuf::from(&snapshot.project_dir);
        let prompt_owned = trimmed.to_string();
        let thread_name = format!("acp-prompt-{acp_id}");
        thread::Builder::new()
            .name(thread_name)
            .spawn(move || {
                let result = session.prompt_protocol_session(
                    &acp_id_owned,
                    &session_id_owned,
                    project_dir,
                    prompt_owned,
                );
                if let Err(error) = result {
                    tracing::warn!(
                        target: "harness::acp_manager",
                        managed_agent_id = %acp_id_owned,
                        runtime_session_id = %session_id_owned,
                        %error,
                        "user-initiated ACP follow-up prompt failed"
                    );
                }
            })
            .map_err(|error| {
                CliErrorKind::workflow_io(format!(
                    "failed to spawn ACP prompt thread for '{acp_id}': {error}"
                ))
            })?;
        self.broadcast("acp_agent_prompted", &snapshot);
        Ok(snapshot)
    }
}
