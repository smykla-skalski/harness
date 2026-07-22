use serde::{Deserialize, Serialize};

use super::wire::{RemoteArtifactEntry, RemoteAssignmentWireState, RemoteAttemptBinding};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RemoteCancelRequest {
    pub(crate) schema_version: u32,
    pub(crate) binding: RemoteAttemptBinding,
    pub(crate) lease_id: String,
    pub(crate) offer_request_sha256: String,
    pub(crate) reason: String,
    pub(crate) request_sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RemoteCancelResponse {
    pub(crate) schema_version: u32,
    pub(crate) binding: RemoteAttemptBinding,
    pub(crate) offer_request_sha256: String,
    pub(crate) cancel_response_sha256: String,
    pub(crate) state: RemoteAssignmentWireState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) claimed_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) started_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) workspace_ref: Option<String>,
    pub(crate) observed_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RemoteSettledRequest {
    pub(crate) schema_version: u32,
    pub(crate) binding: RemoteAttemptBinding,
    pub(crate) lease_id: String,
    pub(crate) offer_request_sha256: String,
    pub(crate) terminal_state: RemoteAssignmentWireState,
    pub(crate) result_sha256: Option<String>,
    pub(crate) request_sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RemoteSettledResponse {
    pub(crate) schema_version: u32,
    pub(crate) binding: RemoteAttemptBinding,
    pub(crate) offer_request_sha256: String,
    pub(crate) settlement_request_sha256: String,
    pub(crate) settled_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RemoteArtifactFetchRequest {
    pub(crate) schema_version: u32,
    pub(crate) binding: RemoteAttemptBinding,
    pub(crate) lease_id: String,
    pub(crate) offer_request_sha256: String,
    pub(crate) relative_path: String,
    pub(crate) expected_sha256: String,
    pub(crate) request_sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RemoteArtifactFetchResponse {
    pub(crate) schema_version: u32,
    pub(crate) binding: RemoteAttemptBinding,
    pub(crate) offer_request_sha256: String,
    pub(crate) artifact: RemoteArtifactEntry,
    pub(crate) content_base64: String,
}
