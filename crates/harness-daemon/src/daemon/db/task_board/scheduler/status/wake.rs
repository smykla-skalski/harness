use sqlx::{SqliteConnection, query_as};

use super::{StoredInstant, keep_latest, stored_instant};
use crate::daemon::db::{CliError, db_error};
use crate::task_board::TASK_BOARD_AUTOMATION_WAKE_BATCH_LIMIT;

#[cfg(test)]
mod tests;

#[derive(Debug)]
pub(super) struct WakeObservation {
    next_pending: Option<StoredInstant>,
    last_processed: Option<StoredInstant>,
}

impl WakeObservation {
    pub(super) fn promote_heartbeat(&self, heartbeat: &mut StoredInstant) {
        if let Some(processed) = self.last_processed.as_ref() {
            keep_latest(heartbeat, processed.clone());
        }
    }

    pub(super) fn next_run_at(&self, other: Option<&StoredInstant>) -> Option<String> {
        match (self.next_pending.as_ref(), other) {
            (Some(wake), Some(other)) if other.instant < wake.instant => Some(other.value.clone()),
            (Some(wake), _) => Some(wake.value.clone()),
            (None, Some(other)) => Some(other.value.clone()),
            (None, None) => None,
        }
    }

    pub(super) fn last_reconciliation_at(&self) -> Option<String> {
        self.last_processed
            .as_ref()
            .map(|processed| processed.value.clone())
    }

    pub(super) const fn is_pending(&self) -> bool {
        self.next_pending.is_some()
    }
}

pub(super) async fn load(connection: &mut SqliteConnection) -> Result<WakeObservation, CliError> {
    let pending = query_as::<_, super::super::wake::TaskBoardAutomationWakeRow>(
        "SELECT sequence, cause, entity_id, entity_revision, payload_json, created_at,
                processed_at
         FROM task_board_orchestrator_wake_events
         WHERE processed_at IS NULL ORDER BY sequence LIMIT ?1",
    )
    .bind(i64::from(TASK_BOARD_AUTOMATION_WAKE_BATCH_LIMIT))
    .fetch_all(&mut *connection)
    .await
    .map_err(|error| db_error(format!("load task board snapshot pending wakes: {error}")))?;
    let processed = query_as::<_, super::super::wake::TaskBoardAutomationWakeRow>(
        "SELECT sequence, cause, entity_id, entity_revision, payload_json, created_at,
                processed_at
         FROM task_board_orchestrator_wake_events
         WHERE processed_at IS NOT NULL
         ORDER BY sequence DESC LIMIT 1",
    )
    .fetch_optional(&mut *connection)
    .await
    .map_err(|error| db_error(format!("load last task board snapshot wake: {error}")))?;
    Ok(WakeObservation {
        next_pending: first_pending(pending)?,
        last_processed: processed.map(decode_processed).transpose()?,
    })
}

fn first_pending(
    rows: Vec<super::super::wake::TaskBoardAutomationWakeRow>,
) -> Result<Option<StoredInstant>, CliError> {
    let mut first = None::<StoredInstant>;
    for row in rows {
        let observation = super::super::wake::decode_task_board_automation_wake_row(row)?;
        if first.is_none() {
            first = Some(stored_instant(
                observation.event.created_at,
                "automation snapshot wake created timestamp",
            )?);
        }
    }
    Ok(first)
}

fn decode_processed(
    row: super::super::wake::TaskBoardAutomationWakeRow,
) -> Result<StoredInstant, CliError> {
    let observation = super::super::wake::decode_task_board_automation_wake_row(row)?;
    let processed_at = observation
        .processed_at
        .ok_or_else(|| db_error("task board snapshot processed wake has no timestamp"))?;
    stored_instant(processed_at, "automation snapshot wake processed timestamp")
}
