//! Three small policy-pipeline wire types, relocated here from
//! `harness-task-board::policy_graph::store` (`PolicyPipelinePromoteRequest`,
//! `PolicyPipelineMakeLiveRequest`) and `harness-task-board::wire::task_board`
//! (`PolicyPipelinePromoteResponse`). All three are pure primitive data with
//! no inherent methods. `PolicyPipelinePromoteOutcome` and the full
//! policy-graph engine stay in `harness-task-board`. The
//! `impl From<PolicyPipelinePromoteOutcome> for PolicyPipelinePromoteResponse`
//! that used to sit next to the definition had no callers anywhere in the
//! workspace (the daemon service layer already builds
//! `PolicyPipelinePromoteResponse` from field literals instead) and was
//! dropped rather than carried forward as a free function. `harness-task-board`
//! re-exports all three names below at the same path.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, Serialize, Deserialize, utoipa::ToSchema)]
pub struct PolicyPipelinePromoteRequest {
    pub revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub canvas_id: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, utoipa::ToSchema)]
pub struct PolicyPipelineMakeLiveRequest {
    pub revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub canvas_id: Option<String>,
}

/// Thin wire projection of `PolicyPipelinePromoteOutcome`: drops the embedded
/// `PolicyGraph` because the promote endpoint's real consumers never read it
/// back off the response (Monitor's promote UI action calls the separate
/// `make-live` endpoint instead, whose own response genuinely needs the full
/// graph and is untouched here). A caller that still wants the graph after
/// promoting reads it from the canvas/summary endpoints, the same place it
/// already comes from today.
#[derive(Debug, Clone, Serialize, Deserialize, utoipa::ToSchema)]
pub struct PolicyPipelinePromoteResponse {
    pub revision: u64,
    pub trace_id: String,
}
