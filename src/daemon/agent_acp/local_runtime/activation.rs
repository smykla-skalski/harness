//! Turning a started process into a live, registered ACP session: build the
//! session handle, wire its disconnect and watchdog forwarders, and roll the
//! registration back if the process fails to install in the pool.

use std::sync::Arc;

use tokio::sync::mpsc;

use crate::agents::acp::supervision::AcpSessionSupervisor;
use crate::agents::kind::DisconnectReason;
use crate::errors::CliError;

use super::super::active::{
    ActiveAcpProcess, ActiveAcpSession, spawn_protocol_disconnect_forwarder,
    spawn_watchdog_forwarder,
};
use super::super::manager::{AcpAgentManagerHandle, AcpAgentSnapshot};
use super::super::permission_bridge::PermissionBridgeHandle;
use super::super::protocol::AcpSessionRequestConfig;
use super::DescriptorStartInput;

impl AcpAgentManagerHandle {
    pub(super) fn activate_started_session(
        &self,
        input: DescriptorStartInput<'_>,
        snapshot: AcpAgentSnapshot,
        permissions: PermissionBridgeHandle,
        process: Arc<ActiveAcpProcess>,
        disconnects: mpsc::Receiver<DisconnectReason>,
        supervisor: Arc<AcpSessionSupervisor>,
    ) -> Result<(), CliError> {
        let active = self.build_started_session(
            snapshot,
            permissions,
            Arc::clone(&process),
            AcpSessionRequestConfig::from_request(input.request, input.descriptor),
            disconnects,
            supervisor,
        );
        self.sessions_guard()?
            .insert(input.acp_id.to_string(), Arc::clone(&active));
        if let Err(error) = self.insert_process(input.process_key.to_string(), process) {
            self.rollback_started_session_after_process_insert_error(input);
            drop(active);
            return Err(error);
        }
        Ok(())
    }

    fn build_started_session(
        &self,
        snapshot: AcpAgentSnapshot,
        permissions: PermissionBridgeHandle,
        process: Arc<ActiveAcpProcess>,
        session_config: AcpSessionRequestConfig,
        disconnects: mpsc::Receiver<DisconnectReason>,
        supervisor: Arc<AcpSessionSupervisor>,
    ) -> Arc<ActiveAcpSession> {
        let active = Arc::new(ActiveAcpSession::new(
            snapshot,
            permissions,
            process,
            session_config,
        ));
        active.set_protocol_disconnect_task(spawn_protocol_disconnect_forwarder(
            self.clone(),
            Arc::downgrade(&active),
            disconnects,
        ));
        active.set_watchdog_task(spawn_watchdog_forwarder(
            self.clone(),
            Arc::downgrade(&active),
            supervisor,
        ));
        active
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
    )]
    fn rollback_started_session_after_process_insert_error(&self, input: DescriptorStartInput<'_>) {
        if let Err(remove_error) = self
            .sessions_guard()
            .map(|mut sessions| sessions.remove(input.acp_id))
        {
            tracing::warn!(
                acp_id = input.acp_id,
                session_id = input.session_id,
                %remove_error,
                "failed to remove ACP session registration after process insert error"
            );
        }
    }
}
