use super::session_setup::{PreparedSession, prepare_session, rollback_session_artifacts};
use super::session_teardown::destroy_session_artifacts;
use super::{
    CliError, Path, SessionState, agents_service, build_log_entry, index, record_signal_ack,
    resolve_hook_agent, session_not_found, session_service, session_storage, utc_now,
};
use crate::errors::CliErrorKind;

/// Start a new session, writing directly to `SQLite` when a DB is available.
/// Creates a per-session linked checkout and records the state file under the
/// session root.
///
/// # Errors
/// Returns `CliError` when the worktree cannot be created or DB operations fail.
pub fn start_session_direct(
    request: &super::protocol::SessionStartRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionState, CliError> {
    let Some(db) = db else {
        // No local DB: route through start_session_with_policy. That helper
        // first tries to forward to a running harness daemon over HTTP - the
        // receiving daemon (which always has its own DB) creates the worktree
        // via start_session_direct_async. When no daemon is reachable, the
        // helper falls back to the legacy file-based path which intentionally
        // does NOT create a worktree, since per the workspace-layout spec the
        // daemon owns worktree lifecycle and a file-only fallback session
        // never gains one.
        return session_service::start_session_with_policy(
            &request.context,
            &request.title,
            Path::new(&request.project_dir),
            request.session_id.as_deref(),
            request.policy_preset.as_deref(),
        );
    };
    let prepared = prepare_session(request)?;
    let PreparedSession {
        layout,
        canonical_origin,
        state,
    } = prepared;

    let project_id = match ensure_project_registered(db, &canonical_origin) {
        Ok(id) => id,
        Err(error) => {
            rollback_session_artifacts(&canonical_origin, &layout);
            return Err(error);
        }
    };
    if let Err(error) = db.create_session_record(&project_id, &state) {
        rollback_session_artifacts(&canonical_origin, &layout);
        return Err(error);
    }
    db.append_log_entry(&build_log_entry(
        &state.session_id,
        session_service::log_session_started(&request.title, &request.context),
        None,
        None,
    ))?;
    db.bump_change(&state.session_id)?;
    db.bump_change("global")?;
    Ok(state)
}

/// Start a new session through the canonical async daemon DB.
/// Creates a per-session worktree; rolls it back on DB failure.
///
/// # Errors
/// Returns `CliError` when the worktree cannot be created or async DB operations fail.
pub(crate) async fn start_session_direct_async(
    request: &super::protocol::SessionStartRequest,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<SessionState, CliError> {
    let prepared = prepare_session(request)?;
    let PreparedSession {
        layout,
        canonical_origin,
        state,
    } = prepared;

    let project_id = match ensure_project_registered_async(async_db, &canonical_origin).await {
        Ok(id) => id,
        Err(error) => {
            rollback_session_artifacts(&canonical_origin, &layout);
            return Err(error);
        }
    };
    if let Err(error) = async_db.create_session_record(&project_id, &state).await {
        rollback_session_artifacts(&canonical_origin, &layout);
        return Err(error);
    }
    async_db
        .append_log_entry(&build_log_entry(
            &state.session_id,
            session_service::log_session_started(&request.title, &request.context),
            None,
            None,
        ))
        .await?;
    async_db.bump_change(&state.session_id).await?;
    async_db.bump_change("global").await?;
    Ok(state)
}

pub(crate) fn ensure_project_registered(
    db: &super::db::DaemonDb,
    project_dir: &Path,
) -> Result<String, CliError> {
    session_storage::record_project_origin(project_dir)?;
    let project = index::discovered_project_for_checkout(project_dir);
    db.sync_project(&project)?;
    Ok(project.project_id)
}

pub(crate) async fn ensure_project_registered_async(
    async_db: &super::db::AsyncDaemonDb,
    project_dir: &Path,
) -> Result<String, CliError> {
    session_storage::record_project_origin(project_dir)?;
    let project = index::discovered_project_for_checkout(project_dir);
    async_db.sync_project(&project).await?;
    Ok(project.project_id)
}
/// Join an existing session, writing directly to `SQLite` when a DB is available.
///
/// # Errors
/// Returns `CliError` when the session or runtime is unknown, or DB operations fail.
pub fn join_session_direct(
    session_id: &str,
    request: &super::protocol::SessionJoinRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionState, CliError> {
    let display_name = request
        .name
        .clone()
        .unwrap_or_else(|| format!("{} {:?}", request.runtime, request.role).to_lowercase());

    let project_dir = Path::new(&request.project_dir);
    let agent_session_id = resolve_hook_agent(&request.runtime)
        .and_then(|rt| agents_service::resolve_known_session_id(rt, project_dir, None).ok())
        .flatten();

    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        let now = utc_now();
        let joined_role =
            session_service::resolve_join_role(&state, request.role, request.fallback_role)?;
        let agent_id = session_service::apply_join_session(
            &mut state,
            &display_name,
            &request.runtime,
            joined_role,
            &request.capabilities,
            agent_session_id.as_deref(),
            &now,
            request.persona.as_deref(),
        )?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_agent_joined(&agent_id, joined_role, &request.runtime),
            None,
            None,
        ))?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return Ok(state);
    }

    // File-based fallback
    session_service::join_session_with_fallback(
        session_id,
        request.role,
        request.fallback_role,
        &request.runtime,
        &request.capabilities,
        request.name.as_deref(),
        project_dir,
        request.persona.as_deref(),
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
    async_db: &super::db::AsyncDaemonDb,
) -> Result<SessionState, CliError> {
    let display_name = request
        .name
        .clone()
        .unwrap_or_else(|| format!("{} {:?}", request.runtime, request.role).to_lowercase());

    let project_dir = Path::new(&request.project_dir);
    let agent_session_id = resolve_hook_agent(&request.runtime)
        .and_then(|rt| agents_service::resolve_known_session_id(rt, project_dir, None).ok())
        .flatten();

    let now = utc_now();
    let (agent_id, joined_role, state) = async_db
        .update_session_state_immediate(session_id, |state| {
            let joined_role =
                session_service::resolve_join_role(state, request.role, request.fallback_role)?;
            let agent_id = session_service::apply_join_session(
                state,
                &display_name,
                &request.runtime,
                joined_role,
                &request.capabilities,
                agent_session_id.as_deref(),
                &now,
                request.persona.as_deref(),
            )?;
            Ok((agent_id, joined_role, state.clone()))
        })
        .await?;
    async_db
        .append_log_entry(&build_log_entry(
            session_id,
            session_service::log_agent_joined(&agent_id, joined_role, &request.runtime),
            None,
            None,
        ))
        .await?;
    async_db.bump_change(session_id).await?;
    async_db.bump_change("global").await?;
    Ok(state)
}

/// Register a managed agent's runtime session ID through the daemon mutation path.
///
/// # Errors
/// Returns `CliError` when the session lookup, state mutation, or persistence fails.
pub fn register_agent_runtime_session_direct(
    session_id: &str,
    request: &super::protocol::AgentRuntimeSessionRegistrationRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<bool, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        let now = utc_now();
        let registered = session_service::apply_register_agent_runtime_session(
            &mut state,
            &request.runtime,
            &request.tui_id,
            &request.agent_session_id,
            &now,
        )?;
        if !registered {
            return Ok(false);
        }
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return Ok(true);
    }

    session_service::register_agent_runtime_session(
        session_id,
        &request.runtime,
        &request.tui_id,
        &request.agent_session_id,
        Path::new(&request.project_dir),
    )
}

