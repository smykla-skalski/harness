use sqlx::{Sqlite, Transaction, query, query_as, query_scalar};

use super::admission_lifecycle::{
    commit_dispatch_admission_in_tx, renew_frozen_dispatch_admission_in_tx,
};
use crate::daemon::db::{CliError, db_error};

pub(super) async fn frozen_unconfigured_start_admission_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
) -> Result<bool, CliError> {
    let (outcome, revision) = start_admission_row(transaction, intent_id).await?;
    match (outcome.as_deref(), revision) {
        (None, None) => Ok(false),
        (Some("unconfigured"), Some(revision)) if revision > 0 => {
            ensure_unconfigured_evidence_is_exclusive(transaction, intent_id).await?;
            Ok(true)
        }
        _ => Err(db_error(
            "workflow start admission authorization is malformed",
        )),
    }
}

pub(super) async fn freeze_unconfigured_start_admission_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
) -> Result<(), CliError> {
    if frozen_unconfigured_start_admission_in_tx(transaction, intent_id).await? {
        return Ok(());
    }
    let settings_revision = query_scalar::<_, i64>(
        "SELECT revision FROM task_board_orchestrator_settings WHERE singleton = 1",
    )
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load workflow start admission revision: {error}")))?;
    let changed = query(
        "UPDATE task_board_dispatch_intents
         SET start_admission_outcome = 'unconfigured',
             start_admission_settings_revision = ?2
         WHERE intent_id = ?1 AND status = 'workflow_prepared'
           AND start_admission_outcome IS NULL
           AND start_admission_settings_revision IS NULL",
    )
    .bind(intent_id)
    .bind(settings_revision)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("freeze unconfigured start admission: {error}")))?
    .rows_affected();
    if changed != 1 {
        return Err(db_error(
            "workflow start admission changed before it could be frozen",
        ));
    }
    ensure_unconfigured_evidence_is_exclusive(transaction, intent_id).await
}

pub(super) async fn commit_frozen_start_admission_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    managed_worker_id: &str,
) -> Result<(), CliError> {
    if frozen_unconfigured_start_admission_in_tx(transaction, intent_id).await? {
        return Ok(());
    }
    let allowed = query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM task_board_dispatch_admission_decisions
         WHERE intent_id = ?1 AND decision = 'allowed' AND is_current = 1",
    )
    .bind(intent_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load frozen workflow start admission: {error}")))?;
    if allowed != 1 {
        return Err(db_error(
            "workflow start has no exact frozen admission authorization",
        ));
    }
    renew_frozen_dispatch_admission_in_tx(transaction, intent_id).await?;
    commit_dispatch_admission_in_tx(transaction, intent_id, managed_worker_id).await
}

async fn start_admission_row(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
) -> Result<(Option<String>, Option<i64>), CliError> {
    query_as(
        "SELECT start_admission_outcome, start_admission_settings_revision
         FROM task_board_dispatch_intents
         WHERE intent_id = ?1 AND status = 'workflow_prepared'",
    )
    .bind(intent_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load workflow start admission: {error}")))?
    .ok_or_else(|| db_error("workflow prepared dispatch intent disappeared"))
}

async fn ensure_unconfigured_evidence_is_exclusive(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
) -> Result<(), CliError> {
    let conflicts = query_scalar::<_, i64>(
        "SELECT
             (SELECT COUNT(*) FROM task_board_dispatch_admission_decisions
              WHERE intent_id = ?1 AND decision = 'allowed' AND is_current = 1)
           + (SELECT COUNT(*) FROM task_board_dispatch_admission_ledger
              WHERE intent_id = ?1 AND state != 'released')",
    )
    .bind(intent_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("validate unconfigured start admission: {error}")))?;
    if conflicts == 0 {
        Ok(())
    } else {
        Err(db_error(
            "unconfigured workflow start admission conflicts with durable policy evidence",
        ))
    }
}
