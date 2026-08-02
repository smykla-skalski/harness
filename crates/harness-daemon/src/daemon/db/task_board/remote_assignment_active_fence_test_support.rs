//! `#[cfg(test)]`-only fencing check, split out of `remote_assignment_active_fence.rs`
//! to keep that file under the repo's line cap. Mirrors
//! [`super::active_remote_assignment_exists_in_tx`]'s query but reads
//! outside a transaction and can optionally pin to one fencing epoch.

use sqlx::query_scalar;

use super::super::remote_assignment_authority_queries::RemoteAssignmentAuthorityQueries;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};

impl AsyncDaemonDb {
    /// Conservatively fences local work while any unresolved controller generation exists.
    ///
    /// An older claimed worker can still produce side effects after workflow ownership advances,
    /// so only dedicated terminal or fallback settlement releases this execution-wide fence.
    pub(crate) async fn task_board_execution_has_active_remote_assignment(
        &self,
        execution_id: &str,
    ) -> Result<bool, CliError> {
        <Self as RemoteAssignmentAuthorityQueries>::task_board_execution_has_active_remote_assignment(
            self, execution_id,
        )
        .await
    }

    pub(crate) async fn task_board_execution_generation_has_active_remote_assignment(
        &self,
        execution_id: &str,
        fencing_epoch: u64,
    ) -> Result<bool, CliError> {
        <Self as RemoteAssignmentAuthorityQueries>::task_board_execution_generation_has_active_remote_assignment(
            self, execution_id, fencing_epoch,
        )
        .await
    }
}

pub(in super::super) async fn task_board_execution_has_active_remote_assignment(
    db: &AsyncDaemonDb,
    execution_id: &str,
) -> Result<bool, CliError> {
    active_remote_assignment_exists(db, execution_id, None).await
}

pub(in super::super) async fn task_board_execution_generation_has_active_remote_assignment(
    db: &AsyncDaemonDb,
    execution_id: &str,
    fencing_epoch: u64,
) -> Result<bool, CliError> {
    active_remote_assignment_exists(db, execution_id, Some(fencing_epoch)).await
}

async fn active_remote_assignment_exists(
    db: &AsyncDaemonDb,
    execution_id: &str,
    fencing_epoch: Option<u64>,
) -> Result<bool, CliError> {
    if execution_id.trim().is_empty() {
        return Err(db_error("remote assignment execution id is blank"));
    }
    let epoch = fencing_epoch
        .map(|value| {
            i64::try_from(value)
                .map_err(|_| db_error("remote assignment fencing epoch is out of range"))
        })
        .transpose()?;
    query_scalar::<_, i64>(
        "SELECT EXISTS(
             SELECT 1
             FROM task_board_remote_assignments AS assignments
             JOIN task_board_execution_hosts AS hosts USING (host_id)
             WHERE assignments.execution_id = ?1
               AND (?2 IS NULL OR assignments.fencing_epoch = ?2)
               AND hosts.host_role = 'controller_remote'
               AND assignments.legacy_migrated = 0
               AND NOT COALESCE((
                   (
                       (assignments.controller_handoff_kind = 'local_fallback'
                        AND assignments.state = 'superseded'
                        AND assignments.controller_handoff_successor_assignment_id IS NULL
                        AND assignments.controller_handoff_successor_fencing_epoch IS NULL)
                       OR (assignments.controller_handoff_kind = 'remote_reassigned'
                           AND assignments.state = 'superseded'
                           AND EXISTS (
                               SELECT 1
                               FROM task_board_remote_assignments AS successor
                               WHERE successor.assignment_id =
                                   assignments.controller_handoff_successor_assignment_id
                                 AND successor.fencing_epoch =
                                   assignments.controller_handoff_successor_fencing_epoch
                                 AND successor.execution_id = assignments.execution_id
                                 AND successor.legacy_migrated = 0
                           ))
                       OR (assignments.controller_handoff_kind = 'result_adopted'
                           AND assignments.state IN ('completed', 'failed')
                           AND assignments.controller_handoff_successor_assignment_id IS NULL
                           AND assignments.controller_handoff_successor_fencing_epoch IS NULL)
                       OR (assignments.controller_handoff_kind = 'evidence_only'
                           AND assignments.state IN (
                               'completed', 'failed', 'cancelled', 'unknown'
                           )
                           AND assignments.controller_handoff_successor_assignment_id IS NULL
                           AND assignments.controller_handoff_successor_fencing_epoch IS NULL)
                       OR (assignments.controller_handoff_kind = 'terminal_projection'
                           AND assignments.state IN ('completed', 'failed', 'cancelled')
                           AND assignments.controller_handoff_successor_assignment_id IS NULL
                           AND assignments.controller_handoff_successor_fencing_epoch IS NULL)
                       OR (assignments.controller_handoff_kind = 'terminal_cleanup'
                           AND assignments.state IN (
                               'completed', 'failed', 'cancelled', 'superseded', 'unknown'
                           )
                           AND assignments.cleanup_settlement_request_sha256 IS NOT NULL
                           AND assignments.cleanup_completed_at IS NOT NULL
                           AND assignments.controller_handoff_successor_assignment_id IS NULL
                           AND assignments.controller_handoff_successor_fencing_epoch IS NULL)
                   )
                   AND length(assignments.controller_handoff_execution_sha256) = 64
                   AND assignments.controller_handoff_execution_sha256
                       NOT GLOB '*[^0-9a-f]*'
                   AND length(trim(assignments.controller_handoff_at)) > 0
               ), 0)
         )",
    )
    .bind(execution_id)
    .bind(epoch)
    .fetch_one(db.pool())
    .await
    .map(|exists| exists != 0)
    .map_err(|error| db_error(format!("load active remote assignment fence: {error}")))
}
