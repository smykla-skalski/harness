use super::super::{
    CliError, LeaderTransferRequest, SessionDetail, SessionEndRequest,
    append_leave_signal_logs_to_db, append_transfer_logs_to_db, build_log_entry,
    effective_project_dir, index, project_dir_for_db_session, refresh_signal_index_for_db,
    session_detail, session_detail_from_daemon_db, session_not_found, session_service, utc_now,
};

/// Transfer session leadership through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the transfer fails.
pub fn transfer_leader(
    session_id: &str,
    request: &LeaderTransferRequest,
    db: Option<&super::super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        let plan = session_service::apply_transfer_leader(
            &mut state,
            &request.new_leader_id,
            &request.actor,
            request.reason.as_deref(),
            &utc_now(),
        )?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        append_transfer_logs_to_db(db, session_id, &request.actor, &plan)?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail_from_daemon_db(session_id, db);
    }

    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    session_service::transfer_leader(
        session_id,
        &request.new_leader_id,
        request.reason.as_deref(),
        &request.actor,
        project_dir,
    )?;
    session_detail(session_id, db)
}

/// End a session through the shared session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or ending fails.
pub fn end_session(
    session_id: &str,
    request: &SessionEndRequest,
    db: Option<&super::super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        let now = utc_now();
        let project_dir = project_dir_for_db_session(db, session_id)?;
        let leave_signals =
            session_service::prepare_end_session_leave_signals(&state, &request.actor, &now)?;
        session_service::write_prepared_leave_signals(&project_dir, &leave_signals, "end session")?;
        session_service::apply_end_session(&mut state, &request.actor, &now)?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.mark_session_inactive(session_id)?;
        append_leave_signal_logs_to_db(db, session_id, &request.actor, &leave_signals)?;
        db.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_session_ended(),
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
    session_service::end_session(session_id, &request.actor, project_dir)?;
    session_detail(session_id, db)
}
