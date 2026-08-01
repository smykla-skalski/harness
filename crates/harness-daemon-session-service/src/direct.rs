use harness_kernel::errors::CliError;
use harness_session::service as session_service;
use harness_session::types::{ManagedAgentRef, SessionState};
use harness_session::wire::{
    AgentRuntimeSessionRegistrationRequest, SessionJoinRequest, SessionTitleRequest,
};
use harness_workspace::workspace::utc_now;
use std::path::Path;

use crate::mutations::sync_file_state_from_storage_async;
use crate::persistence::{build_log_entry, session_not_found};
use crate::ports::{AsyncSignalStorage, SignalStorage};

/// # Errors
/// Returns `CliError` when the session or runtime is unknown, or DB operations fail.
pub fn join_session<S: SignalStorage>(
    session_id: &str,
    request: &SessionJoinRequest,
    agent_session_id: Option<&str>,
    storage: Option<&S>,
) -> Result<SessionState, CliError> {
    let display_name = request
        .name
        .clone()
        .unwrap_or_else(|| format!("{} {:?}", request.runtime, request.role).to_lowercase());
    let project_dir = Path::new(&request.project_dir);

    if let Some(storage) = storage
        && let Some(mut state) = storage.load_session_state_for_mutation(session_id)?
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
            agent_session_id,
            &now,
            request.persona.as_deref(),
            None,
        )?;
        let project_id = storage
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        storage.save_session_state(&project_id, &state)?;
        storage.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_agent_joined(&agent_id, joined_role, &request.runtime),
            None,
            None,
        ))?;
        storage.bump_change(session_id)?;
        storage.bump_change("global")?;
        return Ok(state);
    }

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

/// # Errors
/// Returns `CliError` when the session or runtime is unknown, or async DB
/// operations fail.
pub async fn join_session_async<A: AsyncSignalStorage>(
    session_id: &str,
    request: &SessionJoinRequest,
    agent_session_id: Option<&str>,
    storage: &A,
) -> Result<SessionState, CliError> {
    let display_name = request
        .name
        .clone()
        .unwrap_or_else(|| format!("{} {:?}", request.runtime, request.role).to_lowercase());

    let now = utc_now();
    let (agent_id, joined_role, state) = storage
        .update_session_state_immediate(session_id, |state| {
            let joined_role =
                session_service::resolve_join_role(state, request.role, request.fallback_role)?;
            let agent_id = session_service::apply_join_session(
                state,
                &display_name,
                &request.runtime,
                joined_role,
                &request.capabilities,
                agent_session_id,
                &now,
                request.persona.as_deref(),
                None,
            )?;
            Ok((agent_id, joined_role, state.clone()))
        })
        .await?;
    sync_file_state_from_storage_async(storage, session_id).await?;
    storage
        .append_log_entry(&build_log_entry(
            session_id,
            session_service::log_agent_joined(&agent_id, joined_role, &request.runtime),
            None,
            None,
        ))
        .await?;
    storage.bump_change(session_id).await?;
    storage.bump_change("global").await?;
    Ok(state)
}

/// # Errors
/// Returns `CliError` when the session lookup, state mutation, or persistence fails.
pub fn register_agent_runtime_session<S: SignalStorage>(
    session_id: &str,
    request: &AgentRuntimeSessionRegistrationRequest,
    storage: Option<&S>,
) -> Result<bool, CliError> {
    if let Some(storage) = storage
        && let Some(mut state) = storage.load_session_state_for_mutation(session_id)?
    {
        let now = utc_now();
        let registered = session_service::apply_register_agent_runtime_session(
            &mut state,
            &request.runtime,
            &ManagedAgentRef::tui(request.managed_agent_id.as_str()),
            &request.runtime_session_id,
            &now,
        )?;
        if !registered {
            return Ok(false);
        }
        let project_id = storage
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        storage.save_session_state(&project_id, &state)?;
        storage.bump_change(session_id)?;
        storage.bump_change("global")?;
        return Ok(true);
    }

    session_service::register_agent_runtime_session(
        session_id,
        &request.runtime,
        &request.managed_agent_id,
        &request.runtime_session_id,
        Path::new(&request.project_dir),
    )
}

