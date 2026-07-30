//! Durable storage and restart reconciliation for agent turn runs.
//!
//! Codex runs persist through `codex_runs`; this table (`agent_turn_runs`)
//! covers every other supported runtime (`OpenRouter` today). A run is recorded
//! the moment it starts, its requested and actual runtime and model are both
//! stored, a terminal status is sticky and releases the run's task-board
//! concurrency admission, and a restart settles any interrupted run to exactly
//! one terminal outcome without manual intervention.

use harness_workspace::workspace::utc_now;
use sqlx::{query, query_as, query_scalar};

use super::task_board::release_managed_worker_admission_in_tx;
use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};

/// Bind a full run snapshot onto a prepared statement, in column order. A macro
/// rather than a function so the concrete `sqlx` query type never has to be
/// named; both the plain and transactional callers expand it inline.
macro_rules! bind_run {
    ($statement:expr, $snapshot:expr) => {
        $statement
            .bind(&$snapshot.run_id)
            .bind(&$snapshot.session_id)
            .bind(&$snapshot.task_id)
            .bind(&$snapshot.board_item_id)
            .bind(&$snapshot.workflow_execution_id)
            .bind(&$snapshot.project_dir)
            .bind(&$snapshot.requested_runtime)
            .bind(&$snapshot.actual_runtime)
            .bind(&$snapshot.runtime_turn_id)
            .bind(&$snapshot.requested_model)
            .bind(&$snapshot.actual_model)
            .bind($snapshot.status.as_str())
            .bind(&$snapshot.source_revision)
            .bind(&$snapshot.report)
            .bind(&$snapshot.stop_reason)
            .bind(&$snapshot.error)
            .bind(&$snapshot.created_at)
            .bind(&$snapshot.updated_at)
    };
}

/// Lifecycle of an agent turn run. `Queued` and `Running` are active; the rest
/// are terminal. There is no `WaitingApproval`: report runs never gate on an
/// approval the way codex workspace turns can.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AgentTurnRunStatus {
    Queued,
    Running,
    Completed,
    Failed,
    Cancelled,
}

impl AgentTurnRunStatus {
    pub(crate) const fn is_active(self) -> bool {
        matches!(self, Self::Queued | Self::Running)
    }

    const fn as_str(self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::Running => "running",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
        }
    }

    fn parse(value: &str) -> Result<Self, CliError> {
        match value {
            "queued" => Ok(Self::Queued),
            "running" => Ok(Self::Running),
            "completed" => Ok(Self::Completed),
            "failed" => Ok(Self::Failed),
            "cancelled" => Ok(Self::Cancelled),
            other => Err(db_error(format!("unknown agent turn run status: {other}"))),
        }
    }
}

