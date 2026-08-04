use std::path::Path;

use sqlx::{query, query_scalar};

use super::super::remote_assignment_lease::{commit_noop, finish_mutation, require_assignment};
use super::super::remote_assignment_lifecycle_owner::lifecycle_owner_expiry;
use super::super::remote_assignment_model::{
    TaskBoardRemoteMutationOutcome, canonical_time, concurrent, nonblank, to_i64,
};
use super::super::remote_execution_queries::RemoteExecutionQueries;
use super::super::remote_start_receipts::{
    InitialLifecycleOwner, durable_start_receipt_run_matches, start_receipt,
};
use super::start_adoption;
use super::{
    TaskBoardRemoteExecutorStartAuthority, TaskBoardRemoteExecutorStartIoPermit,
    executor_settings_still_match, executor_start_authority, executor_start_io_permit,
    start_adoption_replays,
};
use crate::daemon::db::prelude::*;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};

pub(in super::super) async fn adopt_task_board_remote_executor_start(
    db: &AsyncDaemonDb,
    permit: &TaskBoardRemoteExecutorStartIoPermit,
    project_dir: &Path,
    started_at: &str,
) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
    let record = db
        .task_board_remote_assignment(&permit.assignment_id)
        .await?
        .ok_or_else(|| db_error("remote executor start assignment disappeared"))?;
    let owner_instance_id = record
        .claimed_host_instance_id
        .ok_or_else(|| db_error("remote executor start has no claimed host"))?;
    adopt_task_board_remote_executor_start_owned(
        db,
        permit,
        project_dir,
        started_at,
        &owner_instance_id,
        started_at,
    )
    .await
}

#[expect(
    clippy::cognitive_complexity,
    reason = "fenced transaction guard chain; each guard settles the transaction before returning"
)]
pub(in super::super) async fn adopt_task_board_remote_executor_start_owned(
    db: &AsyncDaemonDb,
    permit: &TaskBoardRemoteExecutorStartIoPermit,
    project_dir: &Path,
    started_at: &str,
    owner_instance_id: &str,
    owner_at: &str,
) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
    let started = canonical_time(started_at, "remote executor durable start time")?;
    nonblank(
        owner_instance_id,
        "remote executor lifecycle owner instance",
    )?;
    let owner_at_time = canonical_time(owner_at, "remote executor lifecycle owner time")?;
    let project_dir = project_dir.to_string_lossy().into_owned();
    let mut transaction = db
        .begin_immediate_transaction("task board remote executor start adoption")
        .await?;
    let record = require_assignment(&mut transaction, &permit.assignment_id).await?;
    if record.executor_stop_pending.is_some() {
        commit_noop(
            transaction,
            "remote executor start is permanently stop-only",
        )
        .await?;
        return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
    }
    if start_adoption_replays(&record, permit, &project_dir, started_at, &mut transaction).await? {
        commit_noop(transaction, "replayed remote executor start adoption").await?;
        return Ok(TaskBoardRemoteMutationOutcome::Replayed(record));
    }
    let Some(current) = executor_start_io_permit(&record)? else {
        commit_noop(transaction, "stale remote executor start adoption").await?;
        return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
    };
    if current != *permit {
        commit_noop(transaction, "stale durable remote executor start").await?;
        return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
    }
    if !executor_settings_still_match(&mut transaction, &record).await? {
        commit_noop(
            transaction,
            "remote executor settings changed before start adoption",
        )
        .await?;
        return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
    }
    let authority_at =
        canonical_time(&permit.permitted_at, "remote executor start authority time")?;
    if started < authority_at || owner_at_time < started {
        commit_noop(
            transaction,
            "stale durable remote executor start chronology",
        )
        .await?;
        return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
    }
    let owner_expires_at = lifecycle_owner_expiry(owner_at)?;
    let initial_owner = InitialLifecycleOwner {
        instance_id: owner_instance_id,
        acquired_at: owner_at,
        expires_at: &owner_expires_at,
    };
    let receipt = start_receipt(&record, permit, &project_dir, started_at, &initial_owner)?;
    if !durable_start_receipt_run_matches(&mut transaction, &record, &receipt).await? {
        commit_noop(transaction, "stale durable remote executor start").await?;
        return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
    }
    start_adoption::persist_start_adoption_in_tx(
        &mut transaction,
        &record,
        permit,
        &receipt,
        start_adoption::TaskBoardRemoteStartAdoptionContext {
            started_at,
            owner_instance_id,
            owner_at,
            owner_expires_at: &owner_expires_at,
        },
    )
    .await?;
    finish_mutation(
        transaction,
        &record.assignment_id,
        "executor start adoption",
    )
    .await
}

