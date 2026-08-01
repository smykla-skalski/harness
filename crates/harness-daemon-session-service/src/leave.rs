use harness_kernel::errors::CliError;
use harness_session::service as session_service;
use harness_session::types::SessionTransition;
use harness_session::wire::{SessionDetail, SessionLeaveRequest};
use harness_workspace::workspace::utc_now;

use crate::mutations::sync_file_state_from_storage_async;
use crate::persistence::{
    build_log_entry, effective_project_dir, session_detail, session_not_found,
};
use crate::ports::{AsyncSignalStorage, SignalStorage};

/// # Errors
/// Returns an error when the session cannot be resolved or the leave fails.
pub fn leave_session<S: SignalStorage>(
    session_id: &str,
    request: &SessionLeaveRequest,
    storage: Option<&S>,
) -> Result<SessionDetail, CliError> {
    if let Some(storage) = storage
        && let Some(mut state) = storage.load_session_state_for_mutation(session_id)?
    {
        session_service::apply_leave_session(&mut state, &request.agent_id, &utc_now())?;
        let project_id = storage
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        storage.save_session_state(&project_id, &state)?;
        storage.append_log_entry(&build_log_entry(
            session_id,
            SessionTransition::AgentLeft {
                agent_id: request.agent_id.clone(),
            },
            Some(&request.agent_id),
            None,
        ))?;
        storage.bump_change(session_id)?;
        storage.bump_change("global")?;
        return storage.session_detail(session_id);
    }

    let resolved = harness_session::index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    session_service::leave_session(session_id, &request.agent_id, project_dir)?;
    session_detail(session_id, storage)
}

/// # Errors
/// Returns an error when the session cannot be resolved or the leave fails.
pub async fn leave_session_async<A: AsyncSignalStorage>(
    session_id: &str,
    request: &SessionLeaveRequest,
    storage: &A,
) -> Result<SessionDetail, CliError> {
    let now = utc_now();
    storage
        .update_session_state_immediate(session_id, |state| {
            session_service::apply_leave_session(state, &request.agent_id, &now)
        })
        .await?;
    sync_file_state_from_storage_async(storage, session_id).await?;
    storage
        .append_log_entry(&build_log_entry(
            session_id,
            SessionTransition::AgentLeft {
                agent_id: request.agent_id.clone(),
            },
            Some(&request.agent_id),
            None,
        ))
        .await?;
    storage.bump_change(session_id).await?;
    storage.bump_change("global").await?;
    storage.session_detail(session_id).await
}
