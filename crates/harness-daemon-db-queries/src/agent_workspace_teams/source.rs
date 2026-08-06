use harness_daemon_db_core::db_error;
use harness_kernel::errors::CliError;
use sqlx::{FromRow, Sqlite, Transaction, query_as};

#[derive(Debug, Clone, FromRow)]
pub(super) struct WorkspaceSourceRow {
    pub workspace_id: String,
    pub selected_legacy_session_id: Option<String>,
    pub selected_lifecycle: Option<String>,
    pub leader_agent_id: Option<String>,
    pub source_revision: Option<i64>,
    pub reconciled_revision: Option<i64>,
    pub stored_shadow_digest: Option<String>,
    pub team_created_at: Option<String>,
}

#[derive(Debug, Clone, FromRow)]
pub(super) struct RegistrationRow {
    pub session_id: String,
    pub agent_id: String,
    pub name: String,
    pub runtime: String,
    pub role: String,
    pub capabilities_json: String,
    pub status: String,
    pub runtime_session_id: Option<String>,
    pub managed_agent_kind: Option<String>,
    pub managed_agent_id: Option<String>,
    pub joined_at: String,
    pub updated_at: String,
    pub last_activity_at: Option<String>,
    pub current_task_id: Option<String>,
    pub runtime_capabilities_json: String,
}

#[derive(Debug, Clone, FromRow)]
pub(super) struct TuiRow {
    pub tui_id: String,
    pub session_id: String,
    pub agent_id: String,
    pub runtime: String,
    pub status: String,
    pub exit_code: Option<i64>,
    pub signal: Option<String>,
    pub error: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, FromRow)]
pub(super) struct CodexRow {
    pub run_id: String,
    pub session_id: String,
    pub session_agent_id: Option<String>,
    pub display_name: Option<String>,
    pub thread_id: Option<String>,
    pub task_id: Option<String>,
    pub status: String,
    pub error: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone)]
pub(super) struct WorkspaceSources {
    pub workspace: WorkspaceSourceRow,
    pub registrations: Vec<RegistrationRow>,
    pub tuis: Vec<TuiRow>,
    pub codex_runs: Vec<CodexRow>,
}

pub(super) async fn load_workspace_sources(
    transaction: &mut Transaction<'_, Sqlite>,
    daemon_id: &str,
    workspace_id: Option<&str>,
) -> Result<Vec<WorkspaceSources>, CliError> {
    let rows = query_as::<_, WorkspaceSourceRow>(
        "SELECT workspace.workspace_id,
                CASE WHEN team.workspace_id IS NULL
                          OR EXISTS (
                              SELECT 1 FROM sessions selected_session
                              WHERE selected_session.session_id = workspace.selected_legacy_session_id
                          )
                     THEN workspace.selected_legacy_session_id
                     ELSE team.selected_legacy_session_id
                END AS selected_legacy_session_id,
                CASE WHEN team.workspace_id IS NULL
                          OR EXISTS (
                              SELECT 1 FROM sessions selected_session
                              WHERE selected_session.session_id = workspace.selected_legacy_session_id
                          )
                     THEN provenance.lifecycle
                     ELSE team.selected_lifecycle
                END AS selected_lifecycle,
                session.leader_id AS leader_agent_id,
                team.source_revision,
                team.reconciled_revision,
                team.shadow_digest AS stored_shadow_digest,
                team.created_at AS team_created_at
         FROM agent_workspaces workspace
         LEFT JOIN agent_workspace_legacy_sessions provenance
           ON provenance.workspace_id = workspace.workspace_id
          AND provenance.is_selected = 1
         LEFT JOIN agent_workspace_teams team
           ON team.workspace_id = workspace.workspace_id
         LEFT JOIN sessions session
           ON session.session_id = CASE WHEN team.workspace_id IS NULL
                                             OR EXISTS (
                                                 SELECT 1 FROM sessions selected_session
                                                 WHERE selected_session.session_id = workspace.selected_legacy_session_id
                                             )
                                        THEN workspace.selected_legacy_session_id
                                        ELSE team.selected_legacy_session_id
                                   END
         WHERE workspace.daemon_id = ?1
           AND (?2 IS NULL OR workspace.workspace_id = ?2)
           AND (
               team.workspace_id IS NULL
               OR team.source_revision <> team.reconciled_revision
               OR team.shadow_digest = ''
               OR team.selected_legacy_session_id IS NOT CASE
                   WHEN EXISTS (
                       SELECT 1 FROM sessions selected_session
                       WHERE selected_session.session_id = workspace.selected_legacy_session_id
                   )
                   THEN workspace.selected_legacy_session_id
                   ELSE team.selected_legacy_session_id
               END
           )
         ORDER BY workspace.workspace_id",
    )
    .bind(daemon_id)
    .bind(workspace_id)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load agent team workspaces: {error}")))?;

    let mut sources = Vec::with_capacity(rows.len());
    for workspace in rows {
        let legacy_session_ids =
            load_legacy_session_ids(transaction, &workspace.workspace_id).await?;
        let session_ids_json = serde_json::to_string(&legacy_session_ids)
            .map_err(|error| db_error(format!("serialize agent team source ids: {error}")))?;
        let registrations = load_registrations(transaction, &session_ids_json).await?;
        let tuis = load_tuis(transaction, &session_ids_json).await?;
        let codex_runs = load_codex_runs(transaction, &session_ids_json).await?;
        sources.push(WorkspaceSources {
            workspace,
            registrations,
            tuis,
            codex_runs,
        });
    }
    Ok(sources)
}