pub(crate) async fn register_agent_runtime_session_direct_async(
    session_id: &str,
    request: &super::protocol::AgentRuntimeSessionRegistrationRequest,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<bool, CliError> {
    let now = utc_now();
    let registered = async_db
        .update_session_state_immediate(session_id, |state| {
            session_service::apply_register_agent_runtime_session(
                state,
                &request.runtime,
                &request.tui_id,
                &request.agent_session_id,
                &now,
            )
        })
        .await?;
    if !registered {
        return Ok(false);
    }
    async_db.bump_change(session_id).await?;
    async_db.bump_change("global").await?;
    Ok(true)
}

/// Update a session title, writing directly to `SQLite`.
///
/// # Errors
/// Returns `CliError` when the session is unknown or DB operations fail.
pub fn update_session_title_direct(
    session_id: &str,
    request: &super::protocol::SessionTitleRequest,
    db: &super::db::DaemonDb,
) -> Result<SessionState, CliError> {
    let Some(mut state) = db.load_session_state_for_mutation(session_id)? else {
        return Err(session_not_found(session_id));
    };

    state.state_version += 1;
    session_service::apply_update_session_title(&mut state, &request.title, &utc_now())?;
    let project_id = db
        .project_id_for_session(session_id)?
        .ok_or_else(|| session_not_found(session_id))?;
    db.save_session_state(&project_id, &state)?;
    db.bump_change(session_id)?;
    db.bump_change("global")?;
    Ok(state)
}

/// Update a session title through the canonical async daemon DB.
///
/// # Errors
/// Returns `CliError` when the session is unknown or async DB operations fail.
pub(crate) async fn update_session_title_direct_async(
    session_id: &str,
    request: &super::protocol::SessionTitleRequest,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<SessionState, CliError> {
    let now = utc_now();
    let state = async_db
        .update_session_state_immediate(session_id, |state| {
            state.state_version += 1;
            session_service::apply_update_session_title(state, &request.title, &now)?;
            Ok(state.clone())
        })
        .await?;
    async_db.bump_change(session_id).await?;
    async_db.bump_change("global").await?;
    Ok(state)
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
    db: Option<&super::db::DaemonDb>,
) -> Result<bool, CliError> {
    let Some(db) = db else {
        return Ok(false);
    };
    let Some(mut state) = db.load_session_state_for_mutation(session_id)? else {
        return Ok(false);
    };

    let now = utc_now();
    if !session_service::apply_agent_disconnected(&mut state, agent_id, &now) {
        return Ok(false);
    }

    persist_disconnect(db, session_id, agent_id, reason, &state)?;
    Ok(true)
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
    async_db: &super::db::AsyncDaemonDb,
) -> Result<bool, CliError> {
    let now = utc_now();
    let disconnected = async_db
        .update_session_state_immediate(session_id, |state| {
            Ok(session_service::apply_agent_disconnected(
                state, agent_id, &now,
            ))
        })
        .await?;
    if !disconnected {
        return Ok(false);
    }

    async_db
        .append_log_entry(&build_log_entry(
            session_id,
            session_service::log_agent_disconnected(agent_id, reason),
            None,
            None,
        ))
        .await?;
    async_db.bump_change(session_id).await?;
    async_db.bump_change("global").await?;
    Ok(true)
}

pub(crate) fn persist_disconnect(
    db: &super::db::DaemonDb,
    session_id: &str,
    agent_id: &str,
    reason: &str,
    state: &SessionState,
) -> Result<(), CliError> {
    let project_id = db
        .project_id_for_session(session_id)?
        .ok_or_else(|| session_not_found(session_id))?;
    db.save_session_state(&project_id, state)?;
    db.append_log_entry(&build_log_entry(
        session_id,
        session_service::log_agent_disconnected(agent_id, reason),
        None,
        None,
    ))?;
    db.bump_change(session_id)?;
    db.bump_change("global")?;
    Ok(())
}

/// Record a signal acknowledgment, delegating to the session service.
///
/// # Errors
/// Returns `CliError` on log read/write failures.
pub fn record_signal_ack_direct(
    session_id: &str,
    request: &super::protocol::SignalAckRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<(), CliError> {
    let project_dir = Path::new(&request.project_dir);
    record_signal_ack(
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
    db: Option<&super::db::DaemonDb>,
) -> Result<bool, CliError> {
    let Some(db) = db else {
        return Err(CliErrorKind::workflow_io("delete requires a daemon DB").into());
    };
    let Some(state) = db.load_session_state_for_mutation(session_id)? else {
        return Ok(false);
    };
    destroy_session_artifacts(&state);
    db.delete_session_row(session_id)?;
    db.bump_change(session_id)?;
    db.bump_change("global")?;
    Ok(true)
}

/// Async variant of [`delete_session_direct`].
///
/// # Errors
/// Returns [`CliError`] on DB failures.
pub(crate) async fn delete_session_direct_async(
    session_id: &str,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<bool, CliError> {
    let Some(resolved) = async_db.resolve_session(session_id).await? else {
        return Ok(false);
    };
    destroy_session_artifacts(&resolved.state);
    async_db.delete_session_row(session_id).await?;
    async_db.bump_change(session_id).await?;
    async_db.bump_change("global").await?;
    Ok(true)
}
