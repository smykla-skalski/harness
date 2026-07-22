use sqlx::{Sqlite, Transaction, query};

use super::{
    TaskBoardRemoteOperationKind, TaskBoardRemoteOperationTrustFence,
    load_operation_fence_for_kind_in_tx, require_sha256,
};
use crate::daemon::db::task_board::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, concurrent, to_i64,
};
use crate::daemon::db::task_board::remote_lifecycle_trust::{
    TaskBoardRemoteLifecycleTrustSnapshot, digest_values,
    load_generation_lifecycle_trust_in_tx, require_stable_configured_host_in_tx,
};
use crate::daemon::db::{CliError, TaskBoardRemoteHostTrustFence, db_error};

pub(in crate::daemon::db::task_board) async fn claim_controller_operation_trust_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    kind: TaskBoardRemoteOperationKind,
    request_sha256: &str,
    expected: Option<&TaskBoardRemoteOperationTrustFence>,
) -> Result<TaskBoardRemoteOperationTrustFence, CliError> {
    require_sha256(request_sha256, "remote operation request digest")?;
    let generation = load_generation_lifecycle_trust_in_tx(
        transaction,
        &assignment.assignment_id,
        assignment.fencing_epoch,
    )
    .await?;
    let current = load_operation_fence_for_kind_in_tx(
        transaction,
        assignment,
        kind,
        &generation,
    )
    .await?;
    if expected.is_some_and(|expected| *expected != current) {
        return Err(concurrent(
            "remote host trust changed before I/O authority claim",
        ));
    }
    require_assignment_fence(assignment, &current, kind)?;
    generation.require_stable_transport(&current.host)?;
    let fence = operation_snapshot(&current)?;
    let trust_sha256 = operation_digest(assignment, kind, request_sha256, &fence);
    match assignment.controller_operation.as_ref() {
        None => {
            persist_operation_trust_in_tx(
                transaction,
                assignment,
                kind,
                request_sha256,
                &trust_sha256,
                Some(&fence),
            )
            .await?;
        }
        Some(operation) if operation_matches(operation, kind, request_sha256, &trust_sha256, &fence) => {}
        _ => {
            return Err(concurrent(
                "remote assignment has another active controller operation",
            ));
        }
    }
    Ok(current)
}

pub(in crate::daemon::db::task_board) async fn consume_controller_operation_trust_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    kind: TaskBoardRemoteOperationKind,
    request_sha256: &str,
) -> Result<(), CliError> {
    let generation = load_generation_lifecycle_trust_in_tx(
        transaction,
        &assignment.assignment_id,
        assignment.fencing_epoch,
    )
    .await?;
    let current = load_operation_fence_for_kind_in_tx(
        transaction,
        assignment,
        kind,
        &generation,
    )
    .await?;
    require_assignment_fence(assignment, &current, kind)?;
    generation.require_stable_transport(&current.host)?;
    let fence = operation_snapshot(&current)?;
    let trust_sha256 = operation_digest(assignment, kind, request_sha256, &fence);
    let operation = assignment.controller_operation.as_ref().ok_or_else(|| {
        concurrent("remote response lost its exact current host trust fence")
    })?;
    if !operation_matches(operation, kind, request_sha256, &trust_sha256, &fence) {
        return Err(concurrent(
            "remote response lost its exact current host trust fence",
        ));
    }
    clear_operation_trust_in_tx(transaction, assignment, operation).await
}

pub(in crate::daemon::db::task_board) async fn abandon_controller_operation_trust_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
) -> Result<(), CliError> {
    let Some(operation) = assignment.controller_operation.as_ref() else {
        return Ok(());
    };
    clear_operation_trust_in_tx(transaction, assignment, operation).await
}

