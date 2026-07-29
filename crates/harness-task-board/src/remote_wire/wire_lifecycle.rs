use serde::{Deserialize, Serialize};

use super::wire::{RemoteArtifactEntry, RemoteAssignmentWireState, RemoteAttemptBinding};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[derive(utoipa::ToSchema)]
pub struct RemoteCancelRequest {
    pub schema_version: u32,
    pub binding: RemoteAttemptBinding,
    pub lease_id: String,
    pub offer_request_sha256: String,
    pub reason: String,
    pub request_sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[derive(utoipa::ToSchema)]
pub struct RemoteCancelResponse {
    pub schema_version: u32,
    pub binding: RemoteAttemptBinding,
    pub offer_request_sha256: String,
    pub cancel_response_sha256: String,
    pub state: RemoteAssignmentWireState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claimed_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace_ref: Option<String>,
    pub observed_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[derive(utoipa::ToSchema)]
pub struct RemoteSettledRequest {
    pub schema_version: u32,
    pub binding: RemoteAttemptBinding,
    pub lease_id: String,
    pub offer_request_sha256: String,
    pub terminal_state: RemoteAssignmentWireState,
    pub result_sha256: Option<String>,
    pub request_sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[derive(utoipa::ToSchema)]
pub struct RemoteSettledResponse {
    pub schema_version: u32,
    pub binding: RemoteAttemptBinding,
    pub offer_request_sha256: String,
    pub settlement_request_sha256: String,
    pub settled_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[derive(utoipa::ToSchema)]
pub struct RemoteArtifactFetchRequest {
    pub schema_version: u32,
    pub binding: RemoteAttemptBinding,
    pub lease_id: String,
    pub offer_request_sha256: String,
    pub relative_path: String,
    pub expected_sha256: String,
    pub request_sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[derive(utoipa::ToSchema)]
pub struct RemoteArtifactFetchResponse {
    pub schema_version: u32,
    pub binding: RemoteAttemptBinding,
    pub offer_request_sha256: String,
    pub artifact: RemoteArtifactEntry,
    pub content_base64: String,
}
