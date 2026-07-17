use sqlx::{Sqlite, Transaction, query, query_as, query_scalar};

mod compensation;
mod validation;

pub(super) use self::compensation::{
    commit_compensating_dispatch_admission_in_tx, finalize_compensating_dispatch_admission_in_tx,
};
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
use crate::task_board::{TaskBoardItem, TaskBoardLaunchCapability, validate_launch_capability};

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
    if let Some(recorded) = current_allowed_admission(transaction, intent_id).await?
        && recorded.item_revision == item_revision
        && recorded.settings_revision == settings_revision
        && stored_reservation_is_complete(transaction, intent_id, &recorded).await?
        && stored_reservation_time_is_current(transaction, intent_id, &recorded).await?
    {
        renew_recorded_dispatch_admission_in_tx(transaction, intent_id, &recorded).await?;
        return Ok(TaskBoardAdmissionCheck::Allowed(parse_launch_profile(
            recorded.launch_profile.as_deref(),
        )?));
    }
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
    if let Some(recorded) = recorded.as_ref() {
        ensure_recorded_reservation_is_complete(transaction, intent_id, recorded).await?;
    } else {
        let active_rows = active_reserved_row_count(transaction, intent_id).await?;
        if active_rows != 0 || admission_policy_is_configured_in_tx(transaction).await? {
            return Err(db_error(format!(
                "task board admission commit found {active_rows} reserved ledger rows without a current allowed decision under the configured policy"
            )));
        }
    }
    let expected_rows = current_allowed_admission(transaction, intent_id)
        .await?
        .map(|recorded| decode_requirements(&recorded.requirements_json).map(|values| values.len()))
        .transpose()?
        .unwrap_or(0);
    let worker_is_terminal =
        managed_worker_is_terminal_in_tx(transaction, managed_worker_id).await?;
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
    if usize::try_from(changed).ok() != Some(expected_rows) {
        return Err(db_error(format!(
            "task board admission commit changed {changed} ledger rows, expected {expected_rows}"
        )));
    }
    Ok(())
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
    pub(crate) async fn validate_task_board_dispatch_admission_start(
        &self,
        intent_id: &str,
        claim_token: &str,
        actual_capability: Option<TaskBoardLaunchCapability>,
    ) -> Result<(), CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board admission start validation")
            .await?;
        let (item_id, item_revision, session_id, work_item_id, execution_id) =
            claimed_item_identity(&mut transaction, intent_id, claim_token).await?;
        let (item, loaded_revision) = super::items::load_item_in_tx(&mut transaction, &item_id)
            .await?
            .ok_or_else(|| db_error(format!("task-board item '{item_id}' not found")))?;
        if loaded_revision != item_revision {
            return Err(db_error(
                "task board admission item revision changed while loading",
            ));
        }
        super::dispatch_intents::ensure_dispatch_item_startable(
            &item,
            &session_id,
            &work_item_id,
            Some(&execution_id),
        )?;
        let admission = revalidate_dispatch_admission_in_tx(
            &mut transaction,
            intent_id,
            &item,
            loaded_revision,
        )
        .await?;
        let expected = match admission {
            TaskBoardAdmissionCheck::Blocked(snapshot) => {
                let error = CliErrorKind::invalid_transition(snapshot.refusal_message()).into();
                transaction.commit().await.map_err(|error| {
                    db_error(format!(
                        "commit blocked task board admission validation: {error}"
                    ))
                })?;
                return Err(error);
            }
            admission => admission.ensure_allowed()?,
        };
        if let Some(expected) = expected {
            let actual_capability = actual_capability.ok_or_else(|| {
                CliError::from(CliErrorKind::invalid_transition(
                    "task board admission requires an enforceable launch capability".to_string(),
                ))
            })?;
            validate_launch_capability(item.agent_mode, actual_capability).map_err(|error| {
                CliError::from(CliErrorKind::invalid_transition(format!(
                    "task board launch capability refused: {error}"
                )))
            })?;
            if expected != actual_capability {
                return Err(CliErrorKind::invalid_transition(format!(
                    "task board launch capability changed from {expected:?} to {actual_capability:?}"
                ))
                .into());
            }
        }
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit task board admission validation: {error}")))
    }

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

async fn claimed_item_identity(
    transaction: &mut Transaction<'_, Sqlite>,
    intent_id: &str,
    claim_token: &str,
) -> Result<(String, i64, String, String, String), CliError> {
    let (item_id, session_id, work_item_id, execution_id) =
        query_as::<_, (String, String, String, String)>(
            "SELECT item_id, session_id, work_item_id, workflow_execution_id
         FROM task_board_dispatch_intents
         WHERE intent_id = ?1 AND claim_token = ?2 AND status = 'starting'",
        )
        .bind(intent_id)
        .bind(claim_token)
        .fetch_optional(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("load claimed task board admission intent: {error}")))?
        .ok_or_else(|| {
            db_error(format!(
                "task board dispatch intent '{intent_id}' is not claimed"
            ))
        })?;
    let item_revision =
        query_scalar::<_, i64>("SELECT revision FROM task_board_items WHERE item_id = ?1")
            .bind(&item_id)
            .fetch_one(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("load claimed task board item revision: {error}")))?;
    Ok((
        item_id,
        item_revision,
        session_id,
        work_item_id,
        execution_id,
    ))
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
