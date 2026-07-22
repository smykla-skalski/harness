use sqlx::{Sqlite, Transaction, query_as};

use super::remote_assignment_model::{concurrent, to_i64};
use crate::daemon::db::{CliError, db_error};

/// Legacy-migrated (`legacy_migrated = 1`) assignments are frozen archival
/// evidence that keep their exact v40 identity. Every current-row guard - the
/// partial unique indexes and the typed collision query alike - scopes to
/// `legacy_migrated = 0`, and the active-state idempotency guards never see a
/// `superseded` archival row, so a new mutation that reused an archived
/// `assignment_id`, `idempotency_key`, request digest, or preserved
/// `(execution_id, fencing_epoch)` generation would slip past all of them. This
/// raw probe closes that gap: it reads only the stable identity columns, never
/// decodes phase/state (archival rows are structurally undecodable), and omits
/// the exact-attempt tuple (archival rows carry NULL `action_key`/`attempt`).
const ARCHIVAL_COLLISION_SELECT: &str = "SELECT assignment_id, idempotency_key, request_sha256
    FROM task_board_remote_assignments
    WHERE legacy_migrated = 1
      AND (assignment_id = ?1 OR idempotency_key = ?2 OR request_sha256 = ?3
           OR (execution_id = ?4 AND fencing_epoch = ?5))
    ORDER BY assignment_id
    LIMIT 1";

/// Fail closed with a deterministic `ConcurrentModification` when a mutation's
/// identity collides with any archived legacy assignment. An exact idempotent
/// replay is only ever honoured when the archival probe is empty, so callers
/// wire this before their current-row collision resolution.
pub(super) async fn require_no_archival_collision_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    assignment_id: &str,
    idempotency_key: &str,
    request_sha256: Option<&str>,
    execution_id: &str,
    fencing_epoch: u64,
) -> Result<(), CliError> {
    let archived = query_as::<_, (String, String, Option<String>)>(ARCHIVAL_COLLISION_SELECT)
        .bind(assignment_id)
        .bind(idempotency_key)
        .bind(request_sha256)
        .bind(execution_id)
        .bind(to_i64(fencing_epoch, "archival collision fencing epoch")?)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| {
            db_error(format!("probe archival remote assignment collision: {error}"))
        })?;
    if let Some((archived_id, _, _)) = archived {
        return Err(concurrent(format!(
            "remote assignment identity collides with archived legacy assignment '{archived_id}'"
        )));
    }
    Ok(())
}
