//! Audit and external-sync summary wire types, relocated here from
//! `harness-task-board::summary`. `TaskBoardProjectSummary`,
//! `TaskBoardMachineSummary`, and the `build_*_summary` functions that
//! produce every summary type stay in `harness-task-board`: they walk the
//! full `TaskBoardItem` domain entity, which this move has no need for.
//! `harness-task-board` re-exports every name below at the same path.

use serde::{Deserialize, Serialize};

use super::external::{ExternalProvider, ExternalSyncOperation};
use super::types::TaskBoardStatus;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardAuditSummary {
    pub total: usize,
    pub ready: usize,
    pub blocked: usize,
    pub deleted: usize,
    pub by_status: Vec<TaskBoardStatusCount>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardStatusCount {
    pub status: TaskBoardStatus,
    pub count: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardSyncSummary {
    pub total: usize,
    pub providers: Vec<TaskBoardProviderSyncSummary>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub operations: Vec<ExternalSyncOperation>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardProviderSyncSummary {
    pub provider: ExternalProvider,
    pub configured: bool,
    pub linked: usize,
    pub pushable: usize,
    pub blocked: usize,
    pub token_env: Vec<String>,
}

// Existing coverage for these types stays in `harness-task-board::summary`'s
// own test module, exercised through the re-export below.
