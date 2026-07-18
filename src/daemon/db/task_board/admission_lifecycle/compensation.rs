use sqlx::{Sqlite, Transaction, query, query_as, query_scalar};

use super::super::{ITEMS_CHANGE_SCOPE, items::bump_change_in_tx};
use super::validation::{CurrentAllowedAdmission, current_allowed_admission, decode_requirements};
use crate::daemon::db::{CliError, db_error, utc_now};
use crate::task_board::TaskBoardAdmissionRequirementKind;

pub(in crate::daemon::db::task_board) async fn commit_compensating_dispatch_admission_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    managed_worker_id: &str,
) -> Result<(), CliError> {
    if managed_worker_id.is_empty() {
        return Err(db_error(
            "task board compensation managed worker id is empty",
        ));
    }
    let Some(recorded) = current_allowed_admission(transaction, intent_id).await? else {
        ensure_no_active_admission_rows(transaction, intent_id, "compensation commit").await?;
        return Ok(());
    };
    let expected_rows =
        super::ensure_recorded_reservation_is_complete(transaction, intent_id, &recorded).await?;
    let changed = query(
        "UPDATE task_board_dispatch_admission_ledger
         SET state = 'committed', managed_worker_id = ?4, expires_at = NULL,
             committed_at = ?5
         WHERE decision_id = ?1 AND intent_id = ?2 AND generation = ?3
           AND state = 'reserved' AND datetime(expires_at) > datetime('now')",
    )
    .bind(&recorded.decision_id)
    .bind(intent_id)
    .bind(recorded.generation)
    .bind(managed_worker_id)
    .bind(utc_now())
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("commit compensating task board admission: {error}")))?
    .rows_affected();
    ensure_row_count(changed, expected_rows, "commit changed")
}

pub(in crate::daemon::db::task_board) async fn finalize_compensating_dispatch_admission_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    managed_worker_id: &str,
) -> Result<(), CliError> {
    let Some(recorded) = current_allowed_admission(transaction, intent_id).await? else {
        ensure_no_active_admission_rows(transaction, intent_id, "compensation finalize").await?;
        return Ok(());
    };
    let requirements = decode_requirements(&recorded.requirements_json)?;
    let expected_concurrency = requirements
        .iter()
        .filter(|requirement| requirement.kind == TaskBoardAdmissionRequirementKind::Concurrency)
        .count();
    let released_concurrency = ensure_compensating_admission_is_complete(
        transaction,
        intent_id,
        managed_worker_id,
        &recorded,
        requirements.len(),
        expected_concurrency,
    )
    .await?;
    let remaining_concurrency = expected_concurrency
        .checked_sub(released_concurrency)
        .ok_or_else(|| db_error("task board compensation released excess concurrency rows"))?;
    let changed = query(
        "UPDATE task_board_dispatch_admission_ledger
         SET state = 'released', released_at = ?5
         WHERE decision_id = ?1 AND intent_id = ?2 AND generation = ?3
           AND managed_worker_id = ?4 AND kind = 'concurrency' AND state = 'committed'",
    )
    .bind(&recorded.decision_id)
    .bind(intent_id)
    .bind(recorded.generation)
    .bind(managed_worker_id)
    .bind(utc_now())
    .execute(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "finalize compensating task board admission: {error}"
        ))
    })?
    .rows_affected();
    ensure_row_count(changed, remaining_concurrency, "finalize released")?;
    if changed > 0 {
        bump_change_in_tx(transaction, ITEMS_CHANGE_SCOPE).await?;
    }
    Ok(())
}

async fn ensure_compensating_admission_is_complete(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    managed_worker_id: &str,
    recorded: &CurrentAllowedAdmission,
    expected_rows: usize,
    expected_concurrency: usize,
) -> Result<usize, CliError> {
    let (committed_rows, released_concurrency) = query_as::<_, (i64, i64)>(
        "SELECT
             COALESCE(SUM(CASE WHEN state = 'committed' THEN 1 ELSE 0 END), 0),
             COALESCE(SUM(CASE
                 WHEN kind = 'concurrency' AND state = 'released' THEN 1 ELSE 0 END), 0)
         FROM task_board_dispatch_admission_ledger
         WHERE decision_id = ?1 AND intent_id = ?2 AND generation = ?3
           AND managed_worker_id = ?4",
    )
    .bind(&recorded.decision_id)
    .bind(intent_id)
    .bind(recorded.generation)
    .bind(managed_worker_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load compensating task board admission: {error}")))?;
    let active_rows = active_admission_row_count(transaction, intent_id).await?;
    let accepted_rows = committed_rows.saturating_add(released_concurrency);
    if usize::try_from(accepted_rows).ok() != Some(expected_rows)
        || active_rows != committed_rows
        || usize::try_from(released_concurrency)
            .ok()
            .is_none_or(|released| released > expected_concurrency)
    {
        return Err(db_error(format!(
            "task board compensation found {committed_rows} exact committed rows, {released_concurrency} exact released concurrency rows, and {active_rows} active rows, expected {expected_rows} total rows and at most {expected_concurrency} released concurrency rows"
        )));
    }
    usize::try_from(released_concurrency)
        .map_err(|_| db_error("task board compensation released concurrency count is invalid"))
}

async fn ensure_no_active_admission_rows(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    operation: &str,
) -> Result<(), CliError> {
    let active_rows = active_admission_row_count(transaction, intent_id).await?;
    if active_rows != 0 {
        return Err(db_error(format!(
            "task board admission {operation} found {active_rows} active ledger rows without a current allowed decision"
        )));
    }
    Ok(())
}

async fn active_admission_row_count(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
) -> Result<i64, CliError> {
    query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM task_board_dispatch_admission_ledger
         WHERE intent_id = ?1 AND state IN ('reserved', 'committed')",
    )
    .bind(intent_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("count active task board admission rows: {error}")))
}

fn ensure_row_count(changed: u64, expected: usize, operation: &str) -> Result<(), CliError> {
    if usize::try_from(changed).ok() != Some(expected) {
        return Err(db_error(format!(
            "task board compensation {operation} {changed} ledger rows, expected {expected}"
        )));
    }
    Ok(())
}
