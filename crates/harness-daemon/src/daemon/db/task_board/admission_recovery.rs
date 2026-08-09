use std::collections::BTreeMap;

use sqlx::{Sqlite, Transaction, query, query_as, query_scalar};

use super::dispatch_admission_tx_ext::TaskBoardDispatchAdmissionTxExt;
use super::dispatch_intents::decode_applied;
use super::item_tx_ext::TaskBoardItemTxExt;
use crate::daemon::db::prelude::*;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error, utc_now};
use crate::task_board::{DispatchAppliedTask, TaskBoardWorkItemState};

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct TaskBoardAdmissionWorkerRecovery {
    pub(crate) managed_worker_id: String,
    pub(crate) intent_id: String,
    pub(crate) item_id: String,
    /// Legacy provenance retained until the dispatch can be rebound to its
    /// selected durable workspace.
    pub(crate) session_id: Option<String>,
    pub(crate) task_id: String,
    pub(crate) workflow_execution_id: String,
    pub(crate) dispatch: DispatchAppliedTask,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardAdmissionMissingRunRecovery {
    pub(crate) item_id: String,
    pub(crate) progress_changed: bool,
    pub(crate) concurrency_released: bool,
}

#[derive(Debug, sqlx::FromRow)]
struct AdmissionRecoveryRow {
    managed_worker_id: String,
    intent_id: String,
    item_id: String,
    session_id: Option<String>,
    workspace_id: Option<String>,
    working_copy_id: Option<String>,
    work_item_id: String,
    workflow_execution_id: String,
    payload_json: String,
    intent_status: String,
}

/// Real implementations behind the matching [`DispatchAdmissionQueries`]
/// methods, called from the single consolidated trait impl in
/// `dispatch_admission_queries.rs` (a trait's methods can only be implemented
/// in one `impl` block per type, so the per-area files hand it plain
/// functions instead of each declaring their own `impl DispatchAdmissionQueries
/// for AsyncDaemonDb`).
pub(super) async fn task_board_admission_worker_recoveries(
    db: &AsyncDaemonDb,
) -> Result<Vec<TaskBoardAdmissionWorkerRecovery>, CliError> {
    let rows = query_as::<_, AdmissionRecoveryRow>(ADMISSION_RECOVERY_SQL)
        .fetch_all(db.pool())
        .await
        .map_err(|error| {
            db_error(format!(
                "load committed task board admission workers: {error}"
            ))
        })?;
    recoveries_from_rows(rows)
}

pub(super) async fn migrate_legacy_task_board_admission_worker_owners(
    db: &AsyncDaemonDb,
) -> Result<usize, CliError> {
    let recoveries = task_board_admission_worker_recoveries(db).await?;
    let mut migrated = 0;
    for recovery in recoveries {
        if recovery.dispatch.workspace_id.is_none()
            && recovery.session_id.is_some()
            && recovery.dispatch.read_only_workflow.is_none()
            && recovery.dispatch.write_workflow.is_none()
            && migrate_one_legacy_worker_owner(db, &recovery).await?
        {
            migrated += 1;
        }
    }
    Ok(migrated)
}

async fn migrate_one_legacy_worker_owner(
    db: &AsyncDaemonDb,
    expected: &TaskBoardAdmissionWorkerRecovery,
) -> Result<bool, CliError> {
    let mut transaction = db
        .begin_immediate_transaction("legacy task board worker owner migration")
        .await?;
    let Some(current) =
        load_worker_recovery_in_tx(&mut transaction, &expected.managed_worker_id).await?
    else {
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit empty legacy worker owner migration: {error}"
            ))
        })?;
        return Ok(false);
    };
    if current != *expected {
        return Err(db_error(format!(
            "managed worker '{}' changed dispatch identity during owner migration",
            expected.managed_worker_id
        )));
    }
    let Some(workspace_id) = selected_workspace_for_session_in_tx(
        &mut transaction,
        expected
            .session_id
            .as_deref()
            .expect("screened legacy owner"),
    )
    .await?
    else {
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit unmigrated legacy worker owner: {error}")))?;
        return Ok(false);
    };
    persist_migrated_worker_owner_in_tx(&mut transaction, current, &workspace_id).await?;
    transaction.commit().await.map_err(|error| {
        db_error(format!(
            "commit legacy task board worker owner migration: {error}"
        ))
    })?;
    Ok(true)
}

