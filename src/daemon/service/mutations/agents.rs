use super::super::{
    AgentRemoveRequest, CliError, RoleChangeRequest, SessionDetail, append_leave_signal_logs_to_db,
    build_log_entry, effective_project_dir, index, project_dir_for_db_session,
    refresh_signal_index_for_db, session_detail, session_detail_from_daemon_db, session_not_found,
    session_service, slice, utc_now,
};

/// Change an agent role through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the role change fails.
pub fn change_role(
    session_id: &str,
    agent_id: &str,
    request: &RoleChangeRequest,
    db: Option<&super::super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        let from_role = session_service::apply_assign_role(
            &mut state,
            agent_id,
            request.role,
            &request.actor,
            &utc_now(),
        )?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_role_changed(agent_id, from_role, request.role),
            Some(&request.actor),
            request.reason.as_deref(),
        ))?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail_from_daemon_db(session_id, db);
    }

    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    session_service::assign_role(
        session_id,
        agent_id,
        request.role,
        request.reason.as_deref(),
        &request.actor,
        project_dir,
    )?;
    session_detail(session_id, db)
}

/// Remove an agent through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the removal fails.
pub fn remove_agent(
    session_id: &str,
    agent_id: &str,
    request: &AgentRemoveRequest,
    db: Option<&super::super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        let now = utc_now();
        let project_dir = project_dir_for_db_session(db, session_id)?;
        let leave_signal = session_service::prepare_remove_agent_leave_signal(
            &state,
            agent_id,
            &request.actor,
            &now,
        )?;
        if let Some(ref signal) = leave_signal {
            session_service::write_prepared_leave_signals(
                &project_dir,
                slice::from_ref(signal),
                "remove agent",
            )?;
        }
        session_service::apply_remove_agent(&mut state, agent_id, &request.actor, &now)?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        if let Some(ref signal) = leave_signal {
            append_leave_signal_logs_to_db(
                db,
                session_id,
                &request.actor,
                slice::from_ref(signal),
            )?;
        }
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_agent_removed(agent_id),
            Some(&request.actor),
            None,
        ))?;
        refresh_signal_index_for_db(db, session_id)?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail_from_daemon_db(session_id, db);
    }

    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    session_service::remove_agent(session_id, agent_id, &request.actor, project_dir)?;
    session_detail(session_id, db)
}
