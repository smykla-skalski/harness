//! Cleanup-observation trust survives executor restart and host disablement.

use sqlx::{Sqlite, Transaction, query};

use super::{
    TaskBoardRemoteOperationKind, load_operation_fence_for_kind_in_tx,
    persist_operation_trust_in_tx, require_sha256,
};
use crate::daemon::db::task_board::remote_assignment_model::{concurrent, to_i64};
use crate::daemon::db::task_board::remote_lifecycle_trust::{
    TaskBoardRemoteLifecycleTrustSnapshot, digest_values, load_generation_lifecycle_trust_in_tx,
};
use crate::daemon::db::{
    CliError, TaskBoardRemoteAssignmentRecord, TaskBoardRemoteHostTrustFence,
    TaskBoardRemoteOperationTrustFence, db_error,
};

pub(in crate::daemon::db::task_board) async fn claim_cleanup_observation_trust_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    request_sha256: &str,
    parent_record_sha256: &str,
    expected: &TaskBoardRemoteHostTrustFence,
) -> Result<(), CliError> {
    require_sha256(request_sha256, "remote cleanup observation request digest")?;
    require_sha256(parent_record_sha256, "remote cleanup parent record digest")?;
    let (_, fence) = cleanup_fence_in_tx(transaction, assignment, expected).await?;
    let trust_sha256 =
        cleanup_operation_digest(assignment, request_sha256, parent_record_sha256, &fence);
    match assignment.controller_operation.as_ref() {
        None => {
            persist_operation_trust_in_tx(
                transaction,
                assignment,
                TaskBoardRemoteOperationKind::ObserveCleanup,
                request_sha256,
                &trust_sha256,
                Some(&fence),
            )
            .await
        }
        Some(operation)
            if cleanup_operation_matches(operation, request_sha256, &trust_sha256, &fence) =>
        {
            Ok(())
        }
        Some(operation)
            if operation.kind == TaskBoardRemoteOperationKind::ObserveCleanup.as_str()
                && operation.request_sha256 == request_sha256 =>
        {
            replace_operation_trust_in_tx(
                transaction,
                assignment,
                request_sha256,
                &operation.trust_sha256,
                operation.fence.as_ref(),
                &trust_sha256,
                &fence,
            )
            .await
        }
        _ => Err(concurrent(
            "remote cleanup observation conflicts with another controller operation",
        )),
    }
}

pub(in crate::daemon::db::task_board) async fn consume_cleanup_observation_trust_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    request_sha256: &str,
    parent_record_sha256: &str,
    expected: &TaskBoardRemoteHostTrustFence,
) -> Result<(), CliError> {
    require_sha256(parent_record_sha256, "remote cleanup parent record digest")?;
    let (_, fence) = cleanup_fence_in_tx(transaction, assignment, expected).await?;
    let trust_sha256 =
        cleanup_operation_digest(assignment, request_sha256, parent_record_sha256, &fence);
    let exact = assignment
        .controller_operation
        .as_ref()
        .is_some_and(|operation| {
            cleanup_operation_matches(operation, request_sha256, &trust_sha256, &fence)
        });
    if !exact {
        return Err(concurrent(
            "remote cleanup response lost its configured host trust fence",
        ));
    }
    clear_operation_trust_in_tx(
        transaction,
        assignment,
        request_sha256,
        &trust_sha256,
        &fence,
    )
    .await
}

async fn cleanup_fence_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    expected: &TaskBoardRemoteHostTrustFence,
) -> Result<
    (
        TaskBoardRemoteOperationTrustFence,
        TaskBoardRemoteLifecycleTrustSnapshot,
    ),
    CliError,
> {
    let generation = load_generation_lifecycle_trust_in_tx(
        transaction,
        &assignment.assignment_id,
        assignment.fencing_epoch,
    )
    .await?;
    let current = load_operation_fence_for_kind_in_tx(
        transaction,
        assignment,
        TaskBoardRemoteOperationKind::ObserveCleanup,
        &generation,
    )
    .await?;
    require_cleanup_host_fence(assignment, &current.host, expected)?;
    let fence = TaskBoardRemoteLifecycleTrustSnapshot::capture(
        &current.host,
        &current.observed_host_instance_id,
        &current.advertisement_sha256,
    )?;
    Ok((current, fence))
}