async fn selected_workspace_for_session_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    session_id: &str,
) -> Result<Option<String>, CliError> {
    let workspaces = query_scalar::<_, String>(
        "SELECT workspace_id FROM agent_workspace_legacy_sessions
         WHERE session_id = ?1 AND is_selected = 1
         ORDER BY workspace_id LIMIT 2",
    )
    .bind(session_id)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("resolve legacy worker workspace owner: {error}")))?;
    match workspaces.as_slice() {
        [] => Ok(None),
        [workspace_id] => Ok(Some(workspace_id.clone())),
        _ => Err(db_error(format!(
            "legacy Session '{session_id}' is selected by multiple workspaces"
        ))),
    }
}

async fn persist_migrated_worker_owner_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    recovery: TaskBoardAdmissionWorkerRecovery,
    workspace_id: &str,
) -> Result<(), CliError> {
    let now = utc_now();
    migrate_current_item_owner_in_tx(transaction, &recovery, workspace_id, &now).await?;
    let mut dispatch = recovery.dispatch;
    dispatch.workspace_id = Some(workspace_id.to_string());
    dispatch.item.workspace_id = Some(workspace_id.to_string());
    let payload_json = serde_json::to_string(&dispatch)
        .map_err(|error| db_error(format!("serialize migrated worker dispatch: {error}")))?;
    let updated = query(
        "UPDATE task_board_dispatch_intents
         SET workspace_id = ?2, payload_json = ?3, updated_at = ?4
         WHERE intent_id = ?1 AND workspace_id IS NULL",
    )
    .bind(&recovery.intent_id)
    .bind(workspace_id)
    .bind(payload_json)
    .bind(&now)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("persist migrated worker dispatch owner: {error}")))?
    .rows_affected();
    if updated != 1 {
        return Err(db_error(format!(
            "task board dispatch '{}' changed owner during migration",
            recovery.intent_id
        )));
    }
    Ok(())
}

async fn migrate_current_item_owner_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    recovery: &TaskBoardAdmissionWorkerRecovery,
    workspace_id: &str,
    now: &str,
) -> Result<(), CliError> {
    let Some((mut item, revision)) = transaction.load_item_in_tx(&recovery.item_id).await? else {
        return Ok(());
    };
    if item.is_deleted()
        || item.session_id != recovery.session_id
        || item.work_item_id.as_deref() != Some(recovery.task_id.as_str())
        || item.workflow.execution_id.as_deref() != Some(recovery.workflow_execution_id.as_str())
    {
        return Ok(());
    }
    if item
        .workspace_id
        .as_deref()
        .is_some_and(|owner| owner != workspace_id)
    {
        return Err(db_error(format!(
            "task board item '{}' already belongs to another workspace",
            recovery.item_id
        )));
    }
    let next_revision = revision.checked_add(1).ok_or_else(|| {
        db_error(format!(
            "task board item '{}' exhausted its revision during owner migration",
            recovery.item_id
        ))
    })?;
    item.workspace_id = Some(workspace_id.to_string());
    item.updated_at = now.to_string();
    transaction.replace_item_in_tx(&item, next_revision).await?;
    super::items::bump_change_in_tx(transaction, super::ITEMS_CHANGE_SCOPE)
        .await
        .map(|_| ())
}

pub(super) async fn reconcile_missing_task_board_admission_worker(
    db: &AsyncDaemonDb,
    expected: &TaskBoardAdmissionWorkerRecovery,
    reason: &str,
) -> Result<Option<TaskBoardAdmissionMissingRunRecovery>, CliError> {
    let mut transaction = db
        .begin_immediate_transaction("missing task board admission worker recovery")
        .await?;
    if !screen_missing_worker_recovery_in_tx(&mut transaction, expected).await? {
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit no-op task board admission worker recovery: {error}"
            ))
        })?;
        return Ok(None);
    }

    let report = super::work_item_progress_queries::TaskBoardRuntimeTerminalReport {
        state: TaskBoardWorkItemState::Blocked,
        summary: None,
        blocked_reason: Some(reason.to_string()),
    };
    let progress_changed =
        super::work_item_progress_terminal::project_exact_runtime_terminal_in_tx(
            &mut transaction,
            &expected.item_id,
            &expected.task_id,
            &expected.managed_worker_id,
            &report,
        )
        .await?;
    let concurrency_released = transaction
        .release_managed_worker_admission_in_tx(&expected.managed_worker_id)
        .await?;
    transaction.commit().await.map_err(|error| {
        db_error(format!(
            "commit missing task board admission worker recovery: {error}"
        ))
    })?;
    Ok(Some(TaskBoardAdmissionMissingRunRecovery {
        item_id: expected.item_id.clone(),
        progress_changed,
        concurrency_released,
    }))
}

