use serde::{Deserialize, Serialize};

pub const TASK_BOARD_AUTOMATION_WAKE_PAYLOAD_SCHEMA_VERSION: u32 = 1;
pub const TASK_BOARD_AUTOMATION_WAKE_BATCH_LIMIT: u32 = 500;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardAutomationWakeCause {
    LedgerChanged,
    Recovery,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardAutomationWakeEntityKind {
    Item,
    Control,
    Settings,
    Policy,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardAutomationWakeRecoveryReason {
    Startup,
    LeaseExpired,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardAutomationLedgerChangedWakeV1 {
    pub schema_version: u32,
    pub entity_kind: TaskBoardAutomationWakeEntityKind,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardAutomationRecoveryWakeV1 {
    pub schema_version: u32,
    pub reason: TaskBoardAutomationWakeRecoveryReason,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "cause", content = "payload", rename_all = "snake_case")]
pub enum TaskBoardAutomationWakePayload {
    LedgerChanged(TaskBoardAutomationLedgerChangedWakeV1),
    Recovery(TaskBoardAutomationRecoveryWakeV1),
}

impl TaskBoardAutomationWakePayload {
    #[must_use]
    pub const fn cause(&self) -> TaskBoardAutomationWakeCause {
        match self {
            Self::LedgerChanged(_) => TaskBoardAutomationWakeCause::LedgerChanged,
            Self::Recovery(_) => TaskBoardAutomationWakeCause::Recovery,
        }
    }

    #[must_use]
    pub const fn ledger_changed(entity_kind: TaskBoardAutomationWakeEntityKind) -> Self {
        Self::LedgerChanged(TaskBoardAutomationLedgerChangedWakeV1 {
            schema_version: TASK_BOARD_AUTOMATION_WAKE_PAYLOAD_SCHEMA_VERSION,
            entity_kind,
        })
    }

    #[must_use]
    pub const fn recovery(reason: TaskBoardAutomationWakeRecoveryReason) -> Self {
        Self::Recovery(TaskBoardAutomationRecoveryWakeV1 {
            schema_version: TASK_BOARD_AUTOMATION_WAKE_PAYLOAD_SCHEMA_VERSION,
            reason,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskBoardAutomationWakeRequest {
    pub entity_id: Option<String>,
    pub entity_revision: Option<u64>,
    pub payload: TaskBoardAutomationWakePayload,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskBoardAutomationWakeEvent {
    pub sequence: u64,
    pub entity_id: Option<String>,
    pub entity_revision: Option<u64>,
    pub payload: TaskBoardAutomationWakePayload,
    pub created_at: String,
}
