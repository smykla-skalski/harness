//! Request and response shapes for reporting and reading worker progress.

use serde::{Deserialize, Serialize};

use crate::work_item_progress::{
    TaskBoardWorkItemProgress, TaskBoardWorkItemReportRejection, TaskBoardWorkItemState,
};

/// What a worker reports against its dispatched work item.
///
/// The attempt identity and the work-item revision are deliberately absent: the
/// daemon stamps both from the item's own dispatch, so a review handoff carries
/// the attempt the board really started rather than one the worker named.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardWorkItemReportRequest {
    /// Who is reporting. Defaults to the control plane when omitted.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor: Option<String>,
    /// The state to move to. Omit to record a checkpoint without moving.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<TaskBoardWorkItemState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[schema(maximum = 100)]
    pub progress_percent: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blocked_reason: Option<String>,
    /// Ordering fence. Supply it to make a retried delivery detectable; omit it
    /// to take the next sequence.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sequence: Option<u64>,
}

/// The RPC form of a report, which has to name its item in the payload because
/// there is no path to carry it.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardWorkItemReportCommand {
    pub id: String,
    #[serde(flatten)]
    pub report: TaskBoardWorkItemReportRequest,
}

/// The record after one report, and whether the report moved it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardWorkItemReportResponse {
    pub applied: bool,
    /// Why an unapplied report was ignored. A rejection is a visible no-op
    /// rather than an error: a worker retrying a delivery has done nothing
    /// wrong, and the record it reads back is the authority either way.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rejection: Option<TaskBoardWorkItemReportRejection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rejection_message: Option<String>,
    pub progress: TaskBoardWorkItemProgress,
}

/// The durable worker progress for one board item, absent until dispatch.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct TaskBoardWorkItemProgressResponse {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub progress: Option<TaskBoardWorkItemProgress>,
}
