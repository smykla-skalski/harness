use chrono::{DateTime, Utc};
use serde_json::json;
use sqlx::{FromRow, Sqlite, Transaction, query, query_as};

use super::audit::{
    broadcast_automation_audits, insert_automation_audit, parse_scope, terminal_event_type,
};
use super::control::{ensure_control_row, load_control_in_tx};
use super::runs::run_outcome_label;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::daemon::protocol::HarnessMonitorAuditEvent;
use crate::task_board::TaskBoardAutomationRunOutcome;

const LEASE_EXPIRED_ERROR: &str = "coordinator lease expired before run completion";

#[derive(FromRow)]
struct StaleRunRow {
    run_id: String,
    scope_json: String,
    state: String,
    stop_generation: i64,
}

impl AsyncDaemonDb {
    /// Expire coordinator runs left stale across daemon startup.
    pub(crate) async fn recover_stale_task_board_automation_runs(
        &self,
        now: DateTime<Utc>,
    ) -> Result<u64, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("task board automation startup recovery")
            .await?;
        ensure_control_row(&mut transaction, now).await?;
        let events = expire_stale_runs(&mut transaction, now).await?;
        if !events.is_empty() {
            super::super::items::bump_change_in_tx(
                &mut transaction,
                super::super::ORCHESTRATOR_CHANGE_SCOPE,
            )
            .await?;
        }
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit task board automation startup recovery: {error}"
            ))
        })?;
        broadcast_automation_audits(&events);
        u64::try_from(events.len())
            .map_err(|error| db_error(format!("count recovered automation runs: {error}")))
    }
}

pub(super) async fn expire_stale_runs(
    transaction: &mut Transaction<'_, Sqlite>,
    now: DateTime<Utc>,
) -> Result<Vec<HarnessMonitorAuditEvent>, CliError> {
    let control = load_control_in_tx(transaction).await?;
    let rows = stale_run_rows(transaction, now).await?;
    let mut events = Vec::with_capacity(rows.len());
    for row in rows {
        let outcome = stale_outcome(&row, control.stop_generation);
        expire_stale_row(transaction, &row, outcome, now).await?;
        let scope = parse_scope(&row.scope_json, &row.run_id)?;
        events.push(
            insert_automation_audit(
                transaction,
                terminal_event_type(outcome),
                &row.run_id,
                &scope,
                &now.to_rfc3339(),
                json!({
                    "outcome": outcome,
                    "error_kind": "lease_expired",
                    "error": LEASE_EXPIRED_ERROR,
                }),
            )
            .await?,
        );
    }
    Ok(events)
}

async fn stale_run_rows(
    transaction: &mut Transaction<'_, Sqlite>,
    now: DateTime<Utc>,
) -> Result<Vec<StaleRunRow>, CliError> {
    query_as::<_, StaleRunRow>(
        "SELECT run_id, scope_json, state, stop_generation
         FROM task_board_orchestrator_runs
         WHERE state IN ('running', 'cancelling') AND lease_expires_at <= ?1
         ORDER BY run_id",
    )
    .bind(now.to_rfc3339())
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load stale task board automation runs: {error}")))
}

async fn expire_stale_row(
    transaction: &mut Transaction<'_, Sqlite>,
    row: &StaleRunRow,
    outcome: TaskBoardAutomationRunOutcome,
    now: DateTime<Utc>,
) -> Result<(), CliError> {
    let changed = query(
        "UPDATE task_board_orchestrator_runs
         SET state = 'terminal', outcome = ?2, completed_at = ?3,
             heartbeat_at = ?3, error_kind = 'lease_expired',
             error = ?4, revision = revision + 1
         WHERE run_id = ?1 AND state = ?5 AND lease_expires_at <= ?3",
    )
    .bind(&row.run_id)
    .bind(run_outcome_label(outcome))
    .bind(now.to_rfc3339())
    .bind(LEASE_EXPIRED_ERROR)
    .bind(&row.state)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("expire task board automation run: {error}")))?
    .rows_affected();
    if changed == 1 {
        Ok(())
    } else {
        Err(db_error(format!(
            "task board automation run '{}' changed during stale recovery",
            row.run_id
        )))
    }
}

fn stale_outcome(row: &StaleRunRow, current_stop_generation: u64) -> TaskBoardAutomationRunOutcome {
    let stop_generation = u64::try_from(row.stop_generation).unwrap_or(u64::MAX);
    if row.state == "cancelling" || stop_generation != current_stop_generation {
        TaskBoardAutomationRunOutcome::Cancelled
    } else {
        TaskBoardAutomationRunOutcome::Failed
    }
}
