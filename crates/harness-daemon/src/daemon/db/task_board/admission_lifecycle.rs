use sqlx::{Sqlite, Transaction, query, query_scalar};

mod compensation;
mod start;
mod validation;

pub(super) use self::compensation::{
    commit_compensating_dispatch_admission_in_tx, finalize_compensating_dispatch_admission_in_tx,
};
pub(super) use self::validation::validate_worker_start_fence_in_tx;
use self::validation::{
    CurrentAllowedAdmission, admission_policy_is_configured_in_tx, current_allowed_admission,
    current_settings_revision, decode_requirements, intent_item_in_tx,
    stored_reservation_is_complete, stored_reservation_time_is_current,
};
use super::ITEMS_CHANGE_SCOPE;
use super::admission::{TaskBoardDispatchAdmissionSnapshot, evaluate_dispatch_admission_in_tx};
use super::admission_reservations::{
    clear_current_admission_in_tx, persist_admission_snapshot_in_tx,
};
use super::items::bump_change_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, CliErrorKind, db_error, utc_now};
use crate::task_board::{TaskBoardItem, TaskBoardLaunchCapability};

#[derive(Debug)]
pub(super) enum TaskBoardAdmissionCheck {
    Unconfigured,
    Allowed(TaskBoardLaunchCapability),
    Blocked(Box<TaskBoardDispatchAdmissionSnapshot>),
}

impl TaskBoardAdmissionCheck {
    pub(super) fn ensure_allowed(self) -> Result<Option<TaskBoardLaunchCapability>, CliError> {
        match self {
            Self::Unconfigured => Ok(None),
            Self::Allowed(capability) => Ok(Some(capability)),
            Self::Blocked(snapshot) => {
                Err(CliErrorKind::invalid_transition(snapshot.refusal_message()).into())
            }
        }
    }
}

pub(super) async fn revalidate_dispatch_admission_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    item: &TaskBoardItem,
    item_revision: i64,
) -> Result<TaskBoardAdmissionCheck, CliError> {
    let settings_revision = current_settings_revision(transaction).await?;
    if let Some(reused) =
        try_reuse_recorded_admission_in_tx(transaction, intent_id, item_revision, settings_revision)
            .await?
    {
        return Ok(reused);
    }
    evaluate_and_record_dispatch_admission_in_tx(transaction, item, item_revision, intent_id).await
}

async fn try_reuse_recorded_admission_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    item_revision: i64,
    settings_revision: i64,
) -> Result<Option<TaskBoardAdmissionCheck>, CliError> {
    let Some(recorded) = current_allowed_admission(transaction, intent_id).await? else {
        return Ok(None);
    };
    if recorded.item_revision != item_revision
        || recorded.settings_revision != settings_revision
        || !stored_reservation_is_complete(transaction, intent_id, &recorded).await?
        || !stored_reservation_time_is_current(transaction, intent_id, &recorded).await?
    {
        return Ok(None);
    }
    renew_recorded_dispatch_admission_in_tx(transaction, intent_id, &recorded).await?;
    Ok(Some(TaskBoardAdmissionCheck::Allowed(
        parse_launch_profile(recorded.launch_profile.as_deref())?,
    )))
}

async fn evaluate_and_record_dispatch_admission_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item: &TaskBoardItem,
    item_revision: i64,
    intent_id: &str,
) -> Result<TaskBoardAdmissionCheck, CliError> {
    let candidate =
        evaluate_dispatch_admission_in_tx(transaction, item, item_revision, Some(intent_id))
            .await?;
    let Some(mut candidate) = candidate else {
        clear_current_admission_in_tx(transaction, &item.id, Some(intent_id)).await?;
        return Ok(TaskBoardAdmissionCheck::Unconfigured);
    };
    if candidate.is_allowed() {
        persist_admission_snapshot_in_tx(transaction, &item.id, Some(intent_id), &mut candidate)
            .await?;
        let capability = candidate
            .launch_capability
            .ok_or_else(|| db_error("allowed task board admission has no launch capability"))?;
        return Ok(TaskBoardAdmissionCheck::Allowed(capability));
    }
    clear_current_admission_in_tx(transaction, &item.id, Some(intent_id)).await?;
    persist_admission_snapshot_in_tx(transaction, &item.id, None, &mut candidate).await?;
    Ok(TaskBoardAdmissionCheck::Blocked(Box::new(candidate)))
}

pub(super) async fn renew_dispatch_admission_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
) -> Result<(), CliError> {
    let Some(recorded) = current_allowed_admission(transaction, intent_id).await? else {
        let active_rows = active_reserved_row_count(transaction, intent_id).await?;
        if active_rows == 0 && !admission_policy_is_configured_in_tx(transaction).await? {
            return Ok(());
        }
        return Err(db_error(format!(
            "task board admission renewal found {active_rows} reserved ledger rows without a current allowed decision under the configured policy"
        )));
    };
    ensure_recorded_reservation_is_complete(transaction, intent_id, &recorded).await?;
    let (item, item_revision) = intent_item_in_tx(transaction, intent_id).await?;
    revalidate_dispatch_admission_in_tx(transaction, intent_id, &item, item_revision)
        .await?
        .ensure_allowed()?;
    Ok(())
}

