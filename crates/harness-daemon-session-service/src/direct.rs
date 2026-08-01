use harness_kernel::errors::{CliError, CliErrorKind};
use harness_session::service as session_service;
use harness_session::types::{ManagedAgentRef, SessionState};
use harness_session::wire::{
    AgentRuntimeSessionRegistrationRequest, SessionJoinRequest, SessionStartRequest,
    SessionTitleRequest,
};
use harness_workspace::workspace::utc_now;
use std::path::Path;
use tokio::task::spawn_blocking;

use crate::mutations::sync_file_state_from_storage_async;
use crate::persistence::{build_log_entry, session_not_found};
use crate::ports::{AsyncSignalStorage, SignalStorage};
use crate::session_setup::{
    PreparedSession, prepare_session, rollback_session_artifacts, rollback_session_artifacts_async,
};
use crate::session_teardown::destroy_session_artifacts;

/// Start a new session, writing directly to storage when available.
/// Creates a per-session linked checkout and records the state file under the
/// session root.
///
/// # Errors
/// Returns an error when the worktree cannot be created or persistence fails.
pub fn start_session<S: SignalStorage>(
    request: &SessionStartRequest,
    storage: Option<&S>,
) -> Result<SessionState, CliError> {
    let Some(storage) = storage else {
        // No local storage: route through start_session_with_policy. That
        // helper first tries to forward to a running harness daemon over
        // HTTP - the receiving daemon (which always has its own storage)
        // creates the worktree via start_session_async. When no daemon is
        // reachable, the helper falls back to the legacy file-based path
        // which intentionally does NOT create a worktree, since per the
        // workspace-layout spec the daemon owns worktree lifecycle and a
        // file-only fallback session never gains one.
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
        project,
        state,
    } = prepared;

    let project_id = project.project_id.clone();
    if let Err(error) = storage.sync_project(&project) {
        rollback_session_artifacts(&canonical_origin, &layout);
        return Err(error);
    }
    if let Err(error) = storage.create_session_record(&project_id, &state) {
        rollback_session_artifacts(&canonical_origin, &layout);
        return Err(error);
    }
    storage.append_log_entry(&build_log_entry(
        &state.session_id,
        session_service::log_session_started(&request.title, &request.context),
        None,
        None,
    ))?;
    storage.bump_change(&state.session_id)?;
    storage.bump_change("global")?;
    Ok(state)
}

/// Start a new session through storage's async path.
/// Creates a per-session worktree; rolls it back on persistence failure.
///
/// # Errors
/// Returns an error when the worktree cannot be created or persistence fails.
#[expect(
    clippy::cognitive_complexity,
    reason = "session creation must pair each persistence failure with asynchronous artifact rollback"
)]
pub async fn start_session_async<A: AsyncSignalStorage>(
    request: &SessionStartRequest,
    storage: &A,
) -> Result<SessionState, CliError> {
    let request_for_worker = request.clone();
    let prepared = spawn_blocking(move || prepare_session(&request_for_worker))
        .await
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("join session preparation worker: {error}"))
        })??;
    let PreparedSession {
        layout,
        canonical_origin,
        project,
        state,
    } = prepared;

    let project_id = project.project_id.clone();
    if let Err(error) = storage.sync_project(&project).await {
        rollback_session_artifacts_async(canonical_origin, layout).await;
        return Err(error);
    }
    if let Err(error) = storage.create_session_record(&project_id, &state).await {
        rollback_session_artifacts_async(canonical_origin, layout).await;
        return Err(error);
    }
    storage
        .append_log_entry(&build_log_entry(
            &state.session_id,
            session_service::log_session_started(&request.title, &request.context),
            None,
            None,
        ))
        .await?;
    storage.bump_change(&state.session_id).await?;
    storage.bump_change("global").await?;
    Ok(state)
}

/// Destroy the session worktree, deregister it from the active registry,
/// and delete the storage row. Returns `Ok(false)` when not found.
///
/// # Errors
/// Persistence failures return an error. `None` storage returns an error
/// because DELETE has no file-based fallback path.
pub fn delete_session<S: SignalStorage>(
    session_id: &str,
    storage: Option<&S>,
) -> Result<bool, CliError> {
    let Some(storage) = storage else {
        return Err(CliErrorKind::workflow_io("delete requires a daemon database").into());
    };
    let Some(state) = storage.load_session_state_for_mutation(session_id)? else {
        return Ok(false);
    };
    destroy_session_artifacts(&state);
    storage.delete_session_row(session_id)?;
    storage.bump_change(session_id)?;
    storage.bump_change("global")?;
    Ok(true)
}

/// Async variant of [`delete_session`].
///
/// # Errors
/// Returns an error on persistence failures.
pub async fn delete_session_async<A: AsyncSignalStorage>(
    session_id: &str,
    storage: &A,
) -> Result<bool, CliError> {
    let Some(state) = storage.load_session_state(session_id).await? else {
        return Ok(false);
    };
    destroy_session_artifacts(&state);
    storage.delete_session_row(session_id).await?;
    storage.bump_change(session_id).await?;
    storage.bump_change("global").await?;
    Ok(true)
}

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
