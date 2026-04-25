use crate::daemon::agent_tui::{AgentTuiInputRequest, AgentTuiResizeRequest, AgentTuiStartRequest};
use crate::daemon::protocol::{
    AdoptSessionRequest, AgentRemoveRequest, AgentRuntimeSessionRegistrationRequest,
    AgentRuntimeSessionRegistrationResponse, CodexApprovalDecisionRequest, CodexRunRequest,
    CodexSteerRequest, ImproverApplyRequest, LeaderTransferRequest, ManagedAgentListResponse,
    ManagedAgentSnapshot, ObserveSessionRequest, RoleChangeRequest,
    RuntimeSessionResolutionResponse, SessionDetail, SessionEndRequest, SessionJoinRequest,
    SessionLeaveRequest, SessionMutationResponse, SessionStartRequest, SessionSummary,
    SessionTitleRequest, SignalAckRequest, SignalCancelRequest, SignalSendRequest,
    TaskArbitrateRequest, TaskAssignRequest, TaskCheckpointRequest, TaskClaimReviewRequest,
    TaskCreateRequest, TaskDropRequest, TaskRespondReviewRequest, TaskSubmitForReviewRequest,
    TaskSubmitReviewRequest, TaskUpdateRequest,
};
use crate::errors::CliError;
use crate::session::service::{ImproverApplyOutcome, ResolvedRuntimeSessionAgent};
use crate::session::types::SessionState;

use super::DaemonClient;

/// Outcome of asking the daemon to resolve a runtime-session ID.
///
/// The client treats "endpoint missing" as a distinct state so callers can
/// fall back to the legacy fan-out over `list_sessions + get_session_detail`
/// when a new CLI talks to an older daemon that pre-dates `/v1/runtime-sessions/resolve`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RuntimeSessionLookup {
    Resolved(ResolvedRuntimeSessionAgent),
    NotFound,
    EndpointUnavailable,
}

#[expect(
    clippy::missing_errors_doc,
    reason = "all methods forward to daemon HTTP and return CliError on failure"
)]
impl DaemonClient {
    /// Resolve a runtime-session ID against the dedicated resolver endpoint.
    ///
    /// Returns [`RuntimeSessionLookup::EndpointUnavailable`] when the remote
    /// daemon does not recognise `/v1/runtime-sessions/resolve` (HTTP 404),
    /// letting the caller fall back to the legacy `list_sessions` +
    /// `get_session_detail` fan-out. All other transport failures surface
    /// as [`CliError`].
    ///
    /// # Errors
    /// Returns [`CliError`] on network failures, non-404 HTTP errors, or
    /// when the daemon surfaces ambiguity as `session_ambiguous`.
    pub fn resolve_runtime_session(
        &self,
        runtime_name: &str,
        runtime_session_id: &str,
    ) -> Result<RuntimeSessionLookup, CliError> {
        let response: Option<RuntimeSessionResolutionResponse> = self.get_optional(
            "/v1/runtime-sessions/resolve",
            &[
                ("runtime_name", runtime_name),
                ("runtime_session_id", runtime_session_id),
            ],
        )?;
        Ok(match response {
            None => RuntimeSessionLookup::EndpointUnavailable,
            Some(payload) => match payload.resolved {
                Some(resolved) => RuntimeSessionLookup::Resolved(resolved),
                None => RuntimeSessionLookup::NotFound,
            },
        })
    }

    pub fn start_session(&self, request: &SessionStartRequest) -> Result<SessionState, CliError> {
        let response: SessionMutationResponse = self.post("/v1/sessions", request)?;
        Ok(response.state)
    }

