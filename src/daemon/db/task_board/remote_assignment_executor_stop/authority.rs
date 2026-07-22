use serde::{Deserialize, Serialize};

use super::super::remote_assignment_lifecycle_owner::TaskBoardRemoteExecutorLifecycleOwner;
use super::super::remote_assignment_model::TaskBoardRemoteAssignmentRecord;
use super::super::remote_assignment_start_authority::{
    TaskBoardRemoteExecutorStartAuthority, TaskBoardRemoteExecutorStartIoPermit,
};
use crate::daemon::db::CliError;
use crate::task_board::TaskBoardRemoteAssignmentState;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum TaskBoardRemoteExecutorStopReason {
    StartEvidenceInvalid,
    StartAdoptionFenceLost,
    StartAdoptionFailed,
    LifecycleEvidenceInvalid,
}

impl TaskBoardRemoteExecutorStopReason {
    pub(crate) const fn message(self) -> &'static str {
        match self {
            Self::StartEvidenceInvalid => "remote Codex start evidence failed validation",
            Self::StartAdoptionFenceLost => "remote Codex start adoption lost its fence",
            Self::StartAdoptionFailed => "remote Codex start adoption failed",
            Self::LifecycleEvidenceInvalid => "remote Codex lifecycle evidence failed validation",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum TaskBoardRemoteExecutorStopAuthority {
    Start(TaskBoardRemoteExecutorStartIoPermit),
    /// A durable run whose Start-I/O permit never persisted (the permit
    /// transaction rolled back after the run side-effect fired) is still fenced
    /// by the start authority acquired before it. This authorizes stopping that
    /// invalid pre-permit run so it cannot leak the deterministic session slot.
    PrePermit(TaskBoardRemoteExecutorStartAuthority),
    Lifecycle(TaskBoardRemoteExecutorLifecycleOwner),
}

impl TaskBoardRemoteExecutorStopAuthority {
    pub(super) fn kind(&self) -> StopAuthorityKind {
        match self {
            Self::Start(_) => StopAuthorityKind::Start,
            Self::PrePermit(_) => StopAuthorityKind::PrePermit,
            Self::Lifecycle(_) => StopAuthorityKind::Lifecycle,
        }
    }

    pub(super) fn sha256(&self) -> &str {
        match self {
            Self::Start(authority) => &authority.sha256,
            Self::PrePermit(authority) => &authority.sha256,
            Self::Lifecycle(owner) => &owner.sha256,
        }
    }

    pub(super) fn acquired_at(&self) -> &str {
        match self {
            Self::Start(authority) => &authority.permitted_at,
            Self::PrePermit(authority) => &authority.acquired_at,
            Self::Lifecycle(owner) => &owner.acquired_at,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum StopAuthorityKind {
    Start,
    PrePermit,
    Lifecycle,
}

pub(super) fn authority_assignment_id(authority: &TaskBoardRemoteExecutorStopAuthority) -> &str {
    match authority {
        TaskBoardRemoteExecutorStopAuthority::Start(authority) => &authority.assignment_id,
        TaskBoardRemoteExecutorStopAuthority::PrePermit(authority) => &authority.assignment_id,
        TaskBoardRemoteExecutorStopAuthority::Lifecycle(owner) => &owner.assignment_id,
    }
}

pub(super) fn source_matches(
    record: &TaskBoardRemoteAssignmentRecord,
    authority: &TaskBoardRemoteExecutorStopAuthority,
    reason: TaskBoardRemoteExecutorStopReason,
) -> Result<bool, CliError> {
    if record.fencing_epoch != authority_fencing_epoch(authority) {
        return Ok(false);
    }
    Ok(match authority {
        TaskBoardRemoteExecutorStopAuthority::Start(authority) => {
            matches!(
                reason,
                TaskBoardRemoteExecutorStopReason::StartEvidenceInvalid
                    | TaskBoardRemoteExecutorStopReason::StartAdoptionFenceLost
                    | TaskBoardRemoteExecutorStopReason::StartAdoptionFailed
            ) && record.state == TaskBoardRemoteAssignmentState::Claimed
                && record.executor_start_authority_sha256.as_deref()
                    == Some(authority.authority.sha256.as_str())
                && record.executor_start_authority_at.as_deref()
                    == Some(authority.authority.acquired_at.as_str())
                && record.executor_start_io_permit_sha256.as_deref()
                    == Some(authority.sha256.as_str())
                && record.executor_start_io_permit_at.as_deref()
                    == Some(authority.permitted_at.as_str())
                && record.start_receipt.is_none()
                && record.executor_lifecycle_owner.is_none()
        }
        TaskBoardRemoteExecutorStopAuthority::PrePermit(authority) => {
            matches!(
                reason,
                TaskBoardRemoteExecutorStopReason::StartEvidenceInvalid
                    | TaskBoardRemoteExecutorStopReason::StartAdoptionFenceLost
                    | TaskBoardRemoteExecutorStopReason::StartAdoptionFailed
            ) && record.state == TaskBoardRemoteAssignmentState::Claimed
                && record.executor_start_authority_sha256.as_deref()
                    == Some(authority.sha256.as_str())
                && record.executor_start_authority_at.as_deref()
                    == Some(authority.acquired_at.as_str())
                && record.executor_start_io_permit_sha256.is_none()
                && record.executor_start_io_permit_at.is_none()
                && record.start_receipt.is_none()
                && record.executor_lifecycle_owner.is_none()
        }
        TaskBoardRemoteExecutorStopAuthority::Lifecycle(owner) => {
            reason == TaskBoardRemoteExecutorStopReason::LifecycleEvidenceInvalid
                && matches!(
                    record.state,
                    TaskBoardRemoteAssignmentState::Started
                        | TaskBoardRemoteAssignmentState::Running
                )
                && record.executor_lifecycle_owner.as_ref() == Some(owner)
                && record.start_receipt.is_some()
                && record.executor_start_authority_sha256.is_none()
        }
    })
}

pub(super) fn authority_fencing_epoch(authority: &TaskBoardRemoteExecutorStopAuthority) -> u64 {
    match authority {
        TaskBoardRemoteExecutorStopAuthority::Start(authority) => authority.fencing_epoch,
        TaskBoardRemoteExecutorStopAuthority::PrePermit(authority) => authority.fencing_epoch,
        TaskBoardRemoteExecutorStopAuthority::Lifecycle(owner) => owner.fencing_epoch,
    }
}