#[expect(
    clippy::cognitive_complexity,
    reason = "fenced transaction guard chain; each guard settles the transaction before returning"
)]
pub(in super::super) async fn expire_task_board_remote_executor_start_without_run(
    db: &AsyncDaemonDb,
    authority: &TaskBoardRemoteExecutorStartAuthority,
    reason: &str,
    observed_at: &str,
) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
    nonblank(reason, "remote executor start expiry reason")?;
    canonical_time(observed_at, "remote executor start expiry time")?;
    let mut transaction = db
        .begin_immediate_transaction("task board remote executor start expiry")
        .await?;
    let record = require_assignment(&mut transaction, &authority.assignment_id).await?;
    if record.executor_stop_pending.is_some()
        || executor_start_authority(&record)?.as_ref() != Some(authority)
        || executor_start_io_permit(&record)?.is_some()
    {
        commit_noop(transaction, "stale remote executor start expiry").await?;
        return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
    }
    let observed = canonical_time(observed_at, "remote executor start expiry time")?;
    let lease = canonical_time(
        record
            .lease_expires_at
            .as_deref()
            .ok_or_else(|| db_error("remote executor start has no lease expiry"))?,
        "remote executor lease expiry",
    )?;
    let deadline = canonical_time(
        record
            .deadline_at
            .as_deref()
            .ok_or_else(|| db_error("remote executor start has no deadline"))?,
        "remote executor deadline",
    )?;
    if observed < lease && observed < deadline {
        commit_noop(transaction, "early remote executor start expiry").await?;
        return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
    }
    let run_exists =
        query_scalar::<_, bool>("SELECT EXISTS(SELECT 1 FROM codex_runs WHERE run_id = ?1 UNION ALL SELECT 1 FROM agent_turn_runs WHERE run_id = ?1)")
            .bind(&authority.identity.run_id)
            .fetch_one(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("check remote executor start run: {error}")))?;
    let session_exists =
        query_scalar::<_, bool>("SELECT EXISTS(SELECT 1 FROM sessions WHERE session_id = ?1)")
            .bind(&authority.identity.session_id)
            .fetch_one(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("check remote executor start session: {error}")))?;
    if run_exists || session_exists {
        return Err(concurrent(
            "remote executor start authority has durable provisioning evidence",
        ));
    }
    let rows = query(
        "UPDATE task_board_remote_assignments
         SET state = 'unknown', error = ?2,
             executor_start_authority_sha256 = NULL,
             executor_start_authority_at = NULL, updated_at = ?3
         WHERE assignment_id = ?1 AND fencing_epoch = ?4 AND state = 'claimed'
           AND executor_start_authority_sha256 = ?5
           AND executor_start_authority_at = ?6
           AND executor_start_io_permit_sha256 IS NULL
           AND executor_start_io_permit_at IS NULL
           AND NOT EXISTS(SELECT 1 FROM sessions WHERE session_id = ?7)",
    )
    .bind(&record.assignment_id)
    .bind(reason)
    .bind(observed_at)
    .bind(to_i64(record.fencing_epoch, "assignment fencing epoch")?)
    .bind(&authority.sha256)
    .bind(&authority.acquired_at)
    .bind(&authority.identity.session_id)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("expire remote executor start: {error}")))?
    .rows_affected();
    if rows != 1 {
        return Err(concurrent("remote executor start expiry lost its fence"));
    }
    finish_mutation(transaction, &record.assignment_id, "executor start expiry").await
}
