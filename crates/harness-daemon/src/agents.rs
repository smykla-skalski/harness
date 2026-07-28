use std::path::Path;

pub use harness_agents::acp;
pub mod kind {
    pub use harness_protocol::agent::{AcpAgentId, DisconnectReason, RuntimeKind};
}
pub use harness_agents::policy;
pub use harness_agents::runtime;

pub mod service {
    use super::Path;
    use harness_kernel::errors::{CliError, CliErrorKind};
    use harness_protocol::agent::HookAgent;

    /// Resolve the canonical session identifier for a known agent.
    ///
    /// # Errors
    ///
    /// Returns an error when canonical session state cannot be read.
    pub fn resolve_known_session_id(
        agent: HookAgent,
        project_dir: &Path,
        session_id_hint: Option<&str>,
    ) -> Result<Option<String>, CliError> {
        harness_hook::agents::service::resolve_known_session_id(agent, project_dir, session_id_hint)
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("resolve canonical agent session: {error}"))
                    .into()
            })
    }
}
