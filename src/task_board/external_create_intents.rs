use serde::{Deserialize, Serialize};

use super::{
    ExternalCreateOutcome, ExternalProvider, ExternalRef, ExternalSyncField, TaskBoardItem,
    TaskBoardStatus,
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct TaskBoardExternalCreateSnapshot {
    pub(crate) title: String,
    pub(crate) body: String,
    pub(crate) status: TaskBoardStatus,
    pub(crate) project_id: Option<String>,
    pub(crate) execution_repository: Option<String>,
    pub(crate) provider_target: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardExternalCreateIntent {
    pub(crate) intent_id: String,
    pub(crate) item_id: String,
    pub(crate) item_revision: i64,
    pub(crate) provider: ExternalProvider,
    pub(crate) scope_id: String,
    pub(crate) create_key: String,
    pub(crate) snapshot: TaskBoardExternalCreateSnapshot,
    pub(crate) changed_fields: Vec<ExternalSyncField>,
    pub(crate) state: TaskBoardExternalCreateIntentState,
    pub(crate) created_at: String,
    pub(crate) updated_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardExternalCreateEvidence {
    pub(crate) outcome: ExternalCreateOutcome,
    pub(crate) provider_baseline: ExternalRef,
    pub(crate) recorded_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardExternalCreateReceipt {
    pub(crate) evidence: TaskBoardExternalCreateEvidence,
    pub(crate) attached_at: String,
    pub(crate) attached_item_revision: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum TaskBoardExternalCreateIntentState {
    InFlight,
    Created(Box<TaskBoardExternalCreateEvidence>),
    Attached(Box<TaskBoardExternalCreateReceipt>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum TaskBoardExternalCreateExisting {
    Recover(TaskBoardExternalCreateIntent),
    Finalize(TaskBoardExternalCreateIntent),
    Attached(TaskBoardExternalCreateIntent),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum TaskBoardExternalCreateBegin {
    Started(TaskBoardExternalCreateIntent),
    Existing(TaskBoardExternalCreateExisting),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TaskBoardExternalCreateFinalizeDisposition {
    Attached,
    AlreadyLinked,
    AlreadyAttached,
    RetainedMissingItem,
}

#[derive(Debug, Clone)]
#[allow(
    dead_code,
    reason = "the storage contract is consumed by the follow-up provider-create worker"
)]
pub(crate) struct TaskBoardExternalCreateFinalizeResult {
    pub(crate) intent: TaskBoardExternalCreateIntent,
    pub(crate) item: Option<TaskBoardItem>,
    pub(crate) item_revision: Option<i64>,
    pub(crate) disposition: TaskBoardExternalCreateFinalizeDisposition,
}

impl TaskBoardExternalCreateIntent {
    pub(crate) fn created_evidence(&self) -> Option<&TaskBoardExternalCreateEvidence> {
        match &self.state {
            TaskBoardExternalCreateIntentState::InFlight => None,
            TaskBoardExternalCreateIntentState::Created(evidence) => Some(evidence),
            TaskBoardExternalCreateIntentState::Attached(receipt) => Some(&receipt.evidence),
        }
    }
}
