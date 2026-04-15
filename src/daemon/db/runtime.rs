use super::{
    AgentTuiLiveRefreshState, AgentTuiSize, AgentTuiSnapshot, AgentTuiStatus, Arc, CliError,
    CodexRunMode, CodexRunSnapshot, CodexRunStatus, DaemonDb, ErrorKind, IoError, Mutex, OnceLock,
    TerminalScreenSnapshot, Type, db_error, state,
};

pub(crate) fn ensure_shared_db(
    db_slot: &Arc<OnceLock<Arc<Mutex<DaemonDb>>>>,
) -> Result<Arc<Mutex<DaemonDb>>, CliError> {
    if let Some(db) = db_slot.get() {
        return Ok(Arc::clone(db));
    }

    let db_path = state::daemon_root().join("harness.db");
    let db = Arc::new(Mutex::new(DaemonDb::open(&db_path)?));
    let _ = db_slot.set(Arc::clone(&db));
    Ok(db_slot.get().cloned().unwrap_or(db))
}

impl DaemonDb {
    /// Save or update a Codex controller run snapshot.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or serialization failures.
    pub fn save_codex_run(&self, snapshot: &CodexRunSnapshot) -> Result<(), CliError> {
        let pending_approvals_json = serde_json::to_string(&snapshot.pending_approvals)
            .map_err(|error| db_error(format!("serialize codex approvals: {error}")))?;
        self.conn
            .execute(
                "INSERT INTO codex_runs (
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
                    updated_at = excluded.updated_at",
                rusqlite::params![
                    snapshot.run_id,
                    snapshot.session_id,
                    snapshot.project_dir,
                    snapshot.thread_id,
                    snapshot.turn_id,
                    codex_mode_as_str(snapshot.mode),
                    codex_status_as_str(snapshot.status),
                    snapshot.prompt,
                    snapshot.latest_summary,
                    snapshot.final_message,
                    snapshot.error,
                    pending_approvals_json,
                    snapshot.created_at,
                    snapshot.updated_at,
                ],
            )
            .map_err(|error| db_error(format!("save codex run: {error}")))?;
        Ok(())
    }

