use sqlx::{query, query_as};

use super::{
    AgentTuiLiveRefreshState, AgentTuiSize, AgentTuiSnapshot, AgentTuiStatus, AsyncDaemonDb,
    CliError, CodexRunSnapshot, TerminalScreenSnapshot, db_error,
};
use crate::daemon::db::runtime::{
    codex_mode_as_str, codex_mode_from_str, codex_status_as_str, codex_status_from_str,
};

const UPSERT_CODEX_RUN_SQL: &str = "INSERT INTO codex_runs (
    run_id, session_id, project_dir, thread_id, turn_id, mode,
    status, prompt, latest_summary, final_message, error,
    pending_approvals_json, created_at, updated_at
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
ON CONFLICT(run_id) DO UPDATE SET
    session_id = excluded.session_id,
    project_dir = excluded.project_dir,
    thread_id = excluded.thread_id,
    turn_id = excluded.turn_id,
    mode = excluded.mode,
    status = excluded.status,
    prompt = excluded.prompt,
    latest_summary = excluded.latest_summary,
    final_message = excluded.final_message,
    error = excluded.error,
    pending_approvals_json = excluded.pending_approvals_json,
    updated_at = excluded.updated_at";
const CODEX_RUN_SQL: &str = "SELECT run_id, session_id, project_dir, thread_id, turn_id, mode,
    status, prompt, latest_summary, final_message, error,
    pending_approvals_json, created_at, updated_at
 FROM codex_runs
 WHERE run_id = ?1";
const LIST_CODEX_RUNS_SQL: &str =
    "SELECT run_id, session_id, project_dir, thread_id, turn_id, mode,
    status, prompt, latest_summary, final_message, error,
    pending_approvals_json, created_at, updated_at
 FROM codex_runs
 WHERE session_id = ?1
 ORDER BY updated_at DESC";
const UPSERT_AGENT_TUI_SQL: &str = "INSERT INTO agent_tuis (
    tui_id, session_id, agent_id, runtime, status, argv_json,
    project_dir, rows, cols, cursor_row, cursor_col, screen_text,
    transcript_path, exit_code, signal, error, created_at, updated_at
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)
ON CONFLICT(tui_id) DO UPDATE SET
    session_id = excluded.session_id,
    agent_id = excluded.agent_id,
    runtime = excluded.runtime,
    status = excluded.status,
    argv_json = excluded.argv_json,
    project_dir = excluded.project_dir,
    rows = excluded.rows,
    cols = excluded.cols,
    cursor_row = excluded.cursor_row,
    cursor_col = excluded.cursor_col,
    screen_text = excluded.screen_text,
    transcript_path = excluded.transcript_path,
    exit_code = excluded.exit_code,
    signal = excluded.signal,
    error = excluded.error,
    updated_at = excluded.updated_at";
const AGENT_TUI_SQL: &str = "SELECT tui_id, session_id, agent_id, runtime, status, argv_json,
    project_dir, rows, cols, cursor_row, cursor_col, screen_text,
    transcript_path, exit_code, signal, error, created_at, updated_at
 FROM agent_tuis
 WHERE tui_id = ?1";
const LIST_AGENT_TUIS_SQL: &str = "SELECT tui_id, session_id, agent_id, runtime, status, argv_json,
    project_dir, rows, cols, cursor_row, cursor_col, screen_text,
    transcript_path, exit_code, signal, error, created_at, updated_at
 FROM agent_tuis
 WHERE session_id = ?1
 ORDER BY updated_at DESC";
const AGENT_TUI_LIVE_REFRESH_STATE_SQL: &str = "SELECT status, updated_at
 FROM agent_tuis
 WHERE tui_id = ?1";

impl AsyncDaemonDb {
    /// Save or update a Codex controller run snapshot through the canonical async DB.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or serialization failures.
    pub(crate) async fn save_codex_run(&self, snapshot: &CodexRunSnapshot) -> Result<(), CliError> {
        let pending_approvals_json = serde_json::to_string(&snapshot.pending_approvals)
            .map_err(|error| db_error(format!("serialize async codex approvals: {error}")))?;
        query(UPSERT_CODEX_RUN_SQL)
            .bind(&snapshot.run_id)
            .bind(&snapshot.session_id)
            .bind(&snapshot.project_dir)
            .bind(&snapshot.thread_id)
            .bind(&snapshot.turn_id)
            .bind(codex_mode_as_str(snapshot.mode))
            .bind(codex_status_as_str(snapshot.status))
            .bind(&snapshot.prompt)
            .bind(&snapshot.latest_summary)
            .bind(&snapshot.final_message)
            .bind(&snapshot.error)
            .bind(&pending_approvals_json)
            .bind(&snapshot.created_at)
            .bind(&snapshot.updated_at)
            .execute(self.pool())
            .await
            .map_err(|error| db_error(format!("save async codex run: {error}")))?;
        Ok(())
    }

