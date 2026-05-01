use std::collections::BTreeSet;
use std::sync::atomic::Ordering;

use crate::daemon::agent_acp::manager::AcpAgentManagerHandle;

impl AcpAgentManagerHandle {
    pub(crate) fn sandbox_event_cursor(&self) -> Option<u64> {
        *self
            .state
            .sandbox_event_cursor
            .lock()
            .expect("ACP sandbox cursor lock")
    }

    pub(crate) fn set_sandbox_event_cursor(&self, cursor: Option<u64>) {
        *self
            .state
            .sandbox_event_cursor
            .lock()
            .expect("ACP sandbox cursor lock") = cursor;
    }

    pub(crate) fn sandbox_event_epoch(&self) -> Option<String> {
        self.state
            .sandbox_event_epoch
            .lock()
            .expect("ACP sandbox epoch lock")
            .clone()
    }

    pub(crate) fn set_sandbox_event_epoch(&self, epoch: Option<String>) {
        *self
            .state
            .sandbox_event_epoch
            .lock()
            .expect("ACP sandbox epoch lock") = epoch;
    }

    pub(crate) fn sandbox_event_continuity(&self) -> Option<u64> {
        *self
            .state
            .sandbox_event_continuity
            .lock()
            .expect("ACP sandbox continuity lock")
    }

    pub(crate) fn set_sandbox_event_continuity(&self, continuity: Option<u64>) {
        *self
            .state
            .sandbox_event_continuity
            .lock()
            .expect("ACP sandbox continuity lock") = continuity;
    }

    pub(crate) fn sandbox_known_sessions(&self) -> BTreeSet<String> {
        self.state
            .sandbox_known_sessions
            .lock()
            .expect("ACP sandbox known sessions lock")
            .clone()
    }

    pub(crate) fn set_sandbox_known_sessions(&self, sessions: BTreeSet<String>) {
        *self
            .state
            .sandbox_known_sessions
            .lock()
            .expect("ACP sandbox known sessions lock") = sessions;
    }

    pub(crate) fn swap_sandbox_event_poller_running(&self) -> bool {
        self.state
            .sandbox_event_poller_running
            .swap(true, Ordering::SeqCst)
    }

    pub(crate) fn clear_sandbox_event_poller_running(&self) {
        self.state
            .sandbox_event_poller_running
            .store(false, Ordering::SeqCst);
    }
}
