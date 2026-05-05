use super::AcpSessionSupervisor;

/// RAII guard that pauses the watchdog while a client call is in flight.
pub struct ClientCallGuard<'a> {
    pub(super) supervisor: &'a AcpSessionSupervisor,
}

impl Drop for ClientCallGuard<'_> {
    fn drop(&mut self) {
        self.supervisor.exit_client_call();
    }
}

/// RAII guard that activates the watchdog while a daemon-issued request is
/// awaiting an agent response. Drop releases the slot.
pub struct PendingRequestGuard<'a> {
    pub(super) supervisor: &'a AcpSessionSupervisor,
}

impl Drop for PendingRequestGuard<'_> {
    fn drop(&mut self) {
        self.supervisor.exit_pending_request();
    }
}