pub(in crate::daemon::db::task_board) async fn require_pending_operation_replay_trust_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    kind: TaskBoardRemoteOperationKind,
    request_sha256: &str,
    expected_host: &TaskBoardRemoteHostTrustFence,
) -> Result<(), CliError> {
    require_sha256(request_sha256, "pending operation replay request digest")?;
    let current = require_stable_configured_host_in_tx(transaction, expected_host).await?;
    let generation = load_generation_lifecycle_trust_in_tx(
        transaction,
        &assignment.assignment_id,
        assignment.fencing_epoch,
    )
    .await?;
    generation.require_generation_binding(
        &assignment.host_id,
        assignment.configuration_revision,
        assignment.target_host_instance_id.as_deref(),
    )?;
    generation.require_stable_transport(&current)?;
    let operation = assignment.controller_operation.as_ref().ok_or_else(|| {
        concurrent("pending operation replay lost its immutable operation token")
    })?;
    let fence = operation.fence.as_ref().ok_or_else(|| {
        concurrent("pending operation replay has no immutable lifecycle fence")
    })?;
    fence.require_generation_binding(
        &assignment.host_id,
        assignment.configuration_revision,
        assignment.target_host_instance_id.as_deref(),
    )?;
    fence.require_stable_transport(&current)?;
    let trust_sha256 = operation_digest(assignment, kind, request_sha256, fence);
    if operation.kind == kind.as_str()
        && operation.request_sha256 == request_sha256
        && operation.trust_sha256 == trust_sha256
    {
        Ok(())
    } else {
        Err(concurrent(
            "pending operation replay does not match its immutable trust token",
        ))
    }
}

pub(in crate::daemon::db::task_board) async fn consume_pending_operation_replay_trust_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    kind: TaskBoardRemoteOperationKind,
    request_sha256: &str,
    expected_host: &TaskBoardRemoteHostTrustFence,
) -> Result<(), CliError> {
    require_pending_operation_replay_trust_in_tx(
        transaction,
        assignment,
        kind,
        request_sha256,
        expected_host,
    )
    .await?;
    let operation = assignment
        .controller_operation
        .as_ref()
        .expect("validated pending operation token");
    clear_operation_trust_in_tx(transaction, assignment, operation).await
}

pub(in crate::daemon::db::task_board) async fn require_generation_replay_trust_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    expected_host: &TaskBoardRemoteHostTrustFence,
) -> Result<(), CliError> {
    let current = require_stable_configured_host_in_tx(transaction, expected_host).await?;
    let generation = load_generation_lifecycle_trust_in_tx(
        transaction,
        &assignment.assignment_id,
        assignment.fencing_epoch,
    )
    .await?;
    generation.require_generation_binding(
        &assignment.host_id,
        assignment.configuration_revision,
        assignment.target_host_instance_id.as_deref(),
    )?;
    generation.require_stable_transport(&current)
}

pub(in crate::daemon::db::task_board) async fn persist_operation_trust_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    kind: TaskBoardRemoteOperationKind,
    request_sha256: &str,
    trust_sha256: &str,
    fence: Option<&TaskBoardRemoteLifecycleTrustSnapshot>,
) -> Result<(), CliError> {
    let fence_json = fence
        .map(TaskBoardRemoteLifecycleTrustSnapshot::encoded)
        .transpose()?;
    let fence_sha256 = fence.map(|fence| fence.snapshot_sha256.as_str());
    let rows = query(
        "UPDATE task_board_remote_assignments SET
         controller_operation_kind = ?3,
         controller_operation_request_sha256 = ?4,
         controller_operation_trust_sha256 = ?5,
         controller_operation_fence_json = ?6,
         controller_operation_fence_sha256 = ?7
         WHERE assignment_id = ?1 AND fencing_epoch = ?2
           AND controller_operation_kind IS NULL
           AND controller_operation_request_sha256 IS NULL
           AND controller_operation_trust_sha256 IS NULL
           AND controller_operation_fence_json IS NULL
           AND controller_operation_fence_sha256 IS NULL",
    )
    .bind(&assignment.assignment_id)
    .bind(to_i64(
        assignment.fencing_epoch,
        "remote operation fencing epoch",
    )?)
    .bind(kind.as_str())
    .bind(request_sha256)
    .bind(trust_sha256)
    .bind(fence_json)
    .bind(fence_sha256)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("persist remote operation trust: {error}")))?
    .rows_affected();
    if rows == 1 {
        Ok(())
    } else {
        Err(concurrent("remote operation trust claim lost its fence"))
    }
}