async fn load_legacy_session_ids(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
) -> Result<Vec<String>, CliError> {
    query_as::<_, (String,)>(
        "SELECT session_id
         FROM agent_workspace_legacy_sessions
         WHERE workspace_id = ?1
         ORDER BY session_id",
    )
    .bind(workspace_id)
    .fetch_all(transaction.as_mut())
    .await
    .map(|rows| rows.into_iter().map(|(session_id,)| session_id).collect())
    .map_err(|error| db_error(format!("load agent team legacy sessions: {error}")))
}

async fn load_registrations(
    transaction: &mut Transaction<'_, Sqlite>,
    session_ids_json: &str,
) -> Result<Vec<RegistrationRow>, CliError> {
    query_as::<_, RegistrationRow>(
        "SELECT session_id, agent_id, name, runtime, role, capabilities_json,
                status, agent_session_id AS runtime_session_id,
                managed_agent_kind, managed_agent_id, joined_at, updated_at,
                last_activity_at, current_task_id, runtime_capabilities_json
         FROM agents
         WHERE session_id IN (SELECT value FROM json_each(?1))
         ORDER BY session_id, agent_id",
    )
    .bind(session_ids_json)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load agent team registrations: {error}")))
}

async fn load_tuis(
    transaction: &mut Transaction<'_, Sqlite>,
    session_ids_json: &str,
) -> Result<Vec<TuiRow>, CliError> {
    query_as::<_, TuiRow>(
        "SELECT tui_id, session_id, agent_id, runtime, status, exit_code,
                signal, error, created_at, updated_at
         FROM agent_tuis
         WHERE session_id IN (SELECT value FROM json_each(?1))
         ORDER BY session_id, tui_id",
    )
    .bind(session_ids_json)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load agent team terminal runtimes: {error}")))
}

async fn load_codex_runs(
    transaction: &mut Transaction<'_, Sqlite>,
    session_ids_json: &str,
) -> Result<Vec<CodexRow>, CliError> {
    query_as::<_, CodexRow>(
        "SELECT run_id, session_id, session_agent_id, display_name, thread_id,
                task_id, status, error, created_at, updated_at
         FROM codex_runs
         WHERE session_id IN (SELECT value FROM json_each(?1))
         ORDER BY session_id, run_id",
    )
    .bind(session_ids_json)
    .fetch_all(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load agent team Codex runtimes: {error}")))
}
