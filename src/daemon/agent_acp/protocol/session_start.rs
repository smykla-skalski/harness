use std::path::PathBuf;
use std::sync::Arc;

use agent_client_protocol::schema::v1::{SessionConfigOption, SessionId, SessionModeState};
use agent_client_protocol::{Agent, ConnectionTo, Error as AcpError, Result as AcpResult};

use super::handshake::handshake_from_initialize;
use super::session_config::AcpSessionRequestConfig;
use super::session_guard::{RouteTarget, SessionRouteGuard};
use super::{
    AcpAgentManagerHandle, AcpSessionSupervisor, send_initialize, send_new_session,
    send_resume_session,
};
use crate::errors::CliError;

/// What opening a session told us, from either `session/new` or
/// `session/resume`. Both report the same two things.
pub(super) struct InitializedRuntimeSession {
    pub(super) session_id: SessionId,
    pub(super) config_options: Option<Vec<SessionConfigOption>>,
    pub(super) modes: Option<SessionModeState>,
}

pub(super) struct RuntimeSessionStart<'a> {
    pub(super) manager: &'a AcpAgentManagerHandle,
    pub(super) supervisor: &'a Arc<AcpSessionSupervisor>,
    pub(super) connection: &'a ConnectionTo<Agent>,
    pub(super) project_dir: PathBuf,
    pub(super) session_config: &'a AcpSessionRequestConfig,
    /// A prior agent session to pick up instead of opening a new one.
    pub(super) resume_session_id: Option<&'a str>,
    pub(super) session_id: &'a str,
    pub(super) acp_id: &'a str,
    pub(super) runtime_name: &'a str,
    pub(super) session_guard: &'a SessionRouteGuard,
}

pub(super) async fn initialize_and_bind_runtime_session(
    input: RuntimeSessionStart<'_>,
) -> AcpResult<InitializedRuntimeSession> {
    let RuntimeSessionStart {
        manager,
        supervisor,
        connection,
        project_dir,
        session_config,
        resume_session_id,
        session_id,
        acp_id,
        runtime_name,
        session_guard,
    } = input;
    let started_session = initialize_runtime_session(
        supervisor,
        connection,
        project_dir,
        session_config,
        resume_session_id,
    )
    .await?;
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
    session_config: &AcpSessionRequestConfig,
    resume_session_id: Option<&str>,
) -> AcpResult<InitializedRuntimeSession> {
    let initialize_timeout = supervisor.config().initialize_timeout;
    let initialize_response = send_initialize(supervisor, connection, initialize_timeout).await?;
    // The session inputs are capability-gated, so the handshake has to be
    // recorded before either request is built.
    supervisor.record_handshake(handshake_from_initialize(&initialize_response));
    let started = if let Some(resume_session_id) = resume_target(supervisor, resume_session_id) {
        resume_runtime_session(
            supervisor,
            connection,
            project_dir,
            session_config,
            resume_session_id,
        )
        .await?
    } else {
        let response = send_new_session(supervisor, connection, project_dir, session_config).await?;
        InitializedRuntimeSession {
            session_id: response.session_id,
            config_options: response.config_options,
            modes: response.modes,
        }
    };
    super::session_state::seed_from_session_start(
        supervisor,
        started.config_options.as_deref(),
        started.modes.as_ref(),
    );
    Ok(started)
}

/// The session to resume, or `None` to open a fresh one.
///
/// An agent that never advertised `session/resume` would answer it with
/// method-not-found, so a stored id is worth nothing without the capability
/// and the caller silently gets a new session instead.
fn resume_target<'a>(
    supervisor: &AcpSessionSupervisor,
    resume_session_id: Option<&'a str>,
) -> Option<&'a str> {
    let resume_session_id = resume_session_id.map(str::trim).filter(|id| !id.is_empty())?;
    supervisor
        .handshake()
        .is_some_and(|handshake| handshake.supports_session_resume)
        .then_some(resume_session_id)
}

/// Resume falls back to a new session rather than failing the start: the id
/// came from a past run, and an agent that has since dropped that session
/// should still give us a working one.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
async fn resume_runtime_session(
    supervisor: &Arc<AcpSessionSupervisor>,
    connection: &ConnectionTo<Agent>,
    project_dir: PathBuf,
    session_config: &AcpSessionRequestConfig,
    resume_session_id: &str,
) -> AcpResult<InitializedRuntimeSession> {
    match send_resume_session(
        supervisor,
        connection,
        project_dir.clone(),
        session_config,
        resume_session_id,
    )
    .await
    {
        Ok(response) => {
            tracing::info!(resume_session_id, "resumed ACP agent session");
            Ok(InitializedRuntimeSession {
                session_id: SessionId::new(resume_session_id.to_string()),
                config_options: response.config_options,
                modes: response.modes,
            })
        }
        Err(error) => {
            tracing::warn!(%error, resume_session_id, "ACP session resume failed; starting a new session");
            let response =
                send_new_session(supervisor, connection, project_dir, session_config).await?;
            Ok(InitializedRuntimeSession {
                session_id: response.session_id,
                config_options: response.config_options,
                modes: response.modes,
            })
        }
    }
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
