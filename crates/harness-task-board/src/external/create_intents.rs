use serde::{Deserialize, Serialize};

use super::{
    ExternalCreateOutcome, ExternalProvider, ExternalRef, ExternalSyncField, TaskBoardItem,
    TaskBoardStatus,
};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardExternalCreateSnapshot {
    pub title: String,
    pub body: String,
    pub status: TaskBoardStatus,
    pub project_id: Option<String>,
    pub execution_repository: Option<String>,
    pub provider_target: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskBoardExternalCreateIntent {
    pub intent_id: String,
    pub item_id: String,
    pub item_revision: i64,
    pub provider: ExternalProvider,
    pub scope_id: String,
    pub create_key: String,
    pub snapshot: TaskBoardExternalCreateSnapshot,
    pub changed_fields: Vec<ExternalSyncField>,
    pub state: TaskBoardExternalCreateIntentState,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskBoardExternalCreateEvidence {
    pub outcome: ExternalCreateOutcome,
    pub provider_baseline: ExternalRef,
    pub recorded_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskBoardExternalCreateReceipt {
    pub evidence: TaskBoardExternalCreateEvidence,
    pub attached_at: String,
    pub attached_item_revision: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TaskBoardExternalCreateIntentState {
    InFlight,
    Created(Box<TaskBoardExternalCreateEvidence>),
    Attached(Box<TaskBoardExternalCreateReceipt>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TaskBoardExternalCreateExisting {
    Recover(TaskBoardExternalCreateIntent),
    Finalize(TaskBoardExternalCreateIntent),
    Attached(TaskBoardExternalCreateIntent),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TaskBoardExternalCreateBegin {
    Started(TaskBoardExternalCreateIntent),
    Existing(TaskBoardExternalCreateExisting),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TaskBoardExternalCreateFinalizeDisposition {
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
pub struct TaskBoardExternalCreateFinalizeResult {
    pub intent: TaskBoardExternalCreateIntent,
    pub item: Option<TaskBoardItem>,
    pub item_revision: Option<i64>,
    pub disposition: TaskBoardExternalCreateFinalizeDisposition,
}

impl TaskBoardExternalCreateIntent {
    #[must_use]
    pub fn created_evidence(&self) -> Option<&TaskBoardExternalCreateEvidence> {
        match &self.state {
            TaskBoardExternalCreateIntentState::InFlight => None,
            TaskBoardExternalCreateIntentState::Created(evidence) => Some(evidence),
            TaskBoardExternalCreateIntentState::Attached(receipt) => Some(&receipt.evidence),
        }
    }
}
