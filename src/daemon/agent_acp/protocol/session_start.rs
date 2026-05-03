use std::path::PathBuf;
use std::sync::Arc;

use agent_client_protocol::schema::SessionId;
use agent_client_protocol::{Agent, ConnectionTo, Error as AcpError, Result as AcpResult};

use super::{AcpAgentManagerHandle, AcpSessionSupervisor, send_initialize, send_new_session};
use crate::errors::CliError;

pub(super) async fn initialize_and_bind_runtime_session(
    manager: &AcpAgentManagerHandle,
    supervisor: &Arc<AcpSessionSupervisor>,
    connection: &ConnectionTo<Agent>,
    project_dir: PathBuf,
    session_id: &str,
    acp_id: &str,
    runtime_name: &str,
) -> AcpResult<SessionId> {
    let acp_session_id = initialize_runtime_session(supervisor, connection, project_dir).await?;
    bind_runtime_session(manager, session_id, acp_id, runtime_name, &acp_session_id).await?;
    Ok(acp_session_id)
}

async fn initialize_runtime_session(
    supervisor: &Arc<AcpSessionSupervisor>,
    connection: &ConnectionTo<Agent>,
    project_dir: PathBuf,
) -> AcpResult<SessionId> {
    let initialize_timeout = supervisor.config().initialize_timeout;
    send_initialize(supervisor, connection, initialize_timeout).await?;
    send_new_session(supervisor, connection, project_dir).await
}

async fn bind_runtime_session(
    manager: &AcpAgentManagerHandle,
    session_id: &str,
    acp_id: &str,
    runtime_name: &str,
    acp_session_id: &SessionId,
) -> AcpResult<()> {
    let registered =
        load_runtime_bind_registration(manager, session_id, acp_id, runtime_name, acp_session_id)
            .await?;
    if !registered {
        log_missing_runtime_bind(session_id, acp_id, runtime_name, acp_session_id);
        return Err(missing_runtime_bind_error(acp_id));
    }
    log_runtime_bind_success(session_id, acp_id, runtime_name, acp_session_id);
    Ok(())
}

async fn load_runtime_bind_registration(
    manager: &AcpAgentManagerHandle,
    session_id: &str,
    acp_id: &str,
    runtime_name: &str,
    acp_session_id: &SessionId,
) -> AcpResult<bool> {
    let runtime_session_id = acp_session_id.to_string();
    manager
        .bind_orchestration_runtime_session_async(
            session_id,
            acp_id,
            runtime_name,
            &runtime_session_id,
        )
        .await
        .map_err(|error| {
            log_runtime_bind_error(session_id, acp_id, runtime_name, acp_session_id, &error);
            AcpError::new(-32603, format!("bind ACP runtime session: {error}"))
        })
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_runtime_bind_error(
    session_id: &str,
    acp_id: &str,
    runtime_name: &str,
    acp_session_id: &SessionId,
    error: &CliError,
) {
    tracing::warn!(
        session_id,
        acp_id,
        runtime_name,
        runtime_session_id = %acp_session_id,
        %error,
        "failed to bind ACP runtime session into orchestration"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_missing_runtime_bind(
    session_id: &str,
    acp_id: &str,
    runtime_name: &str,
    acp_session_id: &SessionId,
) {
    tracing::warn!(
        session_id,
        acp_id,
        runtime_name,
        runtime_session_id = %acp_session_id,
        "ACP runtime session bind found no orchestration registration to update"
    );
}

fn missing_runtime_bind_error(acp_id: &str) -> AcpError {
    AcpError::new(
        -32603,
        format!("bind ACP runtime session: missing orchestration agent for '{acp_id}'"),
    )
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
fn log_runtime_bind_success(
    session_id: &str,
    acp_id: &str,
    runtime_name: &str,
    acp_session_id: &SessionId,
) {
    tracing::info!(
        session_id,
        acp_id,
        runtime_name,
        runtime_session_id = %acp_session_id,
        "bound ACP protocol session to orchestration"
    );
}
