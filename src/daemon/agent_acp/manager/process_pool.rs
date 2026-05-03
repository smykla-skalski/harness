use std::env;
use std::sync::Arc;

use super::{AcpAgentManagerHandle, ActiveAcpProcess, ActiveAcpSession};
use crate::errors::CliError;

const ACP_DISABLE_POOLING_ENV: &str = "HARNESS_ACP_DISABLE_POOLING";

impl AcpAgentManagerHandle {
    pub(in crate::daemon::agent_acp) fn reusable_session_for_process_key(
        &self,
        process_key: &str,
    ) -> Result<Option<Arc<ActiveAcpSession>>, CliError> {
        if process_pooling_disabled() {
            return Ok(None);
        }
        Ok(self
            .sessions_guard()?
            .values()
            .find(|session| {
                let snapshot = session.snapshot_with_live_counts();
                snapshot.process_key == process_key && !snapshot.status.is_disconnected()
            })
            .cloned())
    }

    pub(in crate::daemon::agent_acp) fn insert_process(
        &self,
        process_key: String,
        process: Arc<ActiveAcpProcess>,
    ) -> Result<(), CliError> {
        self.processes_guard()?.insert(process_key, process);
        Ok(())
    }

    pub(super) fn remove_process_if_empty(&self, process_key: &str) -> Result<(), CliError> {
        let mut processes = self.processes_guard()?;
        if processes
            .get(process_key)
            .is_some_and(|process| process.logical_session_count() == 0)
        {
            processes.remove(process_key);
        }
        Ok(())
    }
}

pub(in crate::daemon::agent_acp) fn process_pooling_disabled() -> bool {
    env::var(ACP_DISABLE_POOLING_ENV).is_ok_and(|value| {
        matches!(
            value.trim().to_ascii_lowercase().as_str(),
            "1" | "true" | "on" | "yes"
        )
    })
}