const ADMISSION_RECOVERY_SQL: &str =
    "SELECT DISTINCT ledger.managed_worker_id, intent.intent_id, intent.item_id,
        intent.session_id, intent.workspace_id, intent.working_copy_id,
        intent.work_item_id, intent.workflow_execution_id,
        intent.payload_json, intent.status AS intent_status
     FROM task_board_dispatch_admission_ledger AS ledger
     JOIN task_board_dispatch_intents AS intent ON intent.intent_id = ledger.intent_id
     WHERE ledger.kind = 'concurrency'
       AND ledger.managed_worker_id IS NOT NULL
       AND NOT (intent.status = 'starting' AND intent.compensation_pending = 1)
       AND (
           ledger.state = 'committed'
           OR (ledger.state = 'released' AND EXISTS (
               SELECT 1 FROM task_board_work_item_progress AS progress
               WHERE progress.item_id = intent.item_id
                 AND progress.work_item_id = intent.work_item_id
                 AND progress.attempt_id = ledger.managed_worker_id
                 AND progress.completed_at IS NULL
                 AND progress.state IN ('pending', 'running')
                 AND (
                     (
                         NOT EXISTS (
                             SELECT 1 FROM codex_runs AS run
                             WHERE run.run_id = ledger.managed_worker_id
                         )
                         AND NOT EXISTS (
                             SELECT 1 FROM agent_tuis AS tui
                             WHERE tui.tui_id = ledger.managed_worker_id
                         )
                     )
                     OR EXISTS (
                         SELECT 1 FROM codex_runs AS run
                         WHERE run.run_id = ledger.managed_worker_id
                           AND run.status IN ('completed', 'failed', 'cancelled')
                     )
                     OR EXISTS (
                         SELECT 1 FROM agent_tuis AS tui
                         WHERE tui.tui_id = ledger.managed_worker_id
                           AND tui.status IN ('exited', 'failed', 'stopped')
                     )
                 )
           ))
       )
     ORDER BY ledger.managed_worker_id, intent.intent_id";

const ADMISSION_RECOVERY_FOR_WORKER_SQL: &str =
    "SELECT DISTINCT ledger.managed_worker_id, intent.intent_id, intent.item_id,
        intent.session_id, intent.workspace_id, intent.working_copy_id,
        intent.work_item_id, intent.workflow_execution_id,
        intent.payload_json, intent.status AS intent_status
     FROM task_board_dispatch_admission_ledger AS ledger
     JOIN task_board_dispatch_intents AS intent ON intent.intent_id = ledger.intent_id
     WHERE ledger.kind = 'concurrency'
       AND ledger.managed_worker_id = ?1
       AND NOT (intent.status = 'starting' AND intent.compensation_pending = 1)
       AND (
           ledger.state = 'committed'
           OR (ledger.state = 'released' AND EXISTS (
               SELECT 1 FROM task_board_work_item_progress AS progress
               WHERE progress.item_id = intent.item_id
                 AND progress.work_item_id = intent.work_item_id
                 AND progress.attempt_id = ledger.managed_worker_id
                 AND progress.completed_at IS NULL
                 AND progress.state IN ('pending', 'running')
                 AND (
                     (
                         NOT EXISTS (
                             SELECT 1 FROM codex_runs AS run
                             WHERE run.run_id = ledger.managed_worker_id
                         )
                         AND NOT EXISTS (
                             SELECT 1 FROM agent_tuis AS tui
                             WHERE tui.tui_id = ledger.managed_worker_id
                         )
                     )
                     OR EXISTS (
                         SELECT 1 FROM codex_runs AS run
                         WHERE run.run_id = ledger.managed_worker_id
                           AND run.status IN ('completed', 'failed', 'cancelled')
                     )
                     OR EXISTS (
                         SELECT 1 FROM agent_tuis AS tui
                         WHERE tui.tui_id = ledger.managed_worker_id
                           AND tui.status IN ('exited', 'failed', 'stopped')
                     )
                 )
           ))
       )
     ORDER BY ledger.managed_worker_id, intent.intent_id";

