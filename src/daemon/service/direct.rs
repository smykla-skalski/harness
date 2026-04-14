use super::{SessionState, CliError, resolve_hook_agent, CliErrorKind, Path, agents_service, utc_now, session_service, build_log_entry, session_storage, index, SessionRole, session_not_found, record_signal_ack};

/// Start a new session, writing directly to `SQLite` when a DB is available.
///
/// Falls back to file-based session creation when `db` is `None`.
///
/// # Errors
/// Returns `CliError` when the runtime is unknown or DB operations fail.
pub fn start_session_direct(
    request: &super::protocol::SessionStartRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionState, CliError> {
    let runtime_name = &request.runtime;
    let leader_runtime = resolve_hook_agent(runtime_name).ok_or_else(|| {
        CliError::from(CliErrorKind::session_agent_conflict(format!(
            "session start requires a known runtime, got '{runtime_name}'"
        )))
    })?;

    let project_dir = Path::new(&request.project_dir);
    let leader_agent_session_id =
        agents_service::resolve_known_session_id(leader_runtime, project_dir, None)?;
    let now = utc_now();
    let session_id = request
        .session_id
        .clone()
        .unwrap_or_else(|| format!("sess-{}", chrono::Utc::now().format("%Y%m%d%H%M%S%f")));

    let state = session_service::build_new_session(
        &request.context,
        &request.title,
        &session_id,
        runtime_name,
        leader_agent_session_id.as_deref(),
        &now,
    );

    if let Some(db) = db {
        let project_id = ensure_project_registered(db, project_dir)?;
        db.create_session_record(&project_id, &state)?;
        let leader_id = state.leader_id.as_deref().unwrap_or("");
        db.append_log_entry(&build_log_entry(
            &session_id,
            session_service::log_session_started(&request.title, &request.context),
            Some(leader_id),
            None,
        ))?;
        db.bump_change(&session_id)?;
        db.bump_change("global")?;
        return Ok(state);
    }

    // File-based fallback
    session_service::start_session(
        &request.context,
        &request.title,
        project_dir,
        Some(runtime_name),
        Some(&session_id),
    )
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

/// Join an existing session, writing directly to `SQLite` when a DB is available.
///
/// # Errors
/// Returns `CliError` when the session or runtime is unknown, or DB operations fail.
pub fn join_session_direct(
    session_id: &str,
    request: &super::protocol::SessionJoinRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionState, CliError> {
    if request.role == SessionRole::Leader {
        return Err(CliErrorKind::session_agent_conflict(
            "daemon join requests cannot claim the leader role",
        )
        .into());
    }
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
        let agent_id = session_service::apply_join_session(
            &mut state,
            &display_name,
            &request.runtime,
            request.role,
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
            session_service::log_agent_joined(&agent_id, request.role, &request.runtime),
            None,
            None,
        ))?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return Ok(state);
    }

    // File-based fallback
    session_service::join_session(
        session_id,
        request.role,
        &request.runtime,
        &request.capabilities,
        request.name.as_deref(),
        project_dir,
        request.persona.as_deref(),
    )
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
