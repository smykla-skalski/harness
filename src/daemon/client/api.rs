use crate::daemon::agent_tui::{
    AgentTuiInputRequest, AgentTuiListResponse, AgentTuiResizeRequest, AgentTuiSnapshot,
    AgentTuiStartRequest,
};
use crate::daemon::protocol::{
    AgentRemoveRequest, LeaderTransferRequest, RoleChangeRequest, SessionDetail, SessionEndRequest,
    SessionJoinRequest, SessionLeaveRequest, SessionMutationResponse, SessionStartRequest,
    SessionSummary, SessionTitleRequest, SignalAckRequest, SignalCancelRequest, SignalSendRequest,
    TaskAssignRequest, TaskCheckpointRequest, TaskCreateRequest, TaskDropRequest,
    TaskUpdateRequest,
};
use crate::errors::CliError;
use crate::session::types::{AgentPersona, SessionState};

use super::DaemonClient;

#[expect(
    clippy::missing_errors_doc,
    reason = "all methods forward to daemon HTTP and return CliError on failure"
)]
impl DaemonClient {
    /// Fetch the list of available agent personas from the daemon.
    ///
    /// # Errors
    /// Returns [`CliError`] on network or deserialization failures.
    pub fn personas(&self) -> Result<Vec<AgentPersona>, CliError> {
        self.get("/v1/personas")
    }

    pub fn start_session(&self, request: &SessionStartRequest) -> Result<SessionState, CliError> {
        let response: SessionMutationResponse = self.post("/v1/sessions", request)?;
        Ok(response.state)
    }

    pub fn join_session(
        &self,
        session_id: &str,
        request: &SessionJoinRequest,
    ) -> Result<SessionState, CliError> {
        let response: SessionMutationResponse =
            self.post(&format!("/v1/sessions/{session_id}/join"), request)?;
        Ok(response.state)
    }

    pub fn end_session(
        &self,
        session_id: &str,
        request: &SessionEndRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(&format!("/v1/sessions/{session_id}/end"), request)
    }

    pub fn leave_session(
        &self,
        session_id: &str,
        request: &SessionLeaveRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(&format!("/v1/sessions/{session_id}/leave"), request)
    }

    pub fn update_session_title(
        &self,
        session_id: &str,
        request: &SessionTitleRequest,
    ) -> Result<SessionState, CliError> {
        let response: SessionMutationResponse =
            self.post(&format!("/v1/sessions/{session_id}/title"), request)?;
        Ok(response.state)
    }

    pub fn assign_role(
        &self,
        session_id: &str,
        agent_id: &str,
        request: &RoleChangeRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(
            &format!("/v1/sessions/{session_id}/agents/{agent_id}/role"),
            request,
        )
    }

    pub fn remove_agent(
        &self,
        session_id: &str,
        agent_id: &str,
        request: &AgentRemoveRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(
            &format!("/v1/sessions/{session_id}/agents/{agent_id}/remove"),
            request,
        )
    }

    pub fn transfer_leader(
        &self,
        session_id: &str,
        request: &LeaderTransferRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(&format!("/v1/sessions/{session_id}/leader"), request)
    }

    pub fn create_task(
        &self,
        session_id: &str,
        request: &TaskCreateRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(&format!("/v1/sessions/{session_id}/task"), request)
    }

    pub fn assign_task(
        &self,
        session_id: &str,
        task_id: &str,
        request: &TaskAssignRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(
            &format!("/v1/sessions/{session_id}/tasks/{task_id}/assign"),
            request,
        )
    }

    pub fn drop_task(
        &self,
        session_id: &str,
        task_id: &str,
        request: &TaskDropRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(
            &format!("/v1/sessions/{session_id}/tasks/{task_id}/drop"),
            request,
        )
    }

    pub fn update_task(
        &self,
        session_id: &str,
        task_id: &str,
        request: &TaskUpdateRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(
            &format!("/v1/sessions/{session_id}/tasks/{task_id}/status"),
            request,
        )
    }

    pub fn checkpoint_task(
        &self,
        session_id: &str,
        task_id: &str,
        request: &TaskCheckpointRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(
            &format!("/v1/sessions/{session_id}/tasks/{task_id}/checkpoint"),
            request,
        )
    }

    pub fn send_signal(
        &self,
        session_id: &str,
        request: &SignalSendRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(&format!("/v1/sessions/{session_id}/signal"), request)
    }

    pub fn record_signal_ack(
        &self,
        session_id: &str,
        request: &SignalAckRequest,
    ) -> Result<(), CliError> {
        let _: serde_json::Value =
            self.post(&format!("/v1/sessions/{session_id}/signal-ack"), request)?;
        Ok(())
    }

    pub fn cancel_signal(
        &self,
        session_id: &str,
        request: &SignalCancelRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(&format!("/v1/sessions/{session_id}/signal-cancel"), request)
    }

    pub fn start_agent_tui(
        &self,
        session_id: &str,
        request: &AgentTuiStartRequest,
    ) -> Result<AgentTuiSnapshot, CliError> {
        self.post(&format!("/v1/sessions/{session_id}/agent-tuis"), request)
    }

    pub fn send_agent_tui_input(
        &self,
        tui_id: &str,
        request: &AgentTuiInputRequest,
    ) -> Result<AgentTuiSnapshot, CliError> {
        self.post(&format!("/v1/agent-tuis/{tui_id}/input"), request)
    }

    pub fn resize_agent_tui(
        &self,
        tui_id: &str,
        request: &AgentTuiResizeRequest,
    ) -> Result<AgentTuiSnapshot, CliError> {
        self.post(&format!("/v1/agent-tuis/{tui_id}/resize"), request)
    }

    pub fn stop_agent_tui(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        let body = serde_json::json!({});
        self.post(&format!("/v1/agent-tuis/{tui_id}/stop"), &body)
    }

    pub fn signal_tui_ready(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        let body = serde_json::json!({});
        self.post(&format!("/v1/agent-tuis/{tui_id}/ready"), &body)
    }

    pub fn get_session_detail(&self, session_id: &str) -> Result<SessionDetail, CliError> {
        self.get(&format!("/v1/sessions/{session_id}"))
    }

    pub fn list_sessions(&self) -> Result<Vec<SessionSummary>, CliError> {
        self.get("/v1/sessions")
    }

    pub fn list_agent_tuis(&self, session_id: &str) -> Result<AgentTuiListResponse, CliError> {
        self.get(&format!("/v1/sessions/{session_id}/agent-tuis"))
    }

    pub fn get_agent_tui(&self, tui_id: &str) -> Result<AgentTuiSnapshot, CliError> {
        self.get(&format!("/v1/agent-tuis/{tui_id}"))
    }
}
