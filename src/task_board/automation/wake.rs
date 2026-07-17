use serde::{Deserialize, Serialize};

pub(crate) const TASK_BOARD_AUTOMATION_WAKE_PAYLOAD_SCHEMA_VERSION: u32 = 1;
pub(crate) const TASK_BOARD_AUTOMATION_WAKE_BATCH_LIMIT: u32 = 500;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum TaskBoardAutomationWakeCause {
    LedgerChanged,
    Recovery,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum TaskBoardAutomationWakeEntityKind {
    Item,
    Control,
    Settings,
    Policy,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum TaskBoardAutomationWakeRecoveryReason {
    Startup,
    LeaseExpired,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct TaskBoardAutomationLedgerChangedWakeV1 {
    pub(crate) schema_version: u32,
    pub(crate) entity_kind: TaskBoardAutomationWakeEntityKind,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct TaskBoardAutomationRecoveryWakeV1 {
    pub(crate) schema_version: u32,
    pub(crate) reason: TaskBoardAutomationWakeRecoveryReason,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "cause", content = "payload", rename_all = "snake_case")]
pub(crate) enum TaskBoardAutomationWakePayload {
    LedgerChanged(TaskBoardAutomationLedgerChangedWakeV1),
    Recovery(TaskBoardAutomationRecoveryWakeV1),
}

impl TaskBoardAutomationWakePayload {
    pub(crate) const fn cause(&self) -> TaskBoardAutomationWakeCause {
        match self {
            Self::LedgerChanged(_) => TaskBoardAutomationWakeCause::LedgerChanged,
            Self::Recovery(_) => TaskBoardAutomationWakeCause::Recovery,
        }
    }

    pub(crate) const fn ledger_changed(entity_kind: TaskBoardAutomationWakeEntityKind) -> Self {
        Self::LedgerChanged(TaskBoardAutomationLedgerChangedWakeV1 {
            schema_version: TASK_BOARD_AUTOMATION_WAKE_PAYLOAD_SCHEMA_VERSION,
            entity_kind,
        })
    }

    pub(crate) const fn recovery(reason: TaskBoardAutomationWakeRecoveryReason) -> Self {
        Self::Recovery(TaskBoardAutomationRecoveryWakeV1 {
            schema_version: TASK_BOARD_AUTOMATION_WAKE_PAYLOAD_SCHEMA_VERSION,
            reason,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardAutomationWakeRequest {
    pub(crate) entity_id: Option<String>,
    pub(crate) entity_revision: Option<u64>,
    pub(crate) payload: TaskBoardAutomationWakePayload,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardAutomationWakeEvent {
    pub(crate) sequence: u64,
    pub(crate) entity_id: Option<String>,
    pub(crate) entity_revision: Option<u64>,
    pub(crate) payload: TaskBoardAutomationWakePayload,
    pub(crate) created_at: String,
}