/// Durable snapshot of one agent turn run. `run_id` doubles as the task-board
/// `managed_worker_id`, so persisting a terminal status releases the matching
/// concurrency admission in the same transaction.
#[derive(Debug, Clone)]
pub(crate) struct AgentTurnRunSnapshot {
    pub run_id: String,
    pub session_id: Option<String>,
    pub task_id: Option<String>,
    pub board_item_id: Option<String>,
    pub workflow_execution_id: Option<String>,
    pub project_dir: Option<String>,
    pub requested_runtime: String,
    pub actual_runtime: Option<String>,
    pub runtime_turn_id: Option<String>,
    pub requested_model: Option<String>,
    pub actual_model: Option<String>,
    pub status: AgentTurnRunStatus,
    pub source_revision: Option<String>,
    pub report: Option<String>,
    pub stop_reason: Option<String>,
    pub error: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

/// A repeated start with the same id must never clobber a run that already
/// progressed, so start-by-id inserts only when absent.
const RECORD_STARTED_SQL: &str = "INSERT OR IGNORE INTO agent_turn_runs (run_id, session_id, \
     task_id, board_item_id, workflow_execution_id, project_dir, requested_runtime, \
     actual_runtime, runtime_turn_id, requested_model, actual_model, status, source_revision, \
     report, stop_reason, error, created_at, updated_at) \
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)";

const SELECT_BY_ID_SQL: &str = "SELECT run_id, session_id, task_id, board_item_id, \
     workflow_execution_id, project_dir, requested_runtime, actual_runtime, runtime_turn_id, \
     requested_model, actual_model, status, source_revision, report, stop_reason, error, created_at, updated_at \
     FROM agent_turn_runs WHERE run_id = ?1";

// A later save carries only the columns it learned. `requested_runtime` is
// immutable and simply omitted from the update, so it keeps its first-insert
// value; identity, context, the actual runtime, and both models are preserved
// with COALESCE so a poll that only knows the new status never erases what an
// earlier save established. The trailing WHERE freezes the whole row once it is
// terminal: a terminal run's status, error, stop_reason, and every other
// column become immutable, so exactly one terminal outcome survives every later
// write and every restart even under a racing caller.
const UPSERT_SQL: &str = "INSERT INTO agent_turn_runs (run_id, session_id, task_id, board_item_id, \
     workflow_execution_id, project_dir, requested_runtime, actual_runtime, runtime_turn_id, \
     requested_model, actual_model, status, source_revision, report, stop_reason, error, created_at, updated_at) \
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18) \
     ON CONFLICT(run_id) DO UPDATE SET \
        session_id = COALESCE(excluded.session_id, agent_turn_runs.session_id), \
        task_id = COALESCE(excluded.task_id, agent_turn_runs.task_id), \
        board_item_id = COALESCE(excluded.board_item_id, agent_turn_runs.board_item_id), \
        workflow_execution_id = COALESCE(excluded.workflow_execution_id, agent_turn_runs.workflow_execution_id), \
        project_dir = COALESCE(excluded.project_dir, agent_turn_runs.project_dir), \
        actual_runtime = COALESCE(excluded.actual_runtime, agent_turn_runs.actual_runtime), \
        runtime_turn_id = COALESCE(excluded.runtime_turn_id, agent_turn_runs.runtime_turn_id), \
        requested_model = COALESCE(excluded.requested_model, agent_turn_runs.requested_model), \
        actual_model = COALESCE(excluded.actual_model, agent_turn_runs.actual_model), \
        status = excluded.status, \
        source_revision = COALESCE(excluded.source_revision, agent_turn_runs.source_revision), \
        report = COALESCE(excluded.report, agent_turn_runs.report), \
        stop_reason = COALESCE(excluded.stop_reason, agent_turn_runs.stop_reason), \
        error = COALESCE(excluded.error, agent_turn_runs.error), \
        updated_at = excluded.updated_at \
     WHERE agent_turn_runs.status NOT IN ('completed', 'failed', 'cancelled')";

impl AsyncDaemonDb {
    /// Record an agent turn run at start. Idempotent by `run_id`: a repeat start
    /// leaves the stored row untouched and returns it, so a reclaimed dispatch
    /// claim never doubles the agent work.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub(crate) async fn record_agent_turn_run_started(
        &self,
        snapshot: &AgentTurnRunSnapshot,
    ) -> Result<AgentTurnRunSnapshot, CliError> {
        bind_run!(query(RECORD_STARTED_SQL), snapshot)
            .execute(self.pool())
            .await
            .map_err(|error| db_error(format!("record agent turn run start: {error}")))?;
        self.agent_turn_run(&snapshot.run_id)
            .await?
            .ok_or_else(|| db_error("agent turn run vanished immediately after start"))
    }

