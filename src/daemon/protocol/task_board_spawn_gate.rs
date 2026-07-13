//! Wire types for the WP3 spawn-gate controls: the two persisted spawn switches
//! and the durable approval-grant list/resolve routes. Split out of
//! `task_board.rs` to keep each file under the source-length cap.

use serde::{Deserialize, Serialize};

use crate::task_board::PolicyApprovalGrant;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PolicyCanvasSetSpawnRequiresLivePolicyRequest {
    pub enabled: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PolicyCanvasSetSpawnKillSwitchRequest {
    pub enabled: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PolicyApprovalGrantsListResponse {
    #[serde(default)]
    pub grants: Vec<PolicyApprovalGrant>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PolicyApprovalGrantResolveRequest {
    pub grant_id: String,
    pub approve: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PolicyApprovalGrantResolveResponse {
    pub grant: PolicyApprovalGrant,
}
