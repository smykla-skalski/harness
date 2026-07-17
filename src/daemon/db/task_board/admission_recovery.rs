use std::collections::BTreeMap;

use sqlx::{Sqlite, Transaction, query_as, query_scalar};

use super::admission_lifecycle::release_managed_worker_admission_in_tx;
use super::dispatch_intents::decode_applied;
use super::items::load_item_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, SessionState, db_error, utc_now};
use crate::session::service as session_service;
use crate::session::types::{CONTROL_PLANE_ACTOR_ID, ManagedAgentRef, TaskStatus};
use crate::task_board::{DispatchAppliedTask, TaskBoardItem, TaskBoardWorkflowStatus};

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct TaskBoardAdmissionWorkerRecovery {
    pub(crate) managed_worker_id: String,
    pub(crate) intent_id: String,
    pub(crate) item_id: String,
    pub(crate) session_id: String,
    pub(crate) task_id: String,
    pub(crate) workflow_execution_id: String,
    pub(crate) dispatch: DispatchAppliedTask,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardAdmissionMissingRunRecovery {
    pub(crate) item_id: String,
    pub(crate) session_id: String,
    pub(crate) session_changed: bool,
    pub(crate) concurrency_released: bool,
}

#[derive(Debug, sqlx::FromRow)]
struct AdmissionRecoveryRow {
    managed_worker_id: String,
    intent_id: String,
    item_id: String,
    session_id: String,
    work_item_id: String,
    workflow_execution_id: String,
    payload_json: String,
    intent_status: String,
}

#[derive(sqlx::FromRow)]
struct AdmissionRecoverySessionRow {
    state_json: String,
    project_id: String,
}

impl AsyncDaemonDb {
    pub(crate) async fn task_board_admission_worker_recoveries(
        &self,
    ) -> Result<Vec<TaskBoardAdmissionWorkerRecovery>, CliError> {
        let rows = query_as::<_, AdmissionRecoveryRow>(ADMISSION_RECOVERY_SQL)
            .fetch_all(self.pool())
            .await
            .map_err(|error| {
                db_error(format!(
                    "load committed task board admission workers: {error}"
                ))
            })?;
        recoveries_from_rows(rows)
    }

    pub(crate) async fn reconcile_missing_task_board_admission_worker(
        &self,
        expected: &TaskBoardAdmissionWorkerRecovery,
        reason: &str,
    ) -> Result<Option<TaskBoardAdmissionMissingRunRecovery>, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("missing task board admission worker recovery")
            .await?;
        let current =
            load_worker_recovery_in_tx(&mut transaction, &expected.managed_worker_id).await?;
        let Some(current) = current else {
            transaction.commit().await.map_err(|error| {
                db_error(format!(
                    "commit absent task board admission worker recovery: {error}"
                ))
            })?;
            return Ok(None);
        };
        if current != *expected {
            return Err(db_error(format!(
                "task board admission worker '{}' changed dispatch identity during recovery",
                expected.managed_worker_id
            )));
        }
        if codex_run_exists_in_tx(&mut transaction, &expected.managed_worker_id).await? {
            transaction.commit().await.map_err(|error| {
                db_error(format!(
                    "commit raced task board admission worker recovery: {error}"
                ))
            })?;
            return Ok(None);
        }

        let concurrency_released =
            release_managed_worker_admission_in_tx(&mut transaction, &expected.managed_worker_id)
                .await?;
        let session_changed = block_linked_session_task(&mut transaction, expected, reason).await?;
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit missing task board admission worker recovery: {error}"
            ))
        })?;
        Ok(Some(TaskBoardAdmissionMissingRunRecovery {
            item_id: expected.item_id.clone(),
            session_id: expected.session_id.clone(),
            session_changed,
            concurrency_released,
        }))
    }
}

