use super::{
    CliError, SessionDetail, SessionLeaveRequest, SessionTransition, build_log_entry,
    effective_project_dir, index, session_detail, session_detail_from_async_daemon_db,
    session_detail_from_daemon_db, session_not_found, session_service, utc_now,
};

/// Mark an agent as disconnected through the shared daemon session service.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the leave fails.
pub fn leave_session(
    session_id: &str,
    request: &SessionLeaveRequest,
    db: Option<&super::db::DaemonDb>,
) -> Result<SessionDetail, CliError> {
    if let Some(db) = db
        && let Some(mut state) = db.load_session_state_for_mutation(session_id)?
    {
        session_service::apply_leave_session(&mut state, &request.agent_id, &utc_now())?;
        let project_id = db
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        db.save_session_state(&project_id, &state)?;
        db.append_log_entry(&build_log_entry(
            session_id,
            SessionTransition::AgentLeft {
                agent_id: request.agent_id.clone(),
            },
            Some(&request.agent_id),
            None,
        ))?;
        db.bump_change(session_id)?;
        db.bump_change("global")?;
        return session_detail_from_daemon_db(session_id, db);
    }

    let resolved = index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    session_service::leave_session(session_id, &request.agent_id, project_dir)?;
    session_detail(session_id, db)
}

/// Mark an agent as disconnected through the canonical async daemon DB.
///
/// # Errors
/// Returns `CliError` when the session cannot be resolved or the leave fails.
pub(crate) async fn leave_session_async(
    session_id: &str,
    request: &SessionLeaveRequest,
    async_db: &super::db::AsyncDaemonDb,
) -> Result<SessionDetail, CliError> {
    let mut resolved = async_db
        .resolve_session(session_id)
        .await?
        .ok_or_else(|| session_not_found(session_id))?;
    session_service::apply_leave_session(&mut resolved.state, &request.agent_id, &utc_now())?;
    async_db
        .save_session_state(&resolved.project.project_id, &resolved.state)
        .await?;
    async_db
        .append_log_entry(&build_log_entry(
            session_id,
            SessionTransition::AgentLeft {
                agent_id: request.agent_id.clone(),
            },
            Some(&request.agent_id),
            None,
        ))
        .await?;
    async_db.bump_change(session_id).await?;
    async_db.bump_change("global").await?;
    session_detail_from_async_daemon_db(session_id, async_db).await
}