pub(super) async fn renew_frozen_dispatch_admission_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
) -> Result<(), CliError> {
    // The worker claim spans the external launch boundary. Extend only the
    // exact generation authorized at that boundary; preparation owns revalidation.
    let Some(recorded) = current_allowed_admission(transaction, intent_id).await? else {
        let active_rows = active_reserved_row_count(transaction, intent_id).await?;
        if active_rows == 0 {
            return Ok(());
        }
        return Err(db_error(format!(
            "task board frozen admission renewal found {active_rows} reserved ledger rows without a current allowed decision"
        )));
    };
    restore_recorded_dispatch_admission_in_tx(transaction, intent_id, &recorded).await?;
    renew_recorded_dispatch_admission_in_tx(transaction, intent_id, &recorded).await
}

async fn restore_recorded_dispatch_admission_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    recorded: &CurrentAllowedAdmission,
) -> Result<(), CliError> {
    // A durable `starting` claim can outlive the reservation horizon while its
    // deterministic worker keeps running. Restore only that claim's exact
    // frozen generation; current policy must not erase truthful start evidence.
    query(
        "UPDATE task_board_dispatch_admission_ledger
         SET state = 'reserved',
             expires_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '+900 seconds'),
             released_at = NULL
         WHERE decision_id = ?1 AND intent_id = ?2 AND generation = ?3
           AND committed_at IS NULL AND managed_worker_id IS NULL
           AND (
               state = 'released'
               OR (state = 'reserved' AND datetime(expires_at) <= datetime('now'))
           )",
    )
    .bind(&recorded.decision_id)
    .bind(intent_id)
    .bind(recorded.generation)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("restore frozen task board admission: {error}")))?;
    Ok(())
}

async fn renew_recorded_dispatch_admission_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    recorded: &CurrentAllowedAdmission,
) -> Result<(), CliError> {
    let expected_rows =
        ensure_recorded_reservation_is_complete(transaction, intent_id, recorded).await?;
    let changed = query(
        "UPDATE task_board_dispatch_admission_ledger
         SET expires_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '+900 seconds')
         WHERE decision_id = ?1 AND intent_id = ?2 AND generation = ?3
           AND state = 'reserved' AND datetime(expires_at) > datetime('now')",
    )
    .bind(&recorded.decision_id)
    .bind(intent_id)
    .bind(recorded.generation)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("renew task board admission reservation: {error}")))?
    .rows_affected();
    if usize::try_from(changed).ok() != Some(expected_rows) {
        return Err(db_error(format!(
            "task board admission renewal changed {changed} ledger rows, expected {expected_rows}"
        )));
    }
    Ok(())
}

async fn ensure_recorded_reservation_is_complete(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    recorded: &CurrentAllowedAdmission,
) -> Result<usize, CliError> {
    let expected_rows = decode_requirements(&recorded.requirements_json)?.len();
    let active_rows = active_reserved_row_count(transaction, intent_id).await?;
    if usize::try_from(active_rows).ok() != Some(expected_rows)
        || !stored_reservation_is_complete(transaction, intent_id, recorded).await?
    {
        return Err(db_error(format!(
            "task board admission renewal found {active_rows} valid reserved ledger rows, expected {expected_rows}"
        )));
    }
    Ok(expected_rows)
}

pub(super) async fn commit_dispatch_admission_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    managed_worker_id: &str,
) -> Result<(), CliError> {
    let recorded = current_allowed_admission(transaction, intent_id).await?;
    ensure_admission_committable_in_tx(transaction, intent_id, recorded.as_ref()).await?;
    let expected_rows = recorded
        .map(|recorded| decode_requirements(&recorded.requirements_json).map(|values| values.len()))
        .transpose()?
        .unwrap_or(0);
    let worker_is_terminal =
        managed_worker_is_terminal_in_tx(transaction, managed_worker_id).await?;
    let changed = write_dispatch_admission_commit_in_tx(
        transaction,
        intent_id,
        managed_worker_id,
        worker_is_terminal,
    )
    .await?;
    if usize::try_from(changed).ok() != Some(expected_rows) {
        return Err(db_error(format!(
            "task board admission commit changed {changed} ledger rows, expected {expected_rows}"
        )));
    }
    Ok(())
}

async fn ensure_admission_committable_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    recorded: Option<&CurrentAllowedAdmission>,
) -> Result<(), CliError> {
    let Some(recorded) = recorded else {
        let active_rows = active_reserved_row_count(transaction, intent_id).await?;
        if active_rows != 0 || admission_policy_is_configured_in_tx(transaction).await? {
            return Err(db_error(format!(
                "task board admission commit found {active_rows} reserved ledger rows without a current allowed decision under the configured policy"
            )));
        }
        return Ok(());
    };
    ensure_recorded_reservation_is_complete(transaction, intent_id, recorded).await?;
    Ok(())
}