const ADMISSION_RECOVERY_SQL: &str =
    "SELECT DISTINCT ledger.managed_worker_id, intent.intent_id, intent.item_id,
        intent.session_id, intent.work_item_id, intent.workflow_execution_id,
        intent.payload_json, intent.status AS intent_status
     FROM task_board_dispatch_admission_ledger AS ledger
     JOIN task_board_dispatch_intents AS intent ON intent.intent_id = ledger.intent_id
     WHERE ledger.state = 'committed' AND ledger.managed_worker_id IS NOT NULL
     ORDER BY ledger.managed_worker_id, intent.intent_id";

const ADMISSION_RECOVERY_FOR_WORKER_SQL: &str =
    "SELECT DISTINCT ledger.managed_worker_id, intent.intent_id, intent.item_id,
        intent.session_id, intent.work_item_id, intent.workflow_execution_id,
        intent.payload_json, intent.status AS intent_status
     FROM task_board_dispatch_admission_ledger AS ledger
     JOIN task_board_dispatch_intents AS intent ON intent.intent_id = ledger.intent_id
     WHERE ledger.state = 'committed' AND ledger.managed_worker_id = ?1
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
        && dispatch.work_item_id == row.work_item_id
        && dispatch.item.id == row.item_id
        && dispatch.item.session_id.as_deref() == Some(row.session_id.as_str())
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

async fn codex_run_exists_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    managed_worker_id: &str,
) -> Result<bool, CliError> {
    query_scalar::<_, bool>("SELECT EXISTS(SELECT 1 FROM codex_runs WHERE run_id = ?1)")
        .bind(managed_worker_id)
        .fetch_one(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("check durable Codex run during recovery: {error}")))
}

async fn block_linked_session_task(
    transaction: &mut Transaction<'_, Sqlite>,
    recovery: &TaskBoardAdmissionWorkerRecovery,
    reason: &str,
) -> Result<bool, CliError> {
    let item_is_linked = load_item_in_tx(transaction, &recovery.item_id)
        .await?
        .is_some_and(|(item, _)| item_matches_recovery(&item, recovery));
    if !item_is_linked {
        return Ok(false);
    }
    let Some(row) = query_as::<_, AdmissionRecoverySessionRow>(
        "SELECT state_json, project_id FROM sessions WHERE session_id = ?1",
    )
    .bind(&recovery.session_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load linked recovery session: {error}")))?
    else {
        return Ok(false);
    };
    let mut state: SessionState = serde_json::from_str(&row.state_json)
        .map_err(|error| db_error(format!("decode linked recovery session: {error}")))?;
    if !session_task_matches_recovery(&state, recovery) {
        return Ok(false);
    }
    session_service::apply_update_task_for_managed_run(
        &mut state,
        &recovery.task_id,
        TaskStatus::Blocked,
        Some(reason),
        CONTROL_PLANE_ACTOR_ID,
        &utc_now(),
    )?;
    super::super::async_writes::sync_session_in_transaction(transaction, &row.project_id, &state)
        .await?;
    Ok(true)
}

fn item_matches_recovery(
    item: &TaskBoardItem,
    recovery: &TaskBoardAdmissionWorkerRecovery,
) -> bool {
    !item.is_deleted()
        && item.session_id.as_deref() == Some(recovery.session_id.as_str())
        && item.work_item_id.as_deref() == Some(recovery.task_id.as_str())
        && item.workflow.execution_id.as_deref() == Some(recovery.workflow_execution_id.as_str())
        && item.workflow.status == TaskBoardWorkflowStatus::Running
        && item.workflow.current_step_id.as_deref() == Some("worker_running")
}

fn session_task_matches_recovery(
    state: &SessionState,
    recovery: &TaskBoardAdmissionWorkerRecovery,
) -> bool {
    if !state.status.allows_managed_run_mutation() {
        return false;
    }
    let Some(task) = state.tasks.get(&recovery.task_id) else {
        return false;
    };
    if task.is_deleted() || task.status != TaskStatus::InProgress {
        return false;
    }
    let Some(agent_id) = task.assigned_to.as_deref() else {
        return false;
    };
    state.agents.get(agent_id).is_some_and(|agent| {
        agent.matches_managed_agent(&ManagedAgentRef::codex(recovery.managed_worker_id.as_str()))
    })
}
