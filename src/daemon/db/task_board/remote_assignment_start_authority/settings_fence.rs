//! Provisioning revalidation and the final Start-I/O settings fence.

use sqlx::{Sqlite, Transaction, query, query_scalar};

use super::{
    TaskBoardRemoteExecutorIdentity, TaskBoardRemoteExecutorStartAuthority,
    executor_settings_still_match, executor_start_authority, executor_start_io_permit,
    start_authority_eligible,
};
use crate::daemon::db::task_board::remote_assignment_lease::{
    commit_noop, finish_mutation, require_assignment,
};
use crate::daemon::db::task_board::remote_assignment_model::{
    TaskBoardRemoteMutationOutcome, canonical_time, concurrent, nonblank, to_i64,
};
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};

const SETTINGS_CHANGED_BEFORE_START: &str =
    "remote executor settings changed before worker start";
const EXECUTOR_RESTARTED_BEFORE_START: &str =
    "remote executor restarted before worker start";

pub(crate) async fn refuse_settings_replacement_during_executor_start_io(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<(), CliError> {
    let active = query_scalar::<_, String>(
        "SELECT assignment_id
         FROM task_board_remote_assignments
         WHERE executor_start_io_permit_sha256 IS NOT NULL
         ORDER BY assignment_id
         LIMIT 1",
    )
    .fetch_optional(transaction.as_mut())
    .await
        .map_err(|error| db_error(format!("fence executor Start I/O settings: {error}")))?;
    if let Some(assignment_id) = active {
        return Err(concurrent(format!(
            "remote executor assignment '{assignment_id}' owns Start I/O; settings replacement is fenced"
        )));
    }
    Ok(())
}

pub(super) async fn revoke_unpermitted_start_in_tx(
    mut transaction: Transaction<'_, Sqlite>,
    record: &crate::daemon::db::TaskBoardRemoteAssignmentRecord,
    identity: &TaskBoardRemoteExecutorIdentity,
    observed_at: &str,
) -> Result<(), CliError> {
    let rows = query(
        "UPDATE task_board_remote_assignments
         SET state = 'unknown', error = ?2, updated_at = ?3
         WHERE assignment_id = ?1 AND fencing_epoch = ?4 AND state = 'claimed'
           AND executor_start_authority_sha256 IS NULL
           AND executor_start_authority_at IS NULL
           AND executor_stop_pending_sha256 IS NULL
           AND NOT EXISTS(SELECT 1 FROM codex_runs WHERE run_id = ?5)
           AND NOT EXISTS(SELECT 1 FROM sessions WHERE session_id = ?6)",
    )
    .bind(&record.assignment_id)
    .bind(SETTINGS_CHANGED_BEFORE_START)
    .bind(observed_at)
    .bind(to_i64(record.fencing_epoch, "assignment fencing epoch")?)
    .bind(&identity.run_id)
    .bind(&identity.session_id)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("revoke unpermitted remote executor start: {error}")))?
    .rows_affected();
    if rows != 1 {
        return Err(concurrent(
            "remote executor settings revocation lost its exact empty-workspace fence",
        ));
    }
    let _ = finish_mutation(
        transaction,
        &record.assignment_id,
        "remote executor settings revocation",
    )
    .await?;
    Ok(())
}

impl AsyncDaemonDb {
    /// Revalidates frozen executor settings while provisioning remains reversible.
    /// The caller must still claim the distinct durable Start-I/O permit after provisioning.
    pub(crate) async fn authorize_task_board_remote_executor_provisioning(
        &self,
        authority: &TaskBoardRemoteExecutorStartAuthority,
        authorized_at: &str,
    ) -> Result<Option<TaskBoardRemoteExecutorStartAuthority>, CliError> {
        canonical_time(authorized_at, "remote executor Start I/O authority time")?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote executor Start I/O authority")
            .await?;
        let record = require_assignment(&mut transaction, &authority.assignment_id).await?;
        if record.executor_stop_pending.is_some()
            || executor_start_authority(&record)?.as_ref() != Some(authority)
        {
            commit_noop(transaction, "stale remote executor Start I/O authority").await?;
            return Ok(None);
        }
        if executor_start_io_permit(&record)?.is_some() {
            let replay = authority.clone();
            commit_noop(transaction, "replayed permitted remote executor provisioning").await?;
            return Ok(Some(replay));
        }
        let settings_match = executor_settings_still_match(&mut transaction, &record).await?;
        let window_open = start_authority_eligible(
            &record,
            record
                .claimed_host_instance_id
                .as_deref()
                .ok_or_else(|| db_error("remote executor start has no claimed host"))?,
            authorized_at,
        )?;
        if settings_match && window_open {
            let replay = authority.clone();
            commit_noop(transaction, "authorized remote executor Start I/O").await?;
            return Ok(Some(replay));
        }
        commit_noop(
            transaction,
            "remote executor Start I/O requires provisioning cleanup",
        )
        .await?;
        Ok(None)
    }

