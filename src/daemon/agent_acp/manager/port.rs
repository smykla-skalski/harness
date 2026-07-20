#[cfg(feature = "daemon-runtime")]
use std::path::Path;
use std::sync::Arc;

use async_trait::async_trait;
use serde::Serialize;
use tokio::sync::broadcast;

use crate::agents::acp::catalog::AcpAgentDescriptor;
use crate::agents::kind::DisconnectReason;
use crate::agents::runtime::event::ConversationEvent;
#[cfg(feature = "daemon-runtime")]
use crate::agents::runtime::signal::AckResult;
use crate::daemon::protocol::StreamEvent;
use crate::errors::CliError;
use crate::session::types::AgentStatus;
use crate::workspace::utc_now;

use super::{AcpAgentManagerHandle, AcpAgentSnapshot, AcpAgentStartRequest};

#[derive(Debug, Clone)]
pub(in crate::daemon::agent_acp) struct AcpOrchestrationRegistration {
    pub agent_id: String,
    pub display_name: String,
}

pub(in crate::daemon::agent_acp) struct AcpRegistrationRequest<'a> {
    pub(super) session_id: &'a str,
    pub(super) acp_id: &'a str,
    pub(super) request: &'a AcpAgentStartRequest,
    pub(super) descriptor: &'a AcpAgentDescriptor,
    pub(super) display_name: &'a str,
    pub(super) agent_session_id: Option<&'a str>,
}

pub(in crate::daemon::agent_acp) struct AcpRuntimeBinding<'a> {
    pub(super) session_id: &'a str,
    pub(super) acp_id: &'a str,
    pub(super) runtime_name: &'a str,
    pub(super) agent_session_id: &'a str,
}

#[cfg(feature = "daemon-runtime")]
pub(in crate::daemon::agent_acp) struct AcpWakeAcceptRequest<'a> {
    pub(super) session_id: &'a str,
    pub(super) agent_id: &'a str,
    pub(super) signal_id: &'a str,
    pub(super) result: AckResult,
    pub(super) project_dir: &'a Path,
}

