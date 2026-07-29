use chrono::{DateTime, Duration, Utc};
use sqlx::{QueryBuilder, Sqlite, SqliteConnection, Transaction, query, query_as};

use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::{
    TaskBoardAutomationHistoryRequest, TaskBoardAutomationHistoryResponse,
    TaskBoardAutomationRunDetail, TaskBoardAutomationRunInfo, TaskBoardAutomationRunOutcome,
    TaskBoardAutomationRunState, TaskBoardAutomationRunTrigger, TaskBoardAutomationScope,
};

const RUN_INFO_SELECT_SQL: &str = "SELECT run_id, trigger, state, outcome, dry_run, scope_json,
    started_at, heartbeat_at, completed_at,
    '' AS stage_summary_json, NULL AS error_kind, NULL AS error
    FROM task_board_orchestrator_runs";
const ACTIVE_RUN_INFO_SELECT_SQL: &str =
    "SELECT run_id, trigger, state, outcome, dry_run, scope_json,
    started_at, heartbeat_at, completed_at,
    '' AS stage_summary_json, NULL AS error_kind, NULL AS error
    FROM task_board_orchestrator_runs
    WHERE state IN ('running', 'cancelling') LIMIT 1";
const RUN_DETAIL_SELECT_SQL: &str = "SELECT run_id, trigger, state, outcome, dry_run, scope_json,
    started_at, heartbeat_at, completed_at, stage_summary_json, error_kind, error
    FROM task_board_orchestrator_runs WHERE run_id = ?1";
const RUN_HISTORY_RETENTION_DAYS: i64 = 30;
const RUN_HISTORY_RETENTION_BATCH_LIMIT: i64 = 100;

#[derive(sqlx::FromRow)]
struct RunRecordRow {
    run_id: String,
    trigger: String,
    state: String,
    outcome: Option<String>,
    dry_run: i64,
    scope_json: String,
    started_at: String,
    heartbeat_at: String,
    completed_at: Option<String>,
    stage_summary_json: String,
    error_kind: Option<String>,
    error: Option<String>,
}

#[derive(Debug)]
struct HistoryCursor {
    completed_at: String,
    run_id: String,
}

impl AsyncDaemonDb {
    pub(crate) async fn active_task_board_automation_run(
        &self,
    ) -> Result<Option<TaskBoardAutomationRunInfo>, CliError> {
        let row = query_as::<_, RunRecordRow>(ACTIVE_RUN_INFO_SELECT_SQL)
            .fetch_optional(self.pool())
            .await
            .map_err(|error| db_error(format!("load active task board automation run: {error}")))?;
        row.as_ref().map(run_info_from_row).transpose()
    }

    pub(crate) async fn task_board_automation_history(
        &self,
        request: &TaskBoardAutomationHistoryRequest,
    ) -> Result<TaskBoardAutomationHistoryResponse, CliError> {
        let cursor = request
            .before
            .as_deref()
            .map(parse_history_cursor)
            .transpose()?;
        let limit = request.normalized_limit();
        history_response(
            load_history_rows(self, cursor.as_ref(), limit).await?,
            limit,
        )
    }

    pub(crate) async fn task_board_automation_run_detail(
        &self,
        run_id: &str,
    ) -> Result<Option<TaskBoardAutomationRunDetail>, CliError> {
        let row = query_as::<_, RunRecordRow>(RUN_DETAIL_SELECT_SQL)
            .bind(run_id)
            .fetch_optional(self.pool())
            .await
            .map_err(|error| {
                db_error(format!(
                    "load task board automation run detail '{run_id}': {error}"
                ))
            })?;
        row.as_ref().map(run_detail_from_row).transpose()
    }
}

pub(super) async fn prune_terminal_run_history(
    transaction: &mut Transaction<'_, Sqlite>,
    finalized_at: DateTime<Utc>,
) -> Result<u64, CliError> {
    let cutoff = finalized_at - Duration::days(RUN_HISTORY_RETENTION_DAYS);
    query(
        "DELETE FROM task_board_orchestrator_runs
         WHERE run_id IN (
            SELECT run_id FROM task_board_orchestrator_runs
            WHERE state = 'terminal' AND completed_at IS NOT NULL AND completed_at < ?1
            ORDER BY completed_at, run_id LIMIT ?2
         )",
    )
    .bind(cutoff.to_rfc3339())
    .bind(RUN_HISTORY_RETENTION_BATCH_LIMIT)
    .execute(transaction.as_mut())
    .await
    .map(|result| result.rows_affected())
    .map_err(|error| db_error(format!("retain task board automation run history: {error}")))
}

