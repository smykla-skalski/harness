use super::{CliError, Path, SessionState, agents_service};

/// Start a new session, writing directly to `SQLite` when a DB is available.
/// Creates a per-session linked checkout and records the state file under the
/// session root.
///
/// # Errors
/// Returns `CliError` when the worktree cannot be created or DB operations fail.
pub fn start_session_direct(
    request: &super::protocol::SessionStartRequest,
    db: Option<&crate::daemon::db_handle::DaemonDbOwnedHandle>,
) -> Result<SessionState, CliError> {
    harness_daemon_session_service::start_session(request, db)
}

/// Start a new session through the canonical async daemon DB.
/// Creates a per-session worktree; rolls it back on DB failure.
///
/// # Errors
/// Returns `CliError` when the worktree cannot be created or async DB operations fail.
pub(crate) async fn start_session_direct_async(
    request: &super::protocol::SessionStartRequest,
    async_db: &crate::daemon::db_handle::AsyncDaemonDbHandle,
) -> Result<SessionState, CliError> {
    harness_daemon_session_service::start_session_async(request, async_db).await
}

/// Join an existing session, writing directly to `SQLite` when a DB is available.
///
/// # Errors
/// Returns `CliError` when the session or runtime is unknown, or DB operations fail.
pub fn join_session_direct(
    session_id: &str,
    request: &super::protocol::SessionJoinRequest,
    db: Option<&crate::daemon::db_handle::DaemonDbOwnedHandle>,
) -> Result<SessionState, CliError> {
    let agent_session_id = resolve_agent_session_id(request);
    harness_daemon_session_service::join_session(
        session_id,
        request,
        agent_session_id.as_deref(),
        db,
    )
}

/// Join an existing session through the canonical async daemon DB.
///
/// # Errors
/// Returns `CliError` when the session or runtime is unknown, or async DB
/// operations fail.
pub(crate) async fn join_session_direct_async(
    session_id: &str,
    request: &super::protocol::SessionJoinRequest,
    async_db: &crate::daemon::db_handle::AsyncDaemonDbHandle,
) -> Result<SessionState, CliError> {
    let agent_session_id = resolve_agent_session_id(request);
    harness_daemon_session_service::join_session_async(
        session_id,
        request,
        agent_session_id.as_deref(),
        async_db,
    )
    .await
}

fn resolve_agent_session_id(request: &super::protocol::SessionJoinRequest) -> Option<String> {
    let project_dir = Path::new(&request.project_dir);
    super::resolve_hook_agent(&request.runtime)
        .and_then(|rt| agents_service::resolve_known_session_id(rt, project_dir, None).ok())
        .flatten()
}

/// Register a managed agent's runtime session ID through the daemon mutation path.
///
/// # Errors
/// Returns `CliError` when the session lookup, state mutation, or persistence fails.
pub fn register_agent_runtime_session_direct(
    session_id: &str,
    request: &super::protocol::AgentRuntimeSessionRegistrationRequest,
    db: Option<&crate::daemon::db_handle::DaemonDbOwnedHandle>,
) -> Result<bool, CliError> {
    harness_daemon_session_service::register_agent_runtime_session(session_id, request, db)
}

pub(crate) async fn register_agent_runtime_session_direct_async(
    session_id: &str,
    request: &super::protocol::AgentRuntimeSessionRegistrationRequest,
    async_db: &crate::daemon::db_handle::AsyncDaemonDbHandle,
) -> Result<bool, CliError> {
    harness_daemon_session_service::register_agent_runtime_session_async(
        session_id, request, async_db,
    )
    .await
}

/// Update a session title, writing directly to `SQLite`.
///
/// # Errors
/// Returns `CliError` when the session is unknown or DB operations fail.
pub fn update_session_title_direct(
    session_id: &str,
    request: &super::protocol::SessionTitleRequest,
    db: &crate::daemon::db_handle::DaemonDbOwnedHandle,
) -> Result<SessionState, CliError> {
    harness_daemon_session_service::update_session_title(session_id, request, db)
}

/// Update a session title through the canonical async daemon DB.
///
/// # Errors
/// Returns `CliError` when the session is unknown or async DB operations fail.
pub(crate) async fn update_session_title_direct_async(
    session_id: &str,
    request: &super::protocol::SessionTitleRequest,
    async_db: &crate::daemon::db_handle::AsyncDaemonDbHandle,
) -> Result<SessionState, CliError> {
    harness_daemon_session_service::update_session_title_async(session_id, request, async_db).await
}

/// Mark a session agent as disconnected, writing directly to `SQLite` when a
/// DB is available.
///
/// Returns `Ok(false)` when the agent is already non-live or missing.
///
/// # Errors
/// Returns `CliError` when the session cannot be loaded or persisted.
pub fn disconnect_agent_direct(
    session_id: &str,
    agent_id: &str,
    reason: &str,
    db: Option<&crate::daemon::db_handle::DaemonDbOwnedHandle>,
) -> Result<bool, CliError> {
    harness_daemon_session_service::disconnect_agent(session_id, agent_id, reason, db)
}

/// Mark a session agent as disconnected through the canonical async daemon DB.
/// Returns `Ok(false)` when the agent is already non-live or missing.
///
/// # Errors
/// Returns `CliError` when the session cannot be loaded or persisted.
pub(crate) async fn disconnect_agent_direct_async(
    session_id: &str,
    agent_id: &str,
    reason: &str,
    async_db: &crate::daemon::db_handle::AsyncDaemonDbHandle,
) -> Result<bool, CliError> {
    harness_daemon_session_service::disconnect_agent_async(session_id, agent_id, reason, async_db)
        .await
}

/// Record a signal acknowledgment, delegating to the session service.
///
/// # Errors
/// Returns `CliError` on log read/write failures.
pub fn record_signal_ack_direct(
    session_id: &str,
    request: &super::protocol::SignalAckRequest,
    db: Option<&crate::daemon::db_handle::DaemonDbOwnedHandle>,
) -> Result<(), CliError> {
    let project_dir = Path::new(&request.project_dir);
    super::record_signal_ack(
        session_id,
        &request.agent_id,
        &request.signal_id,
        request.result,
        project_dir,
        db,
    )
}

/// Destroy the session worktree, deregister it from the active registry,
/// and delete the DB row. Returns `Ok(false)` when not found.
///
/// # Errors
/// DB write failures return [`CliError`]. `None` db returns an error because
/// DELETE has no file-based fallback path.
pub fn delete_session_direct(
    session_id: &str,
    db: Option<&crate::daemon::db_handle::DaemonDbOwnedHandle>,
) -> Result<bool, CliError> {
    harness_daemon_session_service::delete_session(session_id, db)
}

/// Async variant of [`delete_session_direct`].
///
/// # Errors
/// Returns [`CliError`] on DB failures.
pub(crate) async fn delete_session_direct_async(
    session_id: &str,
    async_db: &crate::daemon::db_handle::AsyncDaemonDbHandle,
) -> Result<bool, CliError> {
    harness_daemon_session_service::delete_session_async(session_id, async_db).await
}
