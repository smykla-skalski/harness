use std::path::PathBuf;
use std::sync::Arc;

use agent_client_protocol::schema::{NewSessionResponse, SessionId};
use agent_client_protocol::{Agent, ConnectionTo, Error as AcpError, Result as AcpResult};

use super::session_guard::{RouteTarget, SessionRouteGuard};
use super::{AcpAgentManagerHandle, AcpSessionSupervisor, send_initialize, send_new_session};
use crate::errors::CliError;

pub(super) struct InitializedRuntimeSession {
    pub(super) session_id: SessionId,
    pub(super) response: NewSessionResponse,
}

#[expect(
    clippy::too_many_arguments,
    reason = "ACP initialize+bind needs all of these on one call site to keep the route-registration ordering invariant explicit"
)]
pub(super) async fn initialize_and_bind_runtime_session(
    manager: &AcpAgentManagerHandle,
    supervisor: &Arc<AcpSessionSupervisor>,
    connection: &ConnectionTo<Agent>,
    project_dir: PathBuf,
    session_id: &str,
    acp_id: &str,
    runtime_name: &str,
    session_guard: &SessionRouteGuard,
) -> AcpResult<InitializedRuntimeSession> {
    let started_session = initialize_runtime_session(supervisor, connection, project_dir).await?;
    let acp_session_id = started_session.session_id.clone();
    // Register the route the moment we know the runtime's session_id - the runtime
    // can fire `session/update` notifications immediately after `new_session` returns,
    // so any gap before `bind_runtime_session` finishes would silently drop them with
    // `routing_not_initialized` (e.g. gemini's available_commands_update arrives while
    // the orchestration bind is still in flight).
    session_guard.start_session(
        &acp_session_id,
        RouteTarget {
            acp_id: acp_id.to_string(),
            session_id: session_id.to_string(),
        },
    );
    if let Err(error) =
        bind_runtime_session(manager, session_id, acp_id, runtime_name, &acp_session_id).await
    {
        session_guard.stop_session(&acp_session_id);
        return Err(error);
    }
    Ok(started_session)
}

async fn initialize_runtime_session(
    supervisor: &Arc<AcpSessionSupervisor>,
    connection: &ConnectionTo<Agent>,
    project_dir: PathBuf,
) -> AcpResult<InitializedRuntimeSession> {
    let initialize_timeout = supervisor.config().initialize_timeout;
    send_initialize(supervisor, connection, initialize_timeout).await?;
    let response = send_new_session(supervisor, connection, project_dir).await?;
    Ok(InitializedRuntimeSession {
        session_id: response.session_id.clone(),
        response,
    })
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