pub(super) async fn load_snapshot_run_infos(
    connection: &mut SqliteConnection,
) -> Result<Vec<TaskBoardAutomationRunInfo>, CliError> {
    let rows = query_as::<_, RunRecordRow>(
        "WITH candidates(run_id) AS (
            SELECT run_id FROM task_board_orchestrator_runs
            WHERE state IN ('running', 'cancelling')
            UNION
            SELECT run_id FROM (
                SELECT run_id FROM task_board_orchestrator_runs
                WHERE state = 'terminal' AND outcome IN ('completed', 'noop')
                  AND completed_at IS NOT NULL
                ORDER BY completed_at DESC, run_id DESC LIMIT 1
            )
            UNION
            SELECT run_id FROM (
                SELECT run_id FROM task_board_orchestrator_runs
                WHERE state = 'terminal' AND completed_at IS NOT NULL
                ORDER BY completed_at DESC, run_id DESC LIMIT 1
            )
         )
         SELECT run_id, trigger, state, outcome, dry_run, scope_json, started_at,
                heartbeat_at, completed_at,
                '' AS stage_summary_json, NULL AS error_kind, NULL AS error
         FROM task_board_orchestrator_runs
         WHERE run_id IN (SELECT run_id FROM candidates)",
    )
    .fetch_all(&mut *connection)
    .await
    .map_err(|error| db_error(format!("load task board automation snapshot runs: {error}")))?;
    rows.iter().map(run_info_from_row).collect()
}

async fn load_history_rows(
    db: &AsyncDaemonDb,
    cursor: Option<&HistoryCursor>,
    limit: u32,
) -> Result<Vec<RunRecordRow>, CliError> {
    let mut builder = QueryBuilder::<Sqlite>::new(RUN_INFO_SELECT_SQL);
    builder.push(" WHERE state = 'terminal' AND completed_at IS NOT NULL");
    if let Some(cursor) = cursor {
        builder.push(" AND (completed_at < ");
        builder.push_bind(cursor.completed_at.clone());
        builder.push(" OR (completed_at = ");
        builder.push_bind(cursor.completed_at.clone());
        builder.push(" AND run_id < ");
        builder.push_bind(cursor.run_id.clone());
        builder.push("))");
    }
    builder.push(" ORDER BY completed_at DESC, run_id DESC LIMIT ");
    builder.push_bind(i64::from(limit) + 1);
    builder
        .build_query_as::<RunRecordRow>()
        .fetch_all(db.pool())
        .await
        .map_err(|error| db_error(format!("load task board automation run history: {error}")))
}

fn history_response(
    mut rows: Vec<RunRecordRow>,
    limit: u32,
) -> Result<TaskBoardAutomationHistoryResponse, CliError> {
    let limit = usize::try_from(limit).unwrap_or(usize::MAX);
    let has_older = rows.len() > limit;
    rows.truncate(limit);
    let runs = rows
        .iter()
        .map(run_info_from_row)
        .collect::<Result<Vec<_>, _>>()?;
    let next_cursor = has_older
        .then(|| runs.last().and_then(run_cursor))
        .flatten();
    Ok(TaskBoardAutomationHistoryResponse {
        runs,
        next_cursor,
        has_older,
    })
}

fn run_detail_from_row(row: &RunRecordRow) -> Result<TaskBoardAutomationRunDetail, CliError> {
    Ok(TaskBoardAutomationRunDetail {
        run: run_info_from_row(row)?,
        stages: super::stages::decode_stages(&row.stage_summary_json, &row.run_id)?,
        error_kind: row.error_kind.clone(),
        error: row.error.clone(),
    })
}