/// # Errors
/// Returns `CliError` when the session lookup, state mutation, or persistence fails.
pub async fn register_agent_runtime_session_async<A: AsyncSignalStorage>(
    session_id: &str,
    request: &AgentRuntimeSessionRegistrationRequest,
    storage: &A,
) -> Result<bool, CliError> {
    let now = utc_now();
    let registered = storage
        .update_session_state_immediate(session_id, |state| {
            session_service::apply_register_agent_runtime_session(
                state,
                &request.runtime,
                &ManagedAgentRef::tui(request.managed_agent_id.as_str()),
                &request.runtime_session_id,
                &now,
            )
        })
        .await?;
    if !registered {
        return Ok(false);
    }
    sync_file_state_from_storage_async(storage, session_id).await?;
    storage.bump_change(session_id).await?;
    storage.bump_change("global").await?;
    Ok(true)
}

/// # Errors
/// Returns `CliError` when the session is unknown or DB operations fail.
pub fn update_session_title<S: SignalStorage>(
    session_id: &str,
    request: &SessionTitleRequest,
    storage: &S,
) -> Result<SessionState, CliError> {
    let Some(mut state) = storage.load_session_state_for_mutation(session_id)? else {
        return Err(session_not_found(session_id));
    };

    state.state_version += 1;
    session_service::apply_update_session_title(&mut state, &request.title, &utc_now())?;
    let project_id = storage
        .project_id_for_session(session_id)?
        .ok_or_else(|| session_not_found(session_id))?;
    storage.save_session_state(&project_id, &state)?;
    storage.bump_change(session_id)?;
    storage.bump_change("global")?;
    Ok(state)
}

/// # Errors
/// Returns `CliError` when the session is unknown or async DB operations fail.
pub async fn update_session_title_async<A: AsyncSignalStorage>(
    session_id: &str,
    request: &SessionTitleRequest,
    storage: &A,
) -> Result<SessionState, CliError> {
    let now = utc_now();
    let state = storage
        .update_session_state_immediate(session_id, |state| {
            state.state_version += 1;
            session_service::apply_update_session_title(state, &request.title, &now)?;
            Ok(state.clone())
        })
        .await?;
    sync_file_state_from_storage_async(storage, session_id).await?;
    storage.bump_change(session_id).await?;
    storage.bump_change("global").await?;
    Ok(state)
}

/// Returns `Ok(false)` when the agent is already non-live or missing.
///
/// # Errors
/// Returns `CliError` when the session cannot be loaded or persisted.
pub fn disconnect_agent<S: SignalStorage>(
    session_id: &str,
    agent_id: &str,
    reason: &str,
    storage: Option<&S>,
) -> Result<bool, CliError> {
    let Some(storage) = storage else {
        return Ok(false);
    };
    let Some(mut state) = storage.load_session_state_for_mutation(session_id)? else {
        return Ok(false);
    };

    let now = utc_now();
    if !session_service::apply_agent_disconnected(&mut state, agent_id, &now) {
        return Ok(false);
    }

    persist_disconnect(storage, session_id, agent_id, reason, &state)?;
    Ok(true)
}

/// Returns `Ok(false)` when the agent is already non-live or missing.
///
/// # Errors
/// Returns `CliError` when the session cannot be loaded or persisted.
pub async fn disconnect_agent_async<A: AsyncSignalStorage>(
    session_id: &str,
    agent_id: &str,
    reason: &str,
    storage: &A,
) -> Result<bool, CliError> {
    let now = utc_now();
    let disconnected = storage
        .update_session_state_immediate(session_id, |state| {
            Ok(session_service::apply_agent_disconnected(
                state, agent_id, &now,
            ))
        })
        .await?;
    if !disconnected {
        return Ok(false);
    }

    sync_file_state_from_storage_async(storage, session_id).await?;
    storage
        .append_log_entry(&build_log_entry(
            session_id,
            session_service::log_agent_disconnected(agent_id, reason),
            None,
            None,
        ))
        .await?;
    storage.bump_change(session_id).await?;
    storage.bump_change("global").await?;
    Ok(true)
}

/// # Errors
/// Returns `CliError` when the session cannot be loaded or persisted.
pub fn persist_disconnect<S: SignalStorage>(
    storage: &S,
    session_id: &str,
    agent_id: &str,
    reason: &str,
    state: &SessionState,
) -> Result<(), CliError> {
    let project_id = storage
        .project_id_for_session(session_id)?
        .ok_or_else(|| session_not_found(session_id))?;
    storage.save_session_state(&project_id, state)?;
    storage.append_log_entry(&build_log_entry(
        session_id,
        session_service::log_agent_disconnected(agent_id, reason),
        None,
        None,
    ))?;
    storage.bump_change(session_id)?;
    storage.bump_change("global")?;
    Ok(())
}
