//! Dispatch lifecycle wire types, relocated here from
//! `harness-task-board::dispatch`'s `#[path = "dispatch_lifecycle.rs"]`
//! submodule. `applied()` is a pure field mutation and moved with the type;
//! `planned()` and its private `worker`/`reviewer`/`evaluator` step builders
//! stayed behind as the free function
//! [`dispatch_lifecycle_planned`](harness-task-board) because they read
//! `harness_session::service::SPAWN_REVIEWER_COMMAND`, and `harness-protocol`
//! cannot depend on `harness-session`, which itself depends on
//! `harness-protocol`. `harness-task-board` re-exports every type name below
//! at the same path; its three external callers now call the free function
//! instead of `DispatchLifecycle::planned`.

use serde::{Deserialize, Serialize};

use super::types::AgentMode;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct DispatchLifecycle {
    pub worker: DispatchLifecycleStep,
    pub reviewer: DispatchLifecycleStep,
    pub evaluator: DispatchLifecycleStep,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct DispatchLifecycleStep {
    pub phase: DispatchLifecyclePhase,
    pub status: DispatchLifecycleStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<AgentMode>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suggested_persona: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub required_consensus: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub native_signal: Option<DispatchNativeSignal>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum DispatchLifecyclePhase {
    Worker,
    Reviewer,
    Evaluator,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[derive(utoipa::ToSchema)]
pub enum DispatchLifecycleStatus {
    Planned,
    SessionTaskLinked,
    WaitingForWorkerReview,
    WaitingForReviewCompletion,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct DispatchNativeSignal {
    pub command: String,
    pub trigger_step: String,
}

impl DispatchLifecycle {
    #[must_use]
    pub fn applied(&self) -> Self {
        let mut lifecycle = self.clone();
        lifecycle.worker.status = DispatchLifecycleStatus::SessionTaskLinked;
        lifecycle.reviewer.status = DispatchLifecycleStatus::WaitingForWorkerReview;
        lifecycle.evaluator.status = DispatchLifecycleStatus::WaitingForReviewCompletion;
        lifecycle
    }
}