    pub(crate) async fn revoke_task_board_remote_executor_start_after_cleanup(
        &self,
        authority: &TaskBoardRemoteExecutorStartAuthority,
        observed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        canonical_time(observed_at, "remote executor Start cleanup time")?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote executor Start cleanup")
            .await?;
        let record = require_assignment(&mut transaction, &authority.assignment_id).await?;
        if record.executor_stop_pending.is_some()
            || executor_start_authority(&record)?.as_ref() != Some(authority)
            || executor_start_io_permit(&record)?.is_some()
        {
            commit_noop(transaction, "stale remote executor Start cleanup").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        let settings_match = executor_settings_still_match(&mut transaction, &record).await?;
        let window_open = start_authority_eligible(
            &record,
            record
                .claimed_host_instance_id
                .as_deref()
                .ok_or_else(|| db_error("remote executor start has no claimed host"))?,
            observed_at,
        )?;
        if settings_match && window_open {
            commit_noop(transaction, "live remote executor Start cleanup").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        require_empty_provisioning(&mut transaction, authority).await?;
        let reason = if settings_match {
            "remote assignment expired before executor start"
        } else {
            SETTINGS_CHANGED_BEFORE_START
        };
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
               AND executor_stop_pending_sha256 IS NULL
               AND NOT EXISTS(SELECT 1 FROM codex_runs WHERE run_id = ?7)
               AND NOT EXISTS(SELECT 1 FROM sessions WHERE session_id = ?8)",
        )
        .bind(&record.assignment_id)
        .bind(reason)
        .bind(observed_at)
        .bind(to_i64(record.fencing_epoch, "assignment fencing epoch")?)
        .bind(&authority.sha256)
        .bind(&authority.acquired_at)
        .bind(&authority.identity.run_id)
        .bind(&authority.identity.session_id)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("revoke remote executor Start I/O: {error}")))?
        .rows_affected();
        if rows != 1 {
            return Err(concurrent("remote executor Start I/O revocation lost its fence"));
        }
        finish_mutation(
            transaction,
            &record.assignment_id,
            "remote executor Start I/O revocation",
        )
        .await
    }

    pub(crate) async fn abandon_task_board_remote_executor_start_after_restart(
        &self,
        authority: &TaskBoardRemoteExecutorStartAuthority,
        successor_instance_id: &str,
        observed_at: &str,
    ) -> Result<TaskBoardRemoteMutationOutcome, CliError> {
        nonblank(successor_instance_id, "remote executor successor instance")?;
        canonical_time(observed_at, "remote executor restart cleanup time")?;
        let mut transaction = self
            .begin_immediate_transaction("task board remote executor restart cleanup")
            .await?;
        let record = require_assignment(&mut transaction, &authority.assignment_id).await?;
        if record.executor_stop_pending.is_some()
            || executor_start_authority(&record)?.as_ref() != Some(authority)
            || record.claimed_host_instance_id.as_deref() == Some(successor_instance_id)
        {
            commit_noop(transaction, "stale remote executor restart cleanup").await?;
            return Ok(TaskBoardRemoteMutationOutcome::Stale(record));
        }
        require_empty_provisioning(&mut transaction, authority).await?;
        let permit = executor_start_io_permit(&record)?;
        let rows = query(
            "UPDATE task_board_remote_assignments
             SET state = 'unknown', error = ?2,
                 executor_start_authority_sha256 = NULL,
                 executor_start_authority_at = NULL,
                 executor_start_io_permit_sha256 = NULL,
                 executor_start_io_permit_at = NULL, updated_at = ?3
             WHERE assignment_id = ?1 AND fencing_epoch = ?4 AND state = 'claimed'
               AND claimed_host_instance_id != ?5
               AND target_host_instance_id = claimed_host_instance_id
               AND executor_start_authority_sha256 = ?6
               AND executor_start_authority_at = ?7
               AND executor_stop_pending_sha256 IS NULL
               AND executor_start_io_permit_sha256 IS ?8
               AND executor_start_io_permit_at IS ?9
               AND NOT EXISTS(SELECT 1 FROM codex_runs WHERE run_id = ?10)
               AND NOT EXISTS(SELECT 1 FROM sessions WHERE session_id = ?11)",
        )
        .bind(&record.assignment_id)
        .bind(EXECUTOR_RESTARTED_BEFORE_START)
        .bind(observed_at)
        .bind(to_i64(record.fencing_epoch, "assignment fencing epoch")?)
        .bind(successor_instance_id)
        .bind(&authority.sha256)
        .bind(&authority.acquired_at)
        .bind(permit.as_ref().map(|permit| permit.sha256.as_str()))
        .bind(permit.as_ref().map(|permit| permit.permitted_at.as_str()))
        .bind(&authority.identity.run_id)
        .bind(&authority.identity.session_id)
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("abandon predecessor executor start: {error}")))?
        .rows_affected();
        if rows != 1 {
            return Err(concurrent("remote executor restart cleanup lost its fence"));
        }
        finish_mutation(
            transaction,
            &record.assignment_id,
            "remote executor restart cleanup",
        )
        .await
    }
}

async fn require_empty_provisioning(
    transaction: &mut Transaction<'_, Sqlite>,
    authority: &TaskBoardRemoteExecutorStartAuthority,
) -> Result<(), CliError> {
    let run_exists = query_scalar::<_, bool>(
        "SELECT EXISTS(SELECT 1 FROM codex_runs WHERE run_id = ?1)",
    )
    .bind(&authority.identity.run_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("check pre-Start executor run: {error}")))?;
    let session_exists = query_scalar::<_, bool>(
        "SELECT EXISTS(SELECT 1 FROM sessions WHERE session_id = ?1)",
    )
    .bind(&authority.identity.session_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("check pre-Start executor session: {error}")))?;
    if run_exists || session_exists {
        Err(concurrent(
            "remote executor Start cleanup found durable provisioning evidence",
        ))
    } else {
        Ok(())
    }
}
