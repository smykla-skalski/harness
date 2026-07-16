use crate::daemon::agent_acp::{
    AcpAgentInspectResponse, AcpAgentReconcileResponse, AcpAgentSnapshot, AcpAgentStartRequest,
    AcpPermissionDecision,
};
use crate::errors::CliError;
use harness_protocol::managed_agents::acp::AcpRuntimeProbeResponse;

use super::acp_rpc::{
    BridgeAcpEventsRequest, BridgeAcpEventsResponse, BridgeAcpGetRequest, BridgeAcpInspectRequest,
    BridgeAcpListRequest, BridgeAcpProbeRequest, BridgeAcpProbeResponse, BridgeAcpReconcileRequest,
    BridgeAcpResolvePermissionRequest, BridgeAcpStartRequest,
};
use super::client::BridgeClient;
use super::types::BridgeCapability;

impl BridgeClient {
    /// Return the host bridge's latest cached ACP runtime probe snapshot.
    ///
    /// A missing snapshot means the bridge scheduled its first background
    /// probe and has not completed it yet.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge rejects the request or payload
    /// decoding fails.
    pub fn acp_probe(&self) -> Result<Option<AcpRuntimeProbeResponse>, CliError> {
        let response: BridgeAcpProbeResponse = self.typed_capability_request(
            BridgeCapability::Acp,
            "probe",
            &BridgeAcpProbeRequest::default(),
        )?;
        Ok(response.probe)
    }

    /// Start one bridge-managed ACP session.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge rejects the request or payload
    /// encoding or decoding fails.
    pub fn acp_start(
        &self,
        session_id: &str,
        request: &AcpAgentStartRequest,
        disable_pooling: bool,
        openrouter_token: Option<&str>,
    ) -> Result<AcpAgentSnapshot, CliError> {
        self.typed_capability_request(
            BridgeCapability::Acp,
            "start",
            &BridgeAcpStartRequest {
                session_id: session_id.to_string(),
                request: request.clone(),
                disable_pooling,
                openrouter_token: openrouter_token.map(ToOwned::to_owned),
            },
        )
    }

    /// List ACP sessions for one harness session id.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge rejects the request or payload
    /// decoding fails.
    pub fn acp_list(&self, session_id: &str) -> Result<Vec<AcpAgentSnapshot>, CliError> {
        self.typed_capability_request(
            BridgeCapability::Acp,
            "list",
            &BridgeAcpListRequest {
                session_id: session_id.to_string(),
            },
        )
    }

    /// Inspect ACP state, optionally filtered by harness session id.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge rejects the request or payload
    /// decoding fails.
    pub fn acp_inspect(
        &self,
        session_id: Option<&str>,
    ) -> Result<AcpAgentInspectResponse, CliError> {
        self.typed_capability_request(
            BridgeCapability::Acp,
            "inspect",
            &BridgeAcpInspectRequest {
                session_id: session_id.map(ToOwned::to_owned),
            },
        )
    }

    /// Load a batched ACP reconcile snapshot for sandbox resync.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge rejects the request or payload
    /// decoding fails.
    pub(crate) fn acp_reconcile(&self) -> Result<AcpAgentReconcileResponse, CliError> {
        self.typed_capability_request(
            BridgeCapability::Acp,
            "reconcile",
            &BridgeAcpReconcileRequest::default(),
        )
    }

    /// Load one ACP snapshot by ACP id.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge rejects the request or payload
    /// decoding fails.
    pub fn acp_get(&self, acp_id: &str) -> Result<AcpAgentSnapshot, CliError> {
        self.typed_capability_request(
            BridgeCapability::Acp,
            "get",
            &BridgeAcpGetRequest {
                acp_id: acp_id.to_string(),
            },
        )
    }

    /// Stop one ACP session by ACP id.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge rejects the request or payload
    /// decoding fails.
    pub fn acp_stop(&self, acp_id: &str) -> Result<AcpAgentSnapshot, CliError> {
        self.typed_capability_request(
            BridgeCapability::Acp,
            "stop",
            &BridgeAcpGetRequest {
                acp_id: acp_id.to_string(),
            },
        )
    }

    /// Resolve one ACP permission batch decision.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge rejects the request or payload
    /// encoding or decoding fails.
    pub fn acp_resolve_permission(
        &self,
        acp_id: &str,
        batch_id: &str,
        decision: &AcpPermissionDecision,
    ) -> Result<AcpAgentSnapshot, CliError> {
        self.typed_capability_request(
            BridgeCapability::Acp,
            "resolve_permission",
            &BridgeAcpResolvePermissionRequest {
                acp_id: acp_id.to_string(),
                batch_id: batch_id.to_string(),
                decision: decision.clone(),
            },
        )
    }

    /// Read ACP events after one optional sequence marker.
    ///
    /// # Errors
    /// Returns [`CliError`] when the bridge rejects the request or payload
    /// decoding fails.
    pub(crate) fn acp_events_since(
        &self,
        after_seq: Option<u64>,
        known_epoch: Option<&str>,
        known_continuity: Option<u64>,
    ) -> Result<BridgeAcpEventsResponse, CliError> {
        self.typed_capability_request(
            BridgeCapability::Acp,
            "events_since",
            &BridgeAcpEventsRequest {
                after_seq,
                known_epoch: known_epoch.map(ToOwned::to_owned),
                known_continuity,
            },
        )
    }
}