fn run_info_from_row(row: &RunRecordRow) -> Result<TaskBoardAutomationRunInfo, CliError> {
    let trigger = parse_run_trigger(&row.trigger)?;
    let state = parse_run_state(&row.state)?;
    let outcome = row.outcome.as_deref().map(parse_run_outcome).transpose()?;
    validate_run_shape(row, state, outcome)?;
    let scope =
        serde_json::from_str::<TaskBoardAutomationScope>(&row.scope_json).map_err(|error| {
            db_error(format!(
                "parse task board automation run scope '{}': {error}",
                row.run_id
            ))
        })?;
    Ok(TaskBoardAutomationRunInfo {
        run_id: row.run_id.clone(),
        trigger,
        state,
        outcome,
        dry_run: row.dry_run == 1,
        scope,
        started_at: row.started_at.clone(),
        heartbeat_at: row.heartbeat_at.clone(),
        completed_at: row.completed_at.clone(),
    })
}

fn validate_run_shape(
    row: &RunRecordRow,
    state: TaskBoardAutomationRunState,
    outcome: Option<TaskBoardAutomationRunOutcome>,
) -> Result<(), CliError> {
    if !matches!(row.dry_run, 0 | 1) {
        return Err(invalid_run_value("dry-run flag", &row.dry_run.to_string()));
    }
    parse_instant(&row.started_at, &row.run_id, "start")?;
    parse_instant(&row.heartbeat_at, &row.run_id, "heartbeat")?;
    if let Some(completed_at) = row.completed_at.as_deref() {
        parse_instant(completed_at, &row.run_id, "completion")?;
    }
    let terminal = state == TaskBoardAutomationRunState::Terminal;
    if terminal != outcome.is_some() || terminal != row.completed_at.is_some() {
        return Err(db_error(format!(
            "incoherent task board automation run '{}' terminal state",
            row.run_id
        )));
    }
    Ok(())
}

fn parse_instant(value: &str, run_id: &str, kind: &str) -> Result<(), CliError> {
    DateTime::parse_from_rfc3339(value)
        .map(|_| ())
        .map_err(|error| {
            db_error(format!(
                "parse task board automation run {kind} '{run_id}': {error}"
            ))
        })
}

fn parse_history_cursor(value: &str) -> Result<HistoryCursor, CliError> {
    let (completed_at, run_id) = value
        .split_once('|')
        .filter(|(completed_at, run_id)| !completed_at.is_empty() && !run_id.is_empty())
        .ok_or_else(|| db_error("invalid task board automation history cursor"))?;
    DateTime::parse_from_rfc3339(completed_at).map_err(|error| {
        db_error(format!(
            "parse task board automation history cursor: {error}"
        ))
    })?;
    Ok(HistoryCursor {
        completed_at: completed_at.to_string(),
        run_id: run_id.to_string(),
    })
}

fn run_cursor(run: &TaskBoardAutomationRunInfo) -> Option<String> {
    run.completed_at
        .as_ref()
        .map(|completed_at| format!("{completed_at}|{}", run.run_id))
}

fn parse_run_trigger(value: &str) -> Result<TaskBoardAutomationRunTrigger, CliError> {
    match value {
        "scheduled" => Ok(TaskBoardAutomationRunTrigger::Scheduled),
        "event" => Ok(TaskBoardAutomationRunTrigger::Event),
        "manual" => Ok(TaskBoardAutomationRunTrigger::Manual),
        "recovery" => Ok(TaskBoardAutomationRunTrigger::Recovery),
        value => Err(invalid_run_value("trigger", value)),
    }
}

fn parse_run_state(value: &str) -> Result<TaskBoardAutomationRunState, CliError> {
    match value {
        "running" => Ok(TaskBoardAutomationRunState::Running),
        "cancelling" => Ok(TaskBoardAutomationRunState::Cancelling),
        "terminal" => Ok(TaskBoardAutomationRunState::Terminal),
        value => Err(invalid_run_value("state", value)),
    }
}

fn parse_run_outcome(value: &str) -> Result<TaskBoardAutomationRunOutcome, CliError> {
    match value {
        "completed" => Ok(TaskBoardAutomationRunOutcome::Completed),
        "noop" => Ok(TaskBoardAutomationRunOutcome::Noop),
        "partial" => Ok(TaskBoardAutomationRunOutcome::Partial),
        "failed" => Ok(TaskBoardAutomationRunOutcome::Failed),
        "cancelled" => Ok(TaskBoardAutomationRunOutcome::Cancelled),
        value => Err(invalid_run_value("outcome", value)),
    }
}

fn invalid_run_value(kind: &str, value: &str) -> CliError {
    db_error(format!(
        "invalid task board automation run {kind} '{value}'"
    ))
}