fn recoveries_from_rows(
    rows: Vec<AdmissionRecoveryRow>,
) -> Result<Vec<TaskBoardAdmissionWorkerRecovery>, CliError> {
    let mut recoveries = BTreeMap::new();
    for row in rows {
        let recovery = recovery_from_row(row)?;
        if let Some(existing) = recoveries.get(&recovery.managed_worker_id) {
            if existing != &recovery {
                return Err(db_error(format!(
                    "managed worker '{}' has committed admission for multiple dispatches",
                    recovery.managed_worker_id
                )));
            }
        } else {
            recoveries.insert(recovery.managed_worker_id.clone(), recovery);
        }
    }
    Ok(recoveries.into_values().collect())
}

fn recovery_from_row(
    row: AdmissionRecoveryRow,
) -> Result<TaskBoardAdmissionWorkerRecovery, CliError> {
    if row.intent_status != "completed" {
        return Err(db_error(format!(
            "managed worker '{}' has committed admission for non-completed intent '{}'",
            row.managed_worker_id, row.intent_id
        )));
    }
    let dispatch = decode_applied(&row.payload_json)?;
    let matches = dispatch.board_item_id == row.item_id
        && dispatch.session_id == row.session_id
        && dispatch.workspace_id == row.workspace_id
        && dispatch.working_copy_id == row.working_copy_id
        && dispatch.work_item_id == row.work_item_id
        && dispatch.item.id == row.item_id
        && dispatch.item.session_id == row.session_id
        && dispatch.item.workspace_id == row.workspace_id
        && dispatch.item.working_copy_id == row.working_copy_id
        && dispatch.item.work_item_id.as_deref() == Some(row.work_item_id.as_str())
        && dispatch.item.workflow.execution_id.as_deref()
            == Some(row.workflow_execution_id.as_str());
    if !matches {
        return Err(db_error(format!(
            "task board admission intent '{}' has inconsistent dispatch recovery identity",
            row.intent_id
        )));
    }
    Ok(TaskBoardAdmissionWorkerRecovery {
        managed_worker_id: row.managed_worker_id,
        intent_id: row.intent_id,
        item_id: row.item_id,
        session_id: row.session_id,
        task_id: row.work_item_id,
        workflow_execution_id: row.workflow_execution_id,
        dispatch,
    })
}

async fn load_worker_recovery_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    managed_worker_id: &str,
) -> Result<Option<TaskBoardAdmissionWorkerRecovery>, CliError> {
    let rows = query_as::<_, AdmissionRecoveryRow>(ADMISSION_RECOVERY_FOR_WORKER_SQL)
        .bind(managed_worker_id)
        .fetch_all(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("reload task board admission worker: {error}")))?;
    let mut recoveries = recoveries_from_rows(rows)?;
    match recoveries.len() {
        0 => Ok(None),
        1 => Ok(recoveries.pop()),
        _ => Err(db_error(format!(
            "managed worker '{managed_worker_id}' resolved to multiple recovery records"
        ))),
    }
}

/// Whether the worker recovery still applies: `false` means the caller has
/// nothing left to reconcile and should commit the read-only screen as-is.
async fn screen_missing_worker_recovery_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    expected: &TaskBoardAdmissionWorkerRecovery,
) -> Result<bool, CliError> {
    let Some(current) =
        load_worker_recovery_in_tx(transaction, &expected.managed_worker_id).await?
    else {
        return Ok(false);
    };
    if current != *expected {
        return Err(db_error(format!(
            "task board admission worker '{}' changed dispatch identity during recovery",
            expected.managed_worker_id
        )));
    }
    if managed_worker_exists_in_tx(transaction, &expected.managed_worker_id).await? {
        return Ok(false);
    }
    Ok(true)
}

async fn managed_worker_exists_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    managed_worker_id: &str,
) -> Result<bool, CliError> {
    query_scalar::<_, bool>(
        "SELECT EXISTS(
            SELECT 1 FROM codex_runs WHERE run_id = ?1
            UNION ALL
            SELECT 1 FROM agent_tuis WHERE tui_id = ?1
         )",
    )
    .bind(managed_worker_id)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "check durable managed worker during recovery: {error}"
        ))
    })
}