    /// Load one Codex controller run snapshot from the canonical async DB.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or parse failures.
    pub(crate) async fn codex_run(
        &self,
        run_id: &str,
    ) -> Result<Option<CodexRunSnapshot>, CliError> {
        query_as::<_, AsyncCodexRunRow>(CODEX_RUN_SQL)
            .bind(run_id)
            .fetch_optional(self.pool())
            .await
            .map_err(|error| db_error(format!("load async codex run: {error}")))?
            .map(AsyncCodexRunRow::into_snapshot)
            .transpose()
    }

    /// List Codex controller runs for a session, newest first, from the canonical async DB.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or parse failures.
    pub(crate) async fn list_codex_runs(
        &self,
        session_id: &str,
    ) -> Result<Vec<CodexRunSnapshot>, CliError> {
        let rows = query_as::<_, AsyncCodexRunRow>(LIST_CODEX_RUNS_SQL)
            .bind(session_id)
            .fetch_all(self.pool())
            .await
            .map_err(|error| db_error(format!("list async codex runs: {error}")))?;
        rows.into_iter()
            .map(AsyncCodexRunRow::into_snapshot)
            .collect()
    }

    /// Save or update an agent TUI snapshot through the canonical async DB.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or serialization failures.
    pub(crate) async fn save_agent_tui(&self, snapshot: &AgentTuiSnapshot) -> Result<(), CliError> {
        let argv_json = serde_json::to_string(&snapshot.argv)
            .map_err(|error| db_error(format!("serialize async agent TUI argv: {error}")))?;
        query(UPSERT_AGENT_TUI_SQL)
            .bind(&snapshot.tui_id)
            .bind(&snapshot.session_id)
            .bind(&snapshot.agent_id)
            .bind(&snapshot.runtime)
            .bind(snapshot.status.as_str())
            .bind(&argv_json)
            .bind(&snapshot.project_dir)
            .bind(i64::from(snapshot.screen.rows))
            .bind(i64::from(snapshot.screen.cols))
            .bind(i64::from(snapshot.screen.cursor_row))
            .bind(i64::from(snapshot.screen.cursor_col))
            .bind(&snapshot.screen.text)
            .bind(&snapshot.transcript_path)
            .bind(snapshot.exit_code.map(i64::from))
            .bind(&snapshot.signal)
            .bind(&snapshot.error)
            .bind(&snapshot.created_at)
            .bind(&snapshot.updated_at)
            .execute(self.pool())
            .await
            .map_err(|error| db_error(format!("save async agent TUI: {error}")))?;
        Ok(())
    }

    /// Load one managed agent TUI snapshot from the canonical async DB.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or parse failures.
    pub(crate) async fn agent_tui(
        &self,
        tui_id: &str,
    ) -> Result<Option<AgentTuiSnapshot>, CliError> {
        query_as::<_, AsyncAgentTuiRow>(AGENT_TUI_SQL)
            .bind(tui_id)
            .fetch_optional(self.pool())
            .await
            .map_err(|error| db_error(format!("load async agent TUI: {error}")))?
            .map(AsyncAgentTuiRow::into_snapshot)
            .transpose()
    }

    /// Load the minimal freshness state needed to guard live-refresh persists.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or parse failures.
    pub(crate) async fn agent_tui_live_refresh_state(
        &self,
        tui_id: &str,
    ) -> Result<Option<AgentTuiLiveRefreshState>, CliError> {
        query_as::<_, AsyncAgentTuiLiveRefreshStateRow>(AGENT_TUI_LIVE_REFRESH_STATE_SQL)
            .bind(tui_id)
            .fetch_optional(self.pool())
            .await
            .map_err(|error| db_error(format!("load async agent TUI live-refresh state: {error}")))?
            .map(AsyncAgentTuiLiveRefreshStateRow::into_state)
            .transpose()
    }

    /// List managed agent TUI snapshots for a session, newest first, from the canonical async DB.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or parse failures.
    pub(crate) async fn list_agent_tuis(
        &self,
        session_id: &str,
    ) -> Result<Vec<AgentTuiSnapshot>, CliError> {
        let rows = query_as::<_, AsyncAgentTuiRow>(LIST_AGENT_TUIS_SQL)
            .bind(session_id)
            .fetch_all(self.pool())
            .await
            .map_err(|error| db_error(format!("list async agent TUI snapshots: {error}")))?;
        rows.into_iter()
            .map(AsyncAgentTuiRow::into_snapshot)
            .collect()
    }
}

