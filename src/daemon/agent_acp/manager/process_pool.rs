use std::sync::Arc;

use super::{AcpAgentManagerHandle, ActiveAcpProcess, ActiveAcpSession};

impl AcpAgentManagerHandle {
    pub(in crate::daemon::agent_acp) fn reusable_session_for_process_key(
        &self,
        process_key: &str,
    ) -> Option<Arc<ActiveAcpSession>> {
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