#[async_trait]
pub(in crate::daemon::agent_acp) trait AcpManagerPort:
    Send + Sync
{
    fn event_sender(&self) -> broadcast::Sender<StreamEvent>;

    #[cfg(feature = "daemon-runtime")]
    fn ensure_session_accepts_start(&self, session_id: &str) -> Result<(), CliError>;

    fn register_agent(
        &self,
        request: AcpRegistrationRequest<'_>,
    ) -> Result<AcpOrchestrationRegistration, CliError>;

    fn bind_runtime_session(&self, binding: AcpRuntimeBinding<'_>) -> Result<bool, CliError>;

    async fn bind_runtime_session_async(
        &self,
        binding: AcpRuntimeBinding<'_>,
    ) -> Result<bool, CliError> {
        self.bind_runtime_session(binding)
    }

    /// Persist the title a runtime reports for its own session.
    fn record_runtime_session_title(
        &self,
        session_id: &str,
        acp_id: &str,
        title: &str,
    ) -> Result<bool, CliError>;

    fn rollback_registration(
        &self,
        session_id: &str,
        acp_id: &str,
        agent_id: &str,
        reason_label: &str,
    ) -> Result<bool, CliError>;

    fn sync_disconnect(
        &self,
        snapshot: &AcpAgentSnapshot,
        reason: &DisconnectReason,
        stderr_tail: Option<&String>,
    ) -> Result<bool, CliError>;

    fn sync_runtime_status(
        &self,
        snapshot: &AcpAgentSnapshot,
        status: AgentStatus,
    ) -> Result<bool, CliError>;

    fn project_dir_for_session(&self, session_id: &str) -> Result<Option<String>, CliError>;

    /// The agent session id a previous run on this harness session left behind
    /// for this runtime, so a restart can resume it rather than start over.
    fn last_runtime_session_id(
        &self,
        session_id: &str,
        runtime_name: &str,
    ) -> Result<Option<String>, CliError>;

    fn persist_conversation_events(
        &self,
        session_id: &str,
        agent_id: &str,
        runtime: &str,
        events: &[ConversationEvent],
    ) -> Result<(), CliError>;

    #[cfg(feature = "daemon-runtime")]
    fn sync_wake_accept(&self, request: AcpWakeAcceptRequest<'_>) -> Result<(), CliError>;

    #[cfg(all(test, feature = "daemon-runtime"))]
    fn daemon_db_slot(
        &self,
    ) -> Option<Arc<std::sync::OnceLock<Arc<std::sync::Mutex<crate::daemon::db::DaemonDb>>>>> {
        None
    }
}

pub(super) struct BridgeAcpManagerPort {
    sender: broadcast::Sender<StreamEvent>,
}

impl BridgeAcpManagerPort {
    pub(super) const fn new(sender: broadcast::Sender<StreamEvent>) -> Self {
        Self { sender }
    }
}

#[derive(Serialize)]
struct BridgeRuntimeSessionBound<'a> {
    session_id: &'a str,
    acp_id: &'a str,
    runtime_name: &'a str,
    runtime_session_id: &'a str,
}

#[async_trait]
impl AcpManagerPort for BridgeAcpManagerPort {
    fn event_sender(&self) -> broadcast::Sender<StreamEvent> {
        self.sender.clone()
    }

    #[cfg(feature = "daemon-runtime")]
    fn ensure_session_accepts_start(&self, _session_id: &str) -> Result<(), CliError> {
        Ok(())
    }

    fn register_agent(
        &self,
        request: AcpRegistrationRequest<'_>,
    ) -> Result<AcpOrchestrationRegistration, CliError> {
        let _ = (
            request.session_id,
            request.request,
            request.descriptor,
            request.agent_session_id,
        );
        Ok(AcpOrchestrationRegistration {
            agent_id: request.acp_id.to_string(),
            display_name: request.display_name.to_string(),
        })
    }

    fn bind_runtime_session(&self, binding: AcpRuntimeBinding<'_>) -> Result<bool, CliError> {
        let payload = BridgeRuntimeSessionBound {
            session_id: binding.session_id,
            acp_id: binding.acp_id,
            runtime_name: binding.runtime_name,
            runtime_session_id: binding.agent_session_id,
        };
        let _ = self.sender.send(StreamEvent {
            event: "acp_runtime_session_bound".to_string(),
            recorded_at: utc_now(),
            session_id: Some(binding.session_id.to_string()),
            payload: serde_json::to_value(payload).unwrap_or_default(),
        });
        Ok(true)
    }

    fn record_runtime_session_title(
        &self,
        _session_id: &str,
        _acp_id: &str,
        _title: &str,
    ) -> Result<bool, CliError> {
        Ok(false)
    }

    fn rollback_registration(
        &self,
        _session_id: &str,
        _acp_id: &str,
        _agent_id: &str,
        _reason_label: &str,
    ) -> Result<bool, CliError> {
        Ok(false)
    }

    fn sync_disconnect(
        &self,
        _snapshot: &AcpAgentSnapshot,
        _reason: &DisconnectReason,
        _stderr_tail: Option<&String>,
    ) -> Result<bool, CliError> {
        Ok(false)
    }

    fn sync_runtime_status(
        &self,
        _snapshot: &AcpAgentSnapshot,
        _status: AgentStatus,
    ) -> Result<bool, CliError> {
        Ok(false)
    }

    fn project_dir_for_session(&self, _session_id: &str) -> Result<Option<String>, CliError> {
        Ok(None)
    }

    /// The sandboxed bridge has no session store to read, so a start through it
    /// never resumes on its own. An explicit resume id still works.
    fn last_runtime_session_id(
        &self,
        _session_id: &str,
        _runtime_name: &str,
    ) -> Result<Option<String>, CliError> {
        Ok(None)
    }

    fn persist_conversation_events(
        &self,
        _session_id: &str,
        _agent_id: &str,
        _runtime: &str,
        _events: &[ConversationEvent],
    ) -> Result<(), CliError> {
        Ok(())
    }

    #[cfg(feature = "daemon-runtime")]
    fn sync_wake_accept(&self, request: AcpWakeAcceptRequest<'_>) -> Result<(), CliError> {
        let _ = (
            request.session_id,
            request.agent_id,
            request.signal_id,
            request.result,
            request.project_dir,
        );
        Ok(())
    }
}

impl AcpAgentManagerHandle {
    pub(in crate::daemon::agent_acp) fn register_orchestration_agent(
        &self,
        session_id: &str,
        acp_id: &str,
        request: &AcpAgentStartRequest,
        descriptor: &AcpAgentDescriptor,
        display_name: &str,
        agent_session_id: Option<&str>,
    ) -> Result<AcpOrchestrationRegistration, CliError> {
        self.state.port.register_agent(AcpRegistrationRequest {
            session_id,
            acp_id,
            request,
            descriptor,
            display_name,
            agent_session_id,
        })
    }

    pub(in crate::daemon::agent_acp) async fn bind_orchestration_runtime_session_async(
        &self,
        session_id: &str,
        acp_id: &str,
        runtime_name: &str,
        agent_session_id: &str,
    ) -> Result<bool, CliError> {
        self.state
            .port
            .bind_runtime_session_async(AcpRuntimeBinding {
                session_id,
                acp_id,
                runtime_name,
                agent_session_id,
            })
            .await
    }

    #[cfg(feature = "daemon-runtime")]
    pub(in crate::daemon::agent_acp) fn bind_orchestration_runtime_session(
        &self,
        session_id: &str,
        acp_id: &str,
        runtime_name: &str,
        agent_session_id: &str,
    ) -> Result<bool, CliError> {
        self.state.port.bind_runtime_session(AcpRuntimeBinding {
            session_id,
            acp_id,
            runtime_name,
            agent_session_id,
        })
    }

    /// Persist an agent-reported session title without blocking the caller's
    /// path: the title is advisory metadata, so a failed write is logged and
    /// the next update simply tries again.
    pub(in crate::daemon::agent_acp) fn record_runtime_session_title_best_effort(
        &self,
        session_id: &str,
        acp_id: &str,
        title: &str,
    ) {
        if let Err(error) = self
            .state
            .port
            .record_runtime_session_title(session_id, acp_id, title)
        {
            tracing::warn!(session_id, acp_id, %error,
                "failed to record ACP runtime session title");
        }
    }

    pub(in crate::daemon::agent_acp) fn rollback_orchestration_registration_best_effort(
        &self,
        session_id: &str,
        acp_id: &str,
        agent_id: &str,
        reason_label: &str,
    ) {
        if let Err(error) =
            self.state
                .port
                .rollback_registration(session_id, acp_id, agent_id, reason_label)
        {
            tracing::warn!(session_id, acp_id, agent_id, reason = reason_label, %error,
                "failed to roll back ACP orchestration registration");
        }
    }

    pub(in crate::daemon::agent_acp) fn sync_orchestration_disconnect_best_effort(
        &self,
        snapshot: &AcpAgentSnapshot,
    ) {
        let AgentStatus::Disconnected {
            reason,
            stderr_tail,
        } = &snapshot.status
        else {
            return;
        };
        if let Err(error) = self
            .state
            .port
            .sync_disconnect(snapshot, reason, stderr_tail.as_ref())
        {
            tracing::warn!(acp_id = %snapshot.acp_id, session_id = %snapshot.session_id,
                agent_id = %snapshot.agent_id, %error,
                "failed to sync ACP disconnect into session orchestration");
        }
    }

    pub(in crate::daemon::agent_acp) fn sync_orchestration_runtime_status_best_effort(
        &self,
        snapshot: &AcpAgentSnapshot,
    ) {
        let status = match &snapshot.status {
            AgentStatus::Active => AgentStatus::Active,
            AgentStatus::Idle => AgentStatus::Idle,
            AgentStatus::AwaitingReview
            | AgentStatus::Disconnected { .. }
            | AgentStatus::Removed => return,
        };
        if let Err(error) = self.state.port.sync_runtime_status(snapshot, status) {
            tracing::warn!(session_id = snapshot.session_id, acp_id = snapshot.acp_id,
                agent_id = snapshot.agent_id, %error,
                "failed to sync ACP runtime status into orchestration state");
        }
    }

    pub(in crate::daemon::agent_acp) fn live_event_port(&self) -> Arc<dyn AcpManagerPort> {
        Arc::clone(&self.state.port)
    }

    #[cfg(all(test, feature = "daemon-runtime"))]
    pub(in crate::daemon::agent_acp) fn daemon_db_slot(
        &self,
    ) -> Option<Arc<std::sync::OnceLock<Arc<std::sync::Mutex<crate::daemon::db::DaemonDb>>>>> {
        self.state.port.daemon_db_slot()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agents::acp::catalog;

    #[test]
    fn bridge_manager_registers_a_local_agent_identity() {
        let (sender, _) = broadcast::channel(4);
        let manager = AcpAgentManagerHandle::new_bridge(sender);
        let request = AcpAgentStartRequest {
            agent: "copilot".to_string(),
            ..AcpAgentStartRequest::default()
        };
        let descriptor = catalog::find_builtin("copilot").expect("copilot descriptor");

        let registration = manager
            .register_orchestration_agent(
                "session-1",
                "acp-1",
                &request,
                descriptor,
                "Copilot",
                None,
            )
            .expect("bridge registration");

        assert_eq!(registration.agent_id, "acp-1");
        assert_eq!(registration.display_name, "Copilot");
    }

    #[tokio::test]
    async fn bridge_manager_publishes_runtime_session_binding() {
        let (sender, mut receiver) = broadcast::channel(4);
        let manager = AcpAgentManagerHandle::new_bridge(sender);

        let bound = manager
            .bind_orchestration_runtime_session_async(
                "session-1",
                "acp-1",
                "copilot",
                "runtime-session-1",
            )
            .await
            .expect("bridge runtime binding");

        assert!(bound);
        let event = receiver.try_recv().expect("runtime binding event");
        assert_eq!(event.event, "acp_runtime_session_bound");
        assert_eq!(event.session_id.as_deref(), Some("session-1"));
        assert_eq!(event.payload["acp_id"], "acp-1");
        assert_eq!(event.payload["runtime_name"], "copilot");
        assert_eq!(event.payload["runtime_session_id"], "runtime-session-1");
    }
}