#[derive(sqlx::FromRow)]
struct AsyncCodexRunRow {
    run_id: String,
    session_id: String,
    project_dir: String,
    thread_id: Option<String>,
    turn_id: Option<String>,
    mode: String,
    status: String,
    prompt: String,
    latest_summary: Option<String>,
    final_message: Option<String>,
    error: Option<String>,
    pending_approvals_json: String,
    created_at: String,
    updated_at: String,
}

impl AsyncCodexRunRow {
    fn into_snapshot(self) -> Result<CodexRunSnapshot, CliError> {
        Ok(CodexRunSnapshot {
            run_id: self.run_id,
            session_id: self.session_id,
            project_dir: self.project_dir,
            thread_id: self.thread_id,
            turn_id: self.turn_id,
            mode: codex_mode_from_str(&self.mode)
                .map_err(|error| parse_async_runtime_error("codex mode", &error))?,
            status: codex_status_from_str(&self.status)
                .map_err(|error| parse_async_runtime_error("codex status", &error))?,
            prompt: self.prompt,
            latest_summary: self.latest_summary,
            final_message: self.final_message,
            error: self.error,
            pending_approvals: serde_json::from_str(&self.pending_approvals_json)
                .map_err(|error| db_error(format!("parse async codex approvals: {error}")))?,
            created_at: self.created_at,
            updated_at: self.updated_at,
        })
    }
}

#[derive(sqlx::FromRow)]
struct AsyncAgentTuiRow {
    tui_id: String,
    session_id: String,
    agent_id: String,
    runtime: String,
    status: String,
    argv_json: String,
    project_dir: String,
    rows: i64,
    cols: i64,
    cursor_row: i64,
    cursor_col: i64,
    screen_text: String,
    transcript_path: String,
    exit_code: Option<i64>,
    signal: Option<String>,
    error: Option<String>,
    created_at: String,
    updated_at: String,
}

impl AsyncAgentTuiRow {
    fn into_snapshot(self) -> Result<AgentTuiSnapshot, CliError> {
        let rows = row_i64_to_u16(self.rows, "rows")?;
        let cols = row_i64_to_u16(self.cols, "cols")?;
        let cursor_row = row_i64_to_u16(self.cursor_row, "cursor_row")?;
        let cursor_col = row_i64_to_u16(self.cursor_col, "cursor_col")?;
        let exit_code = self
            .exit_code
            .map(|value| {
                u32::try_from(value).map_err(|error| {
                    db_error(format!("parse async agent TUI exit_code {value}: {error}"))
                })
            })
            .transpose()?;
        Ok(AgentTuiSnapshot {
            tui_id: self.tui_id,
            session_id: self.session_id,
            agent_id: self.agent_id,
            runtime: self.runtime,
            status: AgentTuiStatus::from_str(&self.status)
                .map_err(|error| parse_async_runtime_error("agent TUI status", &error))?,
            argv: serde_json::from_str(&self.argv_json)
                .map_err(|error| db_error(format!("parse async agent TUI argv: {error}")))?,
            project_dir: self.project_dir,
            size: AgentTuiSize { rows, cols },
            screen: TerminalScreenSnapshot {
                rows,
                cols,
                cursor_row,
                cursor_col,
                text: self.screen_text,
            },
            transcript_path: self.transcript_path,
            exit_code,
            signal: self.signal,
            error: self.error,
            created_at: self.created_at,
            updated_at: self.updated_at,
        })
    }
}

#[derive(sqlx::FromRow)]
struct AsyncAgentTuiLiveRefreshStateRow {
    status: String,
    updated_at: String,
}

impl AsyncAgentTuiLiveRefreshStateRow {
    fn into_state(self) -> Result<AgentTuiLiveRefreshState, CliError> {
        Ok(AgentTuiLiveRefreshState {
            status: AgentTuiStatus::from_str(&self.status).map_err(|error| {
                parse_async_runtime_error("agent TUI live-refresh status", &error)
            })?,
            updated_at: self.updated_at,
        })
    }
}

fn row_i64_to_u16(value: i64, column: &str) -> Result<u16, CliError> {
    u16::try_from(value)
        .map_err(|error| db_error(format!("parse async {column} value {value}: {error}")))
}

fn parse_async_runtime_error(subject: &str, error: &str) -> CliError {
    db_error(format!("parse async {subject}: {error}"))
}