async fn clear_operation_trust_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    request_sha256: &str,
    trust_sha256: &str,
    fence: &TaskBoardRemoteLifecycleTrustSnapshot,
) -> Result<(), CliError> {
    let fence_json = fence.encoded()?;
    let rows = query(
        "UPDATE task_board_remote_assignments SET
         controller_operation_kind = NULL,
         controller_operation_request_sha256 = NULL,
         controller_operation_trust_sha256 = NULL,
         controller_operation_fence_json = NULL,
         controller_operation_fence_sha256 = NULL
         WHERE assignment_id = ?1 AND fencing_epoch = ?2
           AND controller_operation_kind = 'observe_cleanup'
           AND controller_operation_request_sha256 = ?3
           AND controller_operation_trust_sha256 = ?4
           AND controller_operation_fence_json = ?5
           AND controller_operation_fence_sha256 = ?6",
    )
    .bind(&assignment.assignment_id)
    .bind(to_i64(
        assignment.fencing_epoch,
        "remote cleanup operation fencing epoch",
    )?)
    .bind(request_sha256)
    .bind(trust_sha256)
    .bind(fence_json)
    .bind(&fence.snapshot_sha256)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("clear remote cleanup trust: {error}")))?
    .rows_affected();
    if rows == 1 {
        Ok(())
    } else {
        Err(concurrent("remote cleanup trust clear lost its fence"))
    }
}

async fn replace_operation_trust_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment: &TaskBoardRemoteAssignmentRecord,
    request_sha256: &str,
    prior_trust_sha256: &str,
    prior_fence: Option<&TaskBoardRemoteLifecycleTrustSnapshot>,
    next_trust_sha256: &str,
    next_fence: &TaskBoardRemoteLifecycleTrustSnapshot,
) -> Result<(), CliError> {
    let prior_fence = prior_fence
        .ok_or_else(|| concurrent("remote cleanup rollover lost its immutable lifecycle fence"))?;
    let prior_fence_json = prior_fence.encoded()?;
    let next_fence_json = next_fence.encoded()?;
    let rows = query(
        "UPDATE task_board_remote_assignments
         SET controller_operation_trust_sha256 = ?5,
             controller_operation_fence_json = ?6,
             controller_operation_fence_sha256 = ?7
         WHERE assignment_id = ?1 AND fencing_epoch = ?2
           AND controller_operation_kind = 'observe_cleanup'
           AND controller_operation_request_sha256 = ?3
           AND controller_operation_trust_sha256 = ?4
           AND controller_operation_fence_json = ?8
           AND controller_operation_fence_sha256 = ?9",
    )
    .bind(&assignment.assignment_id)
    .bind(to_i64(
        assignment.fencing_epoch,
        "remote cleanup operation rollover fencing epoch",
    )?)
    .bind(request_sha256)
    .bind(prior_trust_sha256)
    .bind(next_trust_sha256)
    .bind(next_fence_json)
    .bind(&next_fence.snapshot_sha256)
    .bind(prior_fence_json)
    .bind(&prior_fence.snapshot_sha256)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("roll remote cleanup trust: {error}")))?
    .rows_affected();
    if rows == 1 {
        Ok(())
    } else {
        Err(concurrent("remote cleanup trust rollover lost its fence"))
    }
}

fn cleanup_operation_digest(
    assignment: &TaskBoardRemoteAssignmentRecord,
    request_sha256: &str,
    parent_record_sha256: &str,
    fence: &TaskBoardRemoteLifecycleTrustSnapshot,
) -> String {
    digest_values(&[
        "harness.task-board.remote-cleanup-trust.v1",
        fence.snapshot_sha256.as_str(),
        assignment.assignment_id.as_str(),
        &assignment.fencing_epoch.to_string(),
        request_sha256,
        parent_record_sha256,
    ])
}

fn cleanup_operation_matches(
    operation: &crate::daemon::db::TaskBoardRemoteControllerOperationToken,
    request_sha256: &str,
    trust_sha256: &str,
    fence: &TaskBoardRemoteLifecycleTrustSnapshot,
) -> bool {
    operation.kind == TaskBoardRemoteOperationKind::ObserveCleanup.as_str()
        && operation.request_sha256 == request_sha256
        && operation.trust_sha256 == trust_sha256
        && operation.fence.as_ref() == Some(fence)
}

fn require_cleanup_host_fence(
    assignment: &TaskBoardRemoteAssignmentRecord,
    current: &TaskBoardRemoteHostTrustFence,
    expected: &TaskBoardRemoteHostTrustFence,
) -> Result<(), CliError> {
    if current == expected && current.config.host_id == assignment.host_id {
        Ok(())
    } else {
        Err(concurrent(
            "remote cleanup host trust changed during observation I/O",
        ))
    }
}