pub(super) fn operation_digest(
    assignment: &TaskBoardRemoteAssignmentRecord,
    kind: TaskBoardRemoteOperationKind,
    request_sha256: &str,
    fence: &TaskBoardRemoteLifecycleTrustSnapshot,
) -> String {
    digest_values(&[
        "harness.task-board.remote-operation-trust.v2",
        fence.snapshot_sha256.as_str(),
        assignment.assignment_id.as_str(),
        &assignment.fencing_epoch.to_string(),
        kind.as_str(),
        request_sha256,
    ])
}

pub(super) fn operation_snapshot(
    fence: &TaskBoardRemoteOperationTrustFence,
) -> Result<TaskBoardRemoteLifecycleTrustSnapshot, CliError> {
    TaskBoardRemoteLifecycleTrustSnapshot::capture(
        &fence.host,
        &fence.observed_host_instance_id,
        &fence.advertisement_sha256,
    )
}

fn require_assignment_fence(
    assignment: &TaskBoardRemoteAssignmentRecord,
    current: &TaskBoardRemoteOperationTrustFence,
    kind: TaskBoardRemoteOperationKind,
) -> Result<(), CliError> {
    let same_host = current.host.config.host_id == assignment.host_id;
    let exact = if kind.requires_enabled_host() {
        current.host.config.enabled
            && same_host
            && assignment.configuration_revision == Some(current.host.configuration_revision)
            && assignment.target_host_instance_id.as_deref()
                == Some(current.observed_host_instance_id.as_str())
    } else {
        same_host
            && assignment
                .configuration_revision
                .is_some_and(|revision| current.host.configuration_revision >= revision)
    };
    if exact {
        Ok(())
    } else {
        Err(concurrent(
            "remote operation does not match current configured host evidence",
        ))
    }
}

fn operation_matches(
    operation: &crate::daemon::db::TaskBoardRemoteControllerOperationToken,
    kind: TaskBoardRemoteOperationKind,
    request_sha256: &str,
    trust_sha256: &str,
    fence: &TaskBoardRemoteLifecycleTrustSnapshot,
) -> bool {
    operation.kind == kind.as_str()
        && operation.request_sha256 == request_sha256
        && operation.trust_sha256 == trust_sha256
        && operation.fence.as_ref() == Some(fence)
}

pub(super) async fn clear_operation_trust_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    operation: &crate::daemon::db::TaskBoardRemoteControllerOperationToken,
) -> Result<(), CliError> {
    let fence_json = operation
        .fence
        .as_ref()
        .map(TaskBoardRemoteLifecycleTrustSnapshot::encoded)
        .transpose()?;
    let fence_sha256 = operation
        .fence
        .as_ref()
        .map(|fence| fence.snapshot_sha256.as_str());
    let rows = query(
        "UPDATE task_board_remote_assignments SET
         controller_operation_kind = NULL,
         controller_operation_request_sha256 = NULL,
         controller_operation_trust_sha256 = NULL,
         controller_operation_fence_json = NULL,
         controller_operation_fence_sha256 = NULL
         WHERE assignment_id = ?1 AND fencing_epoch = ?2
           AND controller_operation_kind = ?3
           AND controller_operation_request_sha256 = ?4
           AND controller_operation_trust_sha256 = ?5
           AND controller_operation_fence_json IS ?6
           AND controller_operation_fence_sha256 IS ?7",
    )
    .bind(&assignment.assignment_id)
    .bind(to_i64(
        assignment.fencing_epoch,
        "remote operation fencing epoch",
    )?)
    .bind(&operation.kind)
    .bind(&operation.request_sha256)
    .bind(&operation.trust_sha256)
    .bind(fence_json)
    .bind(fence_sha256)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("clear remote operation trust: {error}")))?
    .rows_affected();
    if rows == 1 {
        Ok(())
    } else {
        Err(concurrent("remote operation trust clear lost its fence"))
    }
}
