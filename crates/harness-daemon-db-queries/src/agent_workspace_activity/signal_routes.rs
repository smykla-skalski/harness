use harness_daemon_db_core::db_error;
use harness_kernel::errors::CliError;
use sqlx::{FromRow, Sqlite, Transaction, query_as};

use super::types::AgentWorkspaceSignalRoute;

#[derive(Debug, FromRow)]
struct SignalRouteRow {
    workspace_id: String,
    member_id: String,
    signal_id: String,
    runtime: String,
    runtime_session_id: String,
    project_dir: String,
    source_session_id: String,
    source_agent_id: String,
}

pub(super) async fn load_signal_route(
    transaction: &mut Transaction<'_, Sqlite>,
    daemon_id: &str,
    source_session_id: &str,
    source_agent_id: &str,
    signal_id: &str,
) -> Result<Option<AgentWorkspaceSignalRoute>, CliError> {
    query_as::<_, SignalRouteRow>(
        "SELECT signal.workspace_id, signal.member_id, signal.signal_id, signal.runtime,
                signal.delivery_runtime_session_id AS runtime_session_id,
                signal.delivery_project_dir AS project_dir,
                signal.source_session_id, signal.source_agent_id
         FROM agent_workspace_signals signal
         JOIN agent_workspaces workspace ON workspace.workspace_id = signal.workspace_id
         WHERE workspace.daemon_id = ?1
           AND signal.source_session_id = ?2 AND signal.source_agent_id = ?3
           AND signal.signal_id = ?4 AND signal.origin_kind = 'native'",
    )
    .bind(daemon_id.trim())
    .bind(source_session_id.trim())
    .bind(source_agent_id.trim())
    .bind(signal_id.trim())
    .fetch_optional(transaction.as_mut())
    .await
    .map(|row| row.map(AgentWorkspaceSignalRoute::from))
    .map_err(|error| db_error(format!("load durable signal compatibility route: {error}")))
}

pub(super) async fn load_pending_signal_routes(
    transaction: &mut Transaction<'_, Sqlite>,
    workspace_id: &str,
    member_id: &str,
) -> Result<Vec<AgentWorkspaceSignalRoute>, CliError> {
    query_as::<_, SignalRouteRow>(
        "SELECT workspace_id, member_id, signal_id, runtime,
                delivery_runtime_session_id AS runtime_session_id,
                delivery_project_dir AS project_dir,
                source_session_id, source_agent_id
         FROM agent_workspace_signals
         WHERE workspace_id = ?1 AND member_id = ?2
           AND origin_kind = 'native' AND ack_json IS NULL
           AND delivery_runtime_session_id IS NOT NULL
           AND delivery_project_dir IS NOT NULL
           AND source_session_id IS NOT NULL AND source_agent_id IS NOT NULL
         ORDER BY created_at, signal_id",
    )
    .bind(workspace_id)
    .bind(member_id)
    .fetch_all(transaction.as_mut())
    .await
    .map(|rows| {
        rows.into_iter()
            .map(AgentWorkspaceSignalRoute::from)
            .collect()
    })
    .map_err(|error| db_error(format!("load pending durable signal routes: {error}")))
}

impl From<SignalRouteRow> for AgentWorkspaceSignalRoute {
    fn from(row: SignalRouteRow) -> Self {
        Self {
            workspace_id: row.workspace_id,
            member_id: row.member_id,
            signal_id: row.signal_id,
            runtime: row.runtime,
            runtime_session_id: row.runtime_session_id,
            project_dir: row.project_dir,
            source_session_id: row.source_session_id,
            source_agent_id: row.source_agent_id,
        }
    }
}
