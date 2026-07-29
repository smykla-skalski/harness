//! Choosing which prior agent session a start should pick up.

use super::super::manager::{AcpAgentManagerHandle, AcpAgentStartRequest};

impl AcpAgentManagerHandle {
    /// The prior agent session this start should pick up, if any.
    ///
    /// Only the id is decided here; whether it is resumed or loaded is chosen
    /// later from what the agent advertises. An explicit id wins,
    /// `resume_disabled` forces a fresh session, and otherwise the last session
    /// this runtime recorded on this harness session is picked up. Looking it up
    /// is best effort: failing to read the store is a reason to start clean,
    /// never to fail the start.
    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    pub(super) fn resume_target(
        &self,
        request: &AcpAgentStartRequest,
        session_id: &str,
        runtime_name: &str,
    ) -> Option<String> {
        if request.resume_disabled {
            return None;
        }
        if let Some(explicit) = request
            .resume_session_id
            .as_deref()
            .map(str::trim)
            .filter(|id| !id.is_empty())
        {
            return Some(explicit.to_string());
        }
        match self
            .state
            .port
            .last_runtime_session_id(session_id, runtime_name)
        {
            Ok(found) => found,
            Err(error) => {
                tracing::warn!(%error, session_id, runtime_name, "could not read a prior ACP session to resume");
                None
            }
        }
    }
}