    pub fn adopt_session(&self, request: &AdoptSessionRequest) -> Result<SessionState, CliError> {
        let response: SessionMutationResponse = self.post("/v1/sessions/adopt", request)?;
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

    pub fn register_agent_runtime_session(
        &self,
        session_id: &str,
        request: &AgentRuntimeSessionRegistrationRequest,
    ) -> Result<bool, CliError> {
        let response: AgentRuntimeSessionRegistrationResponse = self.post(
            &format!("/v1/sessions/{session_id}/runtime-session"),
            request,
        )?;
        Ok(response.registered)
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

    pub fn submit_task_for_review(
        &self,
        session_id: &str,
        task_id: &str,
        request: &TaskSubmitForReviewRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(
            &format!("/v1/sessions/{session_id}/tasks/{task_id}/submit-for-review"),
            request,
        )
    }

    pub fn claim_task_review(
        &self,
        session_id: &str,
        task_id: &str,
        request: &TaskClaimReviewRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(
            &format!("/v1/sessions/{session_id}/tasks/{task_id}/claim-review"),
            request,
        )
    }

    pub fn submit_task_review(
        &self,
        session_id: &str,
        task_id: &str,
        request: &TaskSubmitReviewRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(
            &format!("/v1/sessions/{session_id}/tasks/{task_id}/submit-review"),
            request,
        )
    }

    pub fn respond_task_review(
        &self,
        session_id: &str,
        task_id: &str,
        request: &TaskRespondReviewRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(
            &format!("/v1/sessions/{session_id}/tasks/{task_id}/respond-review"),
            request,
        )
    }

    pub fn arbitrate_task(
        &self,
        session_id: &str,
        task_id: &str,
        request: &TaskArbitrateRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(
            &format!("/v1/sessions/{session_id}/tasks/{task_id}/arbitrate"),
            request,
        )
    }

    pub fn improver_apply(
        &self,
        session_id: &str,
        request: &ImproverApplyRequest,
    ) -> Result<ImproverApplyOutcome, CliError> {
        self.post(
            &format!("/v1/sessions/{session_id}/improver/apply"),
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

    pub fn observe_session(
        &self,
        session_id: &str,
        request: &ObserveSessionRequest,
    ) -> Result<SessionDetail, CliError> {
        self.post(&format!("/v1/sessions/{session_id}/observe"), request)
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

    pub fn get_session_detail(&self, session_id: &str) -> Result<SessionDetail, CliError> {
        self.get(&format!("/v1/sessions/{session_id}"))
    }

    pub fn list_sessions(&self) -> Result<Vec<SessionSummary>, CliError> {
        self.get("/v1/sessions")
    }

    pub fn list_managed_agents(
        &self,
        session_id: &str,
    ) -> Result<ManagedAgentListResponse, CliError> {
        self.get(&format!("/v1/sessions/{session_id}/managed-agents"))
    }

    pub fn get_managed_agent(&self, agent_id: &str) -> Result<ManagedAgentSnapshot, CliError> {
        self.get(&format!("/v1/managed-agents/{agent_id}"))
    }

    pub fn start_terminal_managed_agent(
        &self,
        session_id: &str,
        request: &AgentTuiStartRequest,
    ) -> Result<ManagedAgentSnapshot, CliError> {
        self.post(
            &format!("/v1/sessions/{session_id}/managed-agents/terminal"),
            request,
        )
    }

    pub fn start_codex_managed_agent(
        &self,
        session_id: &str,
        request: &CodexRunRequest,
    ) -> Result<ManagedAgentSnapshot, CliError> {
        self.post(
            &format!("/v1/sessions/{session_id}/managed-agents/codex"),
            request,
        )
    }

    pub fn send_managed_terminal_input(
        &self,
        agent_id: &str,
        request: &AgentTuiInputRequest,
    ) -> Result<ManagedAgentSnapshot, CliError> {
        self.post(&format!("/v1/managed-agents/{agent_id}/input"), request)
    }

    pub fn resize_managed_terminal(
        &self,
        agent_id: &str,
        request: &AgentTuiResizeRequest,
    ) -> Result<ManagedAgentSnapshot, CliError> {
        self.post(&format!("/v1/managed-agents/{agent_id}/resize"), request)
    }

    pub fn stop_managed_terminal(&self, agent_id: &str) -> Result<ManagedAgentSnapshot, CliError> {
        let body = serde_json::json!({});
        self.post(&format!("/v1/managed-agents/{agent_id}/stop"), &body)
    }

    pub fn signal_managed_terminal_ready(&self, agent_id: &str) -> Result<(), CliError> {
        let body = serde_json::json!({});
        let _: ManagedAgentSnapshot =
            self.post(&format!("/v1/managed-agents/{agent_id}/ready"), &body)?;
        Ok(())
    }

    pub fn steer_codex_managed_agent(
        &self,
        agent_id: &str,
        request: &CodexSteerRequest,
    ) -> Result<ManagedAgentSnapshot, CliError> {
        self.post(&format!("/v1/managed-agents/{agent_id}/steer"), request)
    }

    pub fn interrupt_codex_managed_agent(
        &self,
        agent_id: &str,
    ) -> Result<ManagedAgentSnapshot, CliError> {
        let body = serde_json::json!({});
        self.post(&format!("/v1/managed-agents/{agent_id}/interrupt"), &body)
    }

    pub fn resolve_codex_managed_agent_approval(
        &self,
        agent_id: &str,
        approval_id: &str,
        request: &CodexApprovalDecisionRequest,
    ) -> Result<ManagedAgentSnapshot, CliError> {
        self.post(
            &format!("/v1/managed-agents/{agent_id}/approvals/{approval_id}"),
            request,
        )
    }
}
