use sqlx::{Sqlite, Transaction, query, query_as, query_scalar};

use crate::daemon::db::{AsyncDaemonDb, AsyncDaemonTransactions, CliError, db_error, utc_now};

const KILL_SWITCH_FAILURE_REASON: &str = "automation kill switch engaged";
const TRIAGE_DISABLED_FAILURE_REASON: &str = "triage automation disabled";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AgentTurnStopTarget {
    pub(crate) run_id: String,
    pub(crate) runtime_turn_id: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct AutomationKillSwitchStopPlan {
    pub(crate) engaged: bool,
    pub(crate) codex_run_ids: Vec<String>,
    pub(crate) terminal_run_ids: Vec<String>,
    pub(crate) agent_turns: Vec<AgentTurnStopTarget>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct TriageAutomationStopPlan {
    pub(crate) disabled: bool,
    pub(crate) codex_run_ids: Vec<String>,
}

pub(crate) trait AutomationKillSwitchQueries: Send + Sync {
    async fn automation_kill_switch_engaged(&self) -> Result<bool, CliError>;

    async fn automation_kill_switch_stop_plan(
        &self,
    ) -> Result<AutomationKillSwitchStopPlan, CliError>;

    async fn triage_automation_stop_plan(&self) -> Result<TriageAutomationStopPlan, CliError>;
}

impl AutomationKillSwitchQueries for AsyncDaemonDb {
    async fn automation_kill_switch_engaged(&self) -> Result<bool, CliError> {
        automation_kill_switch_engaged(self).await
    }

    async fn automation_kill_switch_stop_plan(
        &self,
    ) -> Result<AutomationKillSwitchStopPlan, CliError> {
        automation_kill_switch_stop_plan(self).await
    }

    async fn triage_automation_stop_plan(&self) -> Result<TriageAutomationStopPlan, CliError> {
        triage_automation_stop_plan(self).await
    }
}

pub(in crate::daemon::db::task_board) async fn automation_kill_switch_engaged_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<bool, CliError> {
    query_scalar(
        "SELECT COALESCE((SELECT spawn_kill_switch FROM policy_workspace
                          WHERE singleton = 1), 0)",
    )
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load automation kill switch: {error}")))
}

pub(in crate::daemon::db::task_board) async fn triage_automation_enabled_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<bool, CliError> {
    query_scalar(
        "SELECT COALESCE(json_extract(settings_json, '$.triage_automation_enabled'), 1)
         FROM task_board_orchestrator_settings WHERE singleton = 1",
    )
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load triage automation setting: {error}")))
}

async fn automation_kill_switch_engaged(db: &AsyncDaemonDb) -> Result<bool, CliError> {
    query_scalar(
        "SELECT COALESCE((SELECT spawn_kill_switch FROM policy_workspace
                          WHERE singleton = 1), 0)",
    )
    .fetch_one(db.pool())
    .await
    .map_err(|error| db_error(format!("load automation kill switch: {error}")))
}

async fn automation_kill_switch_stop_plan(
    db: &AsyncDaemonDb,
) -> Result<AutomationKillSwitchStopPlan, CliError> {
    let mut transaction = db
        .begin_immediate_transaction("task board automation kill switch")
        .await?;
    if !automation_kill_switch_engaged_in_tx(&mut transaction).await? {
        transaction.commit().await.map_err(|error| {
            db_error(format!(
                "commit inactive task board automation kill switch: {error}"
            ))
        })?;
        return Ok(AutomationKillSwitchStopPlan::default());
    }
    cancel_running_triage_escalations(&mut transaction, KILL_SWITCH_FAILURE_REASON).await?;
    let plan = AutomationKillSwitchStopPlan {
        engaged: true,
        codex_run_ids: active_codex_runs(&mut transaction).await?,
        terminal_run_ids: active_terminal_runs(&mut transaction).await?,
        agent_turns: active_agent_turns(&mut transaction).await?,
    };
    transaction.commit().await.map_err(|error| {
        db_error(format!(
            "commit task board automation kill switch stop plan: {error}"
        ))
    })?;
    Ok(plan)
}

async fn triage_automation_stop_plan(
    db: &AsyncDaemonDb,
) -> Result<TriageAutomationStopPlan, CliError> {
    let mut transaction = db
        .begin_immediate_transaction("task board triage automation control")
        .await?;
    let disabled = !triage_automation_enabled_in_tx(&mut transaction).await?;
    if !disabled {
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit active triage automation control: {error}"))
        })?;
        return Ok(TriageAutomationStopPlan::default());
    }
    let codex_run_ids = active_triage_codex_runs(&mut transaction).await?;
    cancel_running_triage_escalations(&mut transaction, TRIAGE_DISABLED_FAILURE_REASON).await?;
    transaction.commit().await.map_err(|error| {
        db_error(format!(
            "commit disabled triage automation control: {error}"
        ))
    })?;
    Ok(TriageAutomationStopPlan {
        disabled: true,
        codex_run_ids,
    })
}

async fn cancel_running_triage_escalations(
    transaction: &mut Transaction<'_, Sqlite>,
    failure_reason: &str,
) -> Result<(), CliError> {
    query(
        "UPDATE task_board_triage_escalations
         SET status = 'failed', completed_at = ?1, failure_reason = ?2
         WHERE status = 'running'",
    )
    .bind(utc_now())
    .bind(failure_reason)
    .execute(transaction.as_mut())
    .await
    .map(|_| ())
    .map_err(|error| db_error(format!("cancel running triage escalations: {error}")))
}

async fn active_triage_codex_runs(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<Vec<String>, CliError> {
    query_scalar(
        "SELECT managed_run_id FROM task_board_triage_escalations AS escalation
         WHERE managed_run_id IS NOT NULL
           AND (
             status = 'running'
             OR (
               status = 'failed'
               AND failure_reason IN (?1, ?2)
               AND EXISTS (
                 SELECT 1 FROM codex_runs AS run
                 WHERE run.run_id = escalation.managed_run_id
                   AND run.status IN ('queued', 'running', 'waiting_approval')
               )
             )
           )
         ORDER BY managed_run_id",
    )
    .bind(TRIAGE_DISABLED_FAILURE_REASON)
    .bind(KILL_SWITCH_FAILURE_REASON)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load active triage Codex runs: {error}")))
}

async fn active_codex_runs(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<Vec<String>, CliError> {
    query_scalar(
        "SELECT run_id FROM codex_runs
         WHERE status IN ('queued', 'running', 'waiting_approval')
         ORDER BY run_id",
    )
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load active Codex runs: {error}")))
}

async fn active_terminal_runs(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<Vec<String>, CliError> {
    query_scalar(
        "SELECT tui_id FROM agent_tuis
         WHERE status IN ('starting', 'running')
         ORDER BY tui_id",
    )
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load active terminal runs: {error}")))
}

async fn active_agent_turns(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<Vec<AgentTurnStopTarget>, CliError> {
    query_as::<_, (String, String)>(
        "SELECT run_id, runtime_turn_id FROM agent_turn_runs
         WHERE runtime_turn_id IS NOT NULL
           AND status IN ('queued', 'running')
         ORDER BY run_id",
    )
    .fetch_all(transaction.as_mut())
    .await
    .map(|rows| {
        rows.into_iter()
            .map(|(run_id, runtime_turn_id)| AgentTurnStopTarget {
                run_id,
                runtime_turn_id,
            })
            .collect()
    })
    .map_err(|error| db_error(format!("load active agent turns: {error}")))
}

#[cfg(test)]
#[path = "automation_kill_switch_tests.rs"]
mod tests;
