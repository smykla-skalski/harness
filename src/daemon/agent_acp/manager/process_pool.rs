use std::env;
use std::sync::Arc;

use super::{AcpAgentManagerHandle, ActiveAcpProcess, ActiveAcpSession};

const ACP_DISABLE_POOLING_ENV: &str = "HARNESS_ACP_DISABLE_POOLING";

impl AcpAgentManagerHandle {
    pub(in crate::daemon::agent_acp) fn reusable_session_for_process_key(
        &self,
        process_key: &str,
    ) -> Option<Arc<ActiveAcpSession>> {
        if process_pooling_disabled() {
            return None;
        }
        self.state
            .sessions
            .lock()
            .expect("ACP sessions lock")
            .values()
            .find(|session| {
                let snapshot = session.snapshot_with_live_counts();
                snapshot.process_key == process_key && !snapshot.status.is_disconnected()
            })
            .cloned()
    }

    pub(in crate::daemon::agent_acp) fn insert_process(
        &self,
        process_key: String,
        process: Arc<ActiveAcpProcess>,
    ) {
        self.state
            .processes
            .lock()
            .expect("ACP processes lock")
            .insert(process_key, process);
    }

    pub(super) fn remove_process_if_empty(&self, process_key: &str) {
        let mut processes = self.state.processes.lock().expect("ACP processes lock");
        if processes
            .get(process_key)
            .is_some_and(|process| process.logical_session_count() == 0)
        {
            processes.remove(process_key);
        }
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