async fn write_dispatch_admission_commit_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    managed_worker_id: &str,
    worker_is_terminal: bool,
) -> Result<u64, CliError> {
    let now = utc_now();
    let changed = query(
        "UPDATE task_board_dispatch_admission_ledger
         SET state = CASE
                 WHEN kind = 'concurrency' AND ?3 = 1 THEN 'released'
                 ELSE 'committed'
             END,
             managed_worker_id = ?2, expires_at = NULL, committed_at = ?4,
             released_at = CASE
                 WHEN kind = 'concurrency' AND ?3 = 1 THEN ?4
                 ELSE NULL
             END
         WHERE intent_id = ?1 AND state = 'reserved'",
    )
    .bind(intent_id)
    .bind(managed_worker_id)
    .bind(worker_is_terminal)
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("commit task board admission ledger: {error}")))?
    .rows_affected();
    Ok(changed)
}

async fn managed_worker_is_terminal_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    managed_worker_id: &str,
) -> Result<bool, CliError> {
    let status = query_scalar::<_, String>("SELECT status FROM codex_runs WHERE run_id = ?1")
        .bind(managed_worker_id)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load managed worker status: {error}")))?;
    Ok(
        status
            .is_some_and(|status| matches!(status.as_str(), "completed" | "failed" | "cancelled")),
    )
}

pub(super) async fn release_dispatch_admission_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
) -> Result<(), CliError> {
    let now = utc_now();
    query(
        "UPDATE task_board_dispatch_admission_ledger
         SET state = 'released', expires_at = NULL, released_at = ?2
         WHERE intent_id = ?1 AND state = 'reserved'",
    )
    .bind(intent_id)
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("release task board admission ledger: {error}")))?;
    Ok(())
}

pub(super) async fn release_item_admission_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
) -> Result<(), CliError> {
    let now = utc_now();
    query(
        "UPDATE task_board_dispatch_admission_ledger
         SET state = 'released', expires_at = NULL, released_at = ?2
         WHERE item_id = ?1
           AND (state = 'reserved' OR (kind = 'concurrency' AND state = 'committed'))",
    )
    .bind(item_id)
    .bind(now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("release task board item admission: {error}")))?;
    Ok(())
}

pub(super) async fn ensure_item_admission_can_terminate_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    item_id: &str,
) -> Result<(), CliError> {
    let active = query_scalar::<_, bool>(
        "SELECT EXISTS(
             SELECT 1 FROM task_board_dispatch_admission_ledger
             WHERE item_id = ?1 AND kind = 'concurrency' AND state = 'committed'
         )",
    )
    .bind(item_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("check active task board admission: {error}")))?;
    if active {
        return Err(CliErrorKind::invalid_transition(format!(
            "task-board item '{item_id}' cannot become terminal while its managed worker is active"
        ))
        .into());
    }
    Ok(())
}

pub(in crate::daemon::db) async fn release_managed_worker_admission_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    managed_worker_id: &str,
) -> Result<bool, CliError> {
    let changed = query(
        "UPDATE task_board_dispatch_admission_ledger
         SET state = 'released', released_at = ?2
         WHERE managed_worker_id = ?1 AND kind = 'concurrency'
           AND state = 'committed'",
    )
    .bind(managed_worker_id)
    .bind(utc_now())
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("release managed worker admission: {error}")))?
    .rows_affected();
    if changed > 0 {
        bump_change_in_tx(transaction, ITEMS_CHANGE_SCOPE).await?;
    }
    Ok(changed > 0)
}

impl AsyncDaemonDb {
    pub(crate) async fn release_task_board_admission_for_managed_worker(
        &self,
        managed_worker_id: &str,
    ) -> Result<bool, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("managed worker admission release")
            .await?;
        let changed =
            release_managed_worker_admission_in_tx(&mut transaction, managed_worker_id).await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit managed worker admission release: {error}"))
        })?;
        Ok(changed)
    }
}

async fn active_reserved_row_count(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
) -> Result<i64, CliError> {
    query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM task_board_dispatch_admission_ledger
         WHERE intent_id = ?1 AND state = 'reserved'
           AND datetime(expires_at) > datetime('now')",
    )
    .bind(intent_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("count task board admission reservations: {error}")))
}

fn parse_launch_profile(value: Option<&str>) -> Result<TaskBoardLaunchCapability, CliError> {
    match value {
        Some("read_only") => Ok(TaskBoardLaunchCapability::ReportReadOnly),
        Some("workspace_write") => Ok(TaskBoardLaunchCapability::WorkspaceWrite),
        Some(other) => Err(db_error(format!(
            "unknown task board admission launch profile '{other}'"
        ))),
        None => Err(db_error(
            "allowed task board admission has no launch capability",
        )),
    }
}