    /// Save or update an agent turn run. A terminal status is sticky and releases
    /// the run's task-board concurrency admission in the same transaction.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub(crate) async fn save_agent_turn_run(
        &self,
        snapshot: &AgentTurnRunSnapshot,
    ) -> Result<(), CliError> {
        let mut transaction = self
            .begin_immediate_transaction("agent turn run save")
            .await?;
        bind_run!(query(UPSERT_SQL), snapshot)
            .execute(transaction.as_mut())
            .await
            .map_err(|error| db_error(format!("save agent turn run: {error}")))?;
        if !snapshot.status.is_active() {
            release_managed_worker_admission_in_tx(&mut transaction, &snapshot.run_id).await?;
        }
        transaction
            .commit()
            .await
            .map_err(|error| db_error(format!("commit agent turn run save: {error}")))
    }

    /// Load one agent turn run.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or parse failures.
    pub(crate) async fn agent_turn_run(
        &self,
        run_id: &str,
    ) -> Result<Option<AgentTurnRunSnapshot>, CliError> {
        query_as::<_, AgentTurnRunRow>(SELECT_BY_ID_SQL)
            .bind(run_id)
            .fetch_optional(self.pool())
            .await
            .map_err(|error| db_error(format!("load agent turn run: {error}")))?
            .map(AgentTurnRunRow::into_snapshot)
            .transpose()
    }

    pub(crate) async fn cancel_agent_turn_run(&self, run_id: &str) -> Result<(), CliError> {
        let Some(mut run) = self.agent_turn_run(run_id).await? else {
            return Err(db_error("cancelled agent turn run does not exist"));
        };
        if !run.status.is_active() {
            return Ok(());
        }
        run.status = AgentTurnRunStatus::Cancelled;
        run.stop_reason = Some("cancelled by remote executor".into());
        run.updated_at = utc_now();
        self.save_agent_turn_run(&run).await
    }

    /// Settle legacy agent turn runs that lack a provider turn identity after a
    /// daemon restart. Correlated runs stay active so runtime reconciliation can
    /// harvest their terminal result. Idempotent: a second sweep finds nothing
    /// eligible and settles zero runs.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL failures.
    pub(crate) async fn reconcile_interrupted_agent_turn_runs(&self) -> Result<usize, CliError> {
        let active: Vec<String> = query_scalar(
            "SELECT run_id FROM agent_turn_runs \
                 WHERE status IN ('queued', 'running') AND runtime_turn_id IS NULL",
        )
        .fetch_all(self.pool())
        .await
        .map_err(|error| db_error(format!("scan interrupted agent turn runs: {error}")))?;
        let mut settled = 0;
        for run_id in active {
            settled += self.settle_interrupted_agent_turn_run(&run_id).await?;
        }
        if settled > 0 {
            tracing::info!(settled, "settled interrupted agent turn runs");
        }
        Ok(settled)
    }

    async fn settle_interrupted_agent_turn_run(&self, run_id: &str) -> Result<usize, CliError> {
        let mut transaction = self
            .begin_immediate_transaction("agent turn run restart reconcile")
            .await?;
        let changed = query(
            "UPDATE agent_turn_runs \
             SET status = 'failed', \
                 error = COALESCE(error, 'agent turn was interrupted by a daemon restart'), \
                 updated_at = ?2 \
             WHERE run_id = ?1 \
               AND status IN ('queued', 'running') \
               AND runtime_turn_id IS NULL",
        )
        .bind(run_id)
        .bind(utc_now())
        .execute(transaction.as_mut())
        .await
        .map_err(|error| db_error(format!("settle interrupted agent turn run: {error}")))?
        .rows_affected();
        if changed > 0 {
            release_managed_worker_admission_in_tx(&mut transaction, run_id).await?;
        }
        transaction.commit().await.map_err(|error| {
            db_error(format!("commit interrupted agent turn run settle: {error}"))
        })?;
        Ok(usize::from(changed > 0))
    }
}

#[derive(sqlx::FromRow)]
struct AgentTurnRunRow {
    run_id: String,
    session_id: Option<String>,
    task_id: Option<String>,
    board_item_id: Option<String>,
    workflow_execution_id: Option<String>,
    project_dir: Option<String>,
    requested_runtime: String,
    actual_runtime: Option<String>,
    runtime_turn_id: Option<String>,
    requested_model: Option<String>,
    actual_model: Option<String>,
    status: String,
    source_revision: Option<String>,
    report: Option<String>,
    stop_reason: Option<String>,
    error: Option<String>,
    created_at: String,
    updated_at: String,
}

impl AgentTurnRunRow {
    fn into_snapshot(self) -> Result<AgentTurnRunSnapshot, CliError> {
        Ok(AgentTurnRunSnapshot {
            run_id: self.run_id,
            session_id: self.session_id,
            task_id: self.task_id,
            board_item_id: self.board_item_id,
            workflow_execution_id: self.workflow_execution_id,
            project_dir: self.project_dir,
            requested_runtime: self.requested_runtime,
            actual_runtime: self.actual_runtime,
            runtime_turn_id: self.runtime_turn_id,
            requested_model: self.requested_model,
            actual_model: self.actual_model,
            status: AgentTurnRunStatus::parse(&self.status)?,
            source_revision: self.source_revision,
            report: self.report,
            stop_reason: self.stop_reason,
            error: self.error,
            created_at: self.created_at,
            updated_at: self.updated_at,
        })
    }
}

#[cfg(test)]
#[path = "async_agent_turn_runs_tests.rs"]
mod tests;