    /// Load one Codex controller run snapshot.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or parse failures.
    pub fn codex_run(&self, run_id: &str) -> Result<Option<CodexRunSnapshot>, CliError> {
        let result = self.conn.query_row(
            "SELECT run_id, session_id, project_dir, thread_id, turn_id, mode,
                status, prompt, latest_summary, final_message, error,
                pending_approvals_json, created_at, updated_at
             FROM codex_runs
             WHERE run_id = ?1",
            [run_id],
            codex_run_from_row,
        );
        match result {
            Ok(snapshot) => Ok(Some(snapshot)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(error) => Err(db_error(format!("load codex run: {error}"))),
        }
    }

    /// List Codex controller runs for a session, newest first.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or parse failures.
    pub fn list_codex_runs(&self, session_id: &str) -> Result<Vec<CodexRunSnapshot>, CliError> {
        let mut statement = self
            .conn
            .prepare(
                "SELECT run_id, session_id, project_dir, thread_id, turn_id, mode,
                    status, prompt, latest_summary, final_message, error,
                    pending_approvals_json, created_at, updated_at
                 FROM codex_runs
                 WHERE session_id = ?1
                 ORDER BY updated_at DESC",
            )
            .map_err(|error| db_error(format!("prepare codex run list: {error}")))?;
        let rows = statement
            .query_map([session_id], codex_run_from_row)
            .map_err(|error| db_error(format!("query codex run list: {error}")))?;

        let mut snapshots = Vec::new();
        for row in rows {
            snapshots.push(row.map_err(|error| db_error(format!("read codex run row: {error}")))?);
        }
        Ok(snapshots)
    }

    /// Persist a managed agent TUI snapshot.
    ///
    /// # Errors
    /// Returns [`CliError`] on serialization or SQL failures.
    pub fn save_agent_tui(&self, snapshot: &AgentTuiSnapshot) -> Result<(), CliError> {
        let argv_json = serde_json::to_string(&snapshot.argv)
            .map_err(|error| db_error(format!("serialize agent TUI argv: {error}")))?;
        self.conn
            .execute(
                "INSERT INTO agent_tuis (
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
                    updated_at = excluded.updated_at",
                rusqlite::params![
                    snapshot.tui_id,
                    snapshot.session_id,
                    snapshot.agent_id,
                    snapshot.runtime,
                    snapshot.status.as_str(),
                    argv_json,
                    snapshot.project_dir,
                    snapshot.screen.rows,
                    snapshot.screen.cols,
                    snapshot.screen.cursor_row,
                    snapshot.screen.cursor_col,
                    snapshot.screen.text,
                    snapshot.transcript_path,
                    snapshot.exit_code,
                    snapshot.signal,
                    snapshot.error,
                    snapshot.created_at,
                    snapshot.updated_at,
                ],
            )
            .map_err(|error| db_error(format!("save agent TUI: {error}")))?;
        Ok(())
    }

    /// Load one managed agent TUI snapshot.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or parse failures.
    pub fn agent_tui(&self, tui_id: &str) -> Result<Option<AgentTuiSnapshot>, CliError> {
        let result = self.conn.query_row(
            "SELECT tui_id, session_id, agent_id, runtime, status, argv_json,
                project_dir, rows, cols, cursor_row, cursor_col, screen_text,
                transcript_path, exit_code, signal, error, created_at, updated_at
             FROM agent_tuis
             WHERE tui_id = ?1",
            [tui_id],
            agent_tui_from_row,
        );
        match result {
            Ok(snapshot) => Ok(Some(snapshot)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(error) => Err(db_error(format!("load agent TUI: {error}"))),
        }
    }

    /// Load the minimal freshness state needed to guard live-refresh persists.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or parse failures.
    pub(crate) fn agent_tui_live_refresh_state(
        &self,
        tui_id: &str,
    ) -> Result<Option<AgentTuiLiveRefreshState>, CliError> {
        let result = self.conn.query_row(
            "SELECT status, updated_at
             FROM agent_tuis
             WHERE tui_id = ?1",
            [tui_id],
            |row| {
                let status_raw: String = row.get(0)?;
                Ok(AgentTuiLiveRefreshState {
                    status: AgentTuiStatus::from_str(&status_raw).map_err(parse_error_to_sql)?,
                    updated_at: row.get(1)?,
                })
            },
        );
        match result {
            Ok(state) => Ok(Some(state)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(error) => Err(db_error(format!(
                "load agent TUI live-refresh state: {error}"
            ))),
        }
    }

    /// List managed agent TUI snapshots for a session, newest first.
    ///
    /// # Errors
    /// Returns [`CliError`] on SQL or parse failures.
    pub fn list_agent_tuis(&self, session_id: &str) -> Result<Vec<AgentTuiSnapshot>, CliError> {
        let mut statement = self
            .conn
            .prepare(
                "SELECT tui_id, session_id, agent_id, runtime, status, argv_json,
                    project_dir, rows, cols, cursor_row, cursor_col, screen_text,
                    transcript_path, exit_code, signal, error, created_at, updated_at
                 FROM agent_tuis
                 WHERE session_id = ?1
                 ORDER BY updated_at DESC",
            )
            .map_err(|error| db_error(format!("prepare agent TUI list: {error}")))?;
        let rows = statement
            .query_map([session_id], agent_tui_from_row)
            .map_err(|error| db_error(format!("query agent TUI list: {error}")))?;

        let mut snapshots = Vec::new();
        for row in rows {
            snapshots.push(row.map_err(|error| db_error(format!("read agent TUI row: {error}")))?);
        }
        Ok(snapshots)
    }
}

fn codex_run_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<CodexRunSnapshot> {
    let mode_raw: String = row.get(5)?;
    let status_raw: String = row.get(6)?;
    let pending_approvals_json: String = row.get(11)?;
    Ok(CodexRunSnapshot {
        run_id: row.get(0)?,
        session_id: row.get(1)?,
        project_dir: row.get(2)?,
        thread_id: row.get(3)?,
        turn_id: row.get(4)?,
        mode: codex_mode_from_str(&mode_raw).map_err(parse_error_to_sql)?,
        status: codex_status_from_str(&status_raw).map_err(parse_error_to_sql)?,
        prompt: row.get(7)?,
        latest_summary: row.get(8)?,
        final_message: row.get(9)?,
        error: row.get(10)?,
        pending_approvals: serde_json::from_str(&pending_approvals_json)
            .map_err(|error| parse_error_to_sql(format!("parse codex approvals: {error}")))?,
        created_at: row.get(12)?,
        updated_at: row.get(13)?,
    })
}

fn agent_tui_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<AgentTuiSnapshot> {
    let status_raw: String = row.get(4)?;
    let argv_json: String = row.get(5)?;
    let rows = row_i64_to_u16(row.get(7)?, "rows")?;
    let cols = row_i64_to_u16(row.get(8)?, "cols")?;
    let cursor_row = row_i64_to_u16(row.get(9)?, "cursor_row")?;
    let cursor_col = row_i64_to_u16(row.get(10)?, "cursor_col")?;
    let exit_code = row
        .get::<_, Option<i64>>(13)?
        .map(|value| u32::try_from(value).map_err(|error| parse_error_to_sql(error.to_string())))
        .transpose()?;
    Ok(AgentTuiSnapshot {
        tui_id: row.get(0)?,
        session_id: row.get(1)?,
        agent_id: row.get(2)?,
        runtime: row.get(3)?,
        status: AgentTuiStatus::from_str(&status_raw).map_err(parse_error_to_sql)?,
        argv: serde_json::from_str(&argv_json)
            .map_err(|error| parse_error_to_sql(format!("parse agent TUI argv: {error}")))?,
        project_dir: row.get(6)?,
        size: AgentTuiSize { rows, cols },
        screen: TerminalScreenSnapshot {
            rows,
            cols,
            cursor_row,
            cursor_col,
            text: row.get(11)?,
        },
        transcript_path: row.get(12)?,
        exit_code,
        signal: row.get(14)?,
        error: row.get(15)?,
        created_at: row.get(16)?,
        updated_at: row.get(17)?,
    })
}

pub(super) fn row_i64_to_u16(value: i64, column: &str) -> rusqlite::Result<u16> {
    u16::try_from(value)
        .map_err(|error| parse_error_to_sql(format!("invalid {column} value {value}: {error}")))
}

fn parse_error_to_sql(error: String) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(
        0,
        Type::Text,
        Box::new(IoError::new(ErrorKind::InvalidData, error)),
    )
}

pub(super) fn codex_mode_as_str(mode: CodexRunMode) -> &'static str {
    match mode {
        CodexRunMode::Report => "report",
        CodexRunMode::WorkspaceWrite => "workspace_write",
        CodexRunMode::Approval => "approval",
    }
}

pub(super) fn codex_mode_from_str(value: &str) -> Result<CodexRunMode, String> {
    match value {
        "report" => Ok(CodexRunMode::Report),
        "workspace_write" => Ok(CodexRunMode::WorkspaceWrite),
        "approval" => Ok(CodexRunMode::Approval),
        _ => Err(format!("unknown codex run mode '{value}'")),
    }
}

pub(super) fn codex_status_as_str(status: CodexRunStatus) -> &'static str {
    match status {
        CodexRunStatus::Queued => "queued",
        CodexRunStatus::Running => "running",
        CodexRunStatus::WaitingApproval => "waiting_approval",
        CodexRunStatus::Completed => "completed",
        CodexRunStatus::Failed => "failed",
        CodexRunStatus::Cancelled => "cancelled",
    }
}

pub(super) fn codex_status_from_str(value: &str) -> Result<CodexRunStatus, String> {
    match value {
        "queued" => Ok(CodexRunStatus::Queued),
        "running" => Ok(CodexRunStatus::Running),
        "waiting_approval" => Ok(CodexRunStatus::WaitingApproval),
        "completed" => Ok(CodexRunStatus::Completed),
        "failed" => Ok(CodexRunStatus::Failed),
        "cancelled" => Ok(CodexRunStatus::Cancelled),
        _ => Err(format!("unknown codex run status '{value}'")),
    }
}
