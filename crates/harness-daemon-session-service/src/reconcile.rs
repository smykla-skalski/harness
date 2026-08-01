use std::path::{Path, PathBuf};

use harness_agents::runtime::signal::{
    AckResult, SignalAck, acknowledge_signal as write_signal_ack,
};
use harness_daemon_snapshot as snapshot;
use harness_kernel::errors::CliError;
use harness_session::index::ResolvedSession;
use harness_session::service as session_service;
use harness_session::types::{SessionState, SessionTransition};
use harness_session::wire::SignalAckRequest;
use harness_workspace::workspace::utc_now;

use crate::async_ops::record_signal_ack_direct_async;
use crate::persistence::{build_log_entry, effective_project_dir};
use crate::ports::{AsyncSignalStorage, ExpiredPendingSignalIndexRecord, SignalStorage};

/// Whether a resolved session is eligible for liveness reconciliation, and if
/// so, the project directory to reconcile it against.
#[must_use]
pub fn liveness_project_dir_for_resolved(resolved: &ResolvedSession) -> Option<PathBuf> {
    if !resolved.state.status.is_liveness_eligible() || !session_has_live_agents(&resolved.state) {
        return None;
    }
    Some(effective_project_dir(resolved).to_path_buf())
}

fn session_has_live_agents(state: &SessionState) -> bool {
    state.agents.values().any(|agent| agent.status.is_alive())
}

/// Reconcile a resolved session's agent liveness and persist any transitions.
///
/// # Errors
/// Returns an error when persistence fails.
pub fn sync_resolved_liveness<S: SignalStorage>(
    storage: &S,
    resolved: &mut ResolvedSession,
    project_dir: &Path,
) -> Result<bool, CliError> {
    let now = utc_now();
    let mut result = session_service::LivenessSyncResult::default();
    let activity_map = session_service::collect_agent_activity_from_state(
        &resolved.state,
        &resolved.state.session_id,
        project_dir,
    );
    let changed = session_service::apply_liveness_transitions(
        &mut resolved.state,
        &activity_map,
        &now,
        &mut result,
    );
    if !changed {
        return Ok(false);
    }

    session_service::refresh_session(&mut resolved.state, &now);
    storage.save_session_state(&resolved.project.project_id, &resolved.state)?;
    if !result.disconnected.is_empty() || !result.idled.is_empty() {
        storage.append_log_entry(&build_log_entry(
            &resolved.state.session_id,
            SessionTransition::LivenessSynced {
                disconnected: result.disconnected.clone(),
                idled: result.idled.clone(),
            },
            None,
            Some("liveness sync"),
        ))?;
    }
    session_service::cleanup_dead_agent_signals(
        &activity_map,
        &result,
        &resolved.state.session_id,
        project_dir,
    );
    if !result.disconnected.is_empty() {
        let signals = snapshot::load_signals_for(&resolved.project, &resolved.state)?;
        storage.sync_signal_index(&resolved.state.session_id, &signals)?;
    }
    storage.bump_change(&resolved.state.session_id)?;
    storage.bump_change("global")?;
    Ok(true)
}

/// Async counterpart of [`sync_resolved_liveness`].
///
/// # Errors
/// Returns an error when persistence fails.
pub async fn sync_resolved_liveness_async<A: AsyncSignalStorage>(
    storage: &A,
    resolved: &mut ResolvedSession,
    project_dir: &Path,
) -> Result<bool, CliError> {
    let now = utc_now();
    let mut result = session_service::LivenessSyncResult::default();
    let activity_map = session_service::collect_agent_activity_from_state(
        &resolved.state,
        &resolved.state.session_id,
        project_dir,
    );
    let changed = session_service::apply_liveness_transitions(
        &mut resolved.state,
        &activity_map,
        &now,
        &mut result,
    );
    if !changed {
        return Ok(false);
    }

    session_service::refresh_session(&mut resolved.state, &now);
    storage
        .save_session_state(&resolved.project.project_id, &resolved.state)
        .await?;
    if !result.disconnected.is_empty() || !result.idled.is_empty() {
        storage
            .append_log_entry(&build_log_entry(
                &resolved.state.session_id,
                SessionTransition::LivenessSynced {
                    disconnected: result.disconnected.clone(),
                    idled: result.idled.clone(),
                },
                None,
                Some("liveness sync"),
            ))
            .await?;
    }
    session_service::cleanup_dead_agent_signals(
        &activity_map,
        &result,
        &resolved.state.session_id,
        project_dir,
    );
    if !result.disconnected.is_empty() {
        let signals = snapshot::load_signals_for(&resolved.project, &resolved.state)?;
        storage
            .sync_signal_index(&resolved.state.session_id, &signals)
            .await?;
    }
    storage.bump_change(&resolved.state.session_id).await?;
    storage.bump_change("global").await?;
    Ok(true)
}

/// Expire pending signals whose delivery window has passed and record the
/// expiry acknowledgment.
///
/// # Errors
/// Returns an error when persistence fails.
pub fn reconcile_expired_pending_signals<S: SignalStorage>(
    session_id: &str,
    storage: &S,
) -> Result<(), CliError> {
    let expired = storage.load_expired_pending_signals(session_id)?;
    if expired.is_empty() {
        return Ok(());
    }

    let Some(state) = storage.load_session_state_for_mutation(session_id)? else {
        return Ok(());
    };
    let Some(project_dir) = storage.project_dir_for_session(session_id)? else {
        return Ok(());
    };
    let project_dir = PathBuf::from(project_dir);
    let context_root = session_service::signal_context_root(&project_dir);
    let mut needs_filesystem_fallback = false;

    for indexed_signal in &expired {
        if !acknowledge_indexed_expired_signal(
            session_id,
            &project_dir,
            &context_root,
            &state,
            storage,
            indexed_signal,
        )? {
            needs_filesystem_fallback = true;
        }
    }

    if needs_filesystem_fallback {
        let expired =
            session_service::collect_expired_pending_signals_for_state(&state, &project_dir)?;
        for signal in expired {
            let ack = SignalAck {
                signal_id: signal.signal.signal_id.clone(),
                acknowledged_at: utc_now(),
                result: AckResult::Expired,
                agent: signal.signal_session_id.clone(),
                session_id: session_id.to_string(),
                details: Some("expired before agent acknowledged delivery".to_string()),
            };
            write_signal_ack(&signal.signal_dir, &ack)?;
            crate::record_signal_ack(
                session_id,
                &signal.agent_id,
                &signal.signal.signal_id,
                AckResult::Expired,
                &project_dir,
                Some(storage),
            )?;
        }
    }

    Ok(())
}

fn acknowledge_indexed_expired_signal<S: SignalStorage>(
    session_id: &str,
    project_dir: &Path,
    context_root: &Path,
    state: &SessionState,
    storage: &S,
    indexed_signal: &ExpiredPendingSignalIndexRecord,
) -> Result<bool, CliError> {
    let Some(agent) = state.agents.get(&indexed_signal.agent_id) else {
        return Ok(false);
    };
    let Some(runtime) = harness_agents::runtime::runtime_for_name(&indexed_signal.runtime) else {
        return Ok(false);
    };

    let Some((signal_session_id, signal_dir)) =
        session_service::signal_dirs_for_agent_in_context_root(
            runtime,
            session_id,
            agent.agent_session_id.as_deref(),
            context_root,
        )
        .into_iter()
        .find(|(_, signal_dir)| {
            harness_agents::runtime::signal::pending_dir(signal_dir)
                .join(format!("{}.json", indexed_signal.signal.signal_id))
                .is_file()
        })
    else {
        return Ok(false);
    };

    let ack = SignalAck {
        signal_id: indexed_signal.signal.signal_id.clone(),
        acknowledged_at: utc_now(),
        result: AckResult::Expired,
        agent: signal_session_id,
        session_id: session_id.to_string(),
        details: Some("expired before agent acknowledged delivery".to_string()),
    };
    write_signal_ack(&signal_dir, &ack)?;
    crate::record_signal_ack(
        session_id,
        &indexed_signal.agent_id,
        &indexed_signal.signal.signal_id,
        AckResult::Expired,
        project_dir,
        Some(storage),
    )?;
    Ok(true)
}

/// Async counterpart of [`reconcile_expired_pending_signals`].
///
/// # Errors
/// Returns an error when persistence fails.
pub async fn reconcile_expired_pending_signals_async<A: AsyncSignalStorage>(
    session_id: &str,
    storage: &A,
) -> Result<(), CliError> {
    let expired = storage.load_expired_pending_signals(session_id).await?;
    if expired.is_empty() {
        return Ok(());
    }

    let Some(resolved) = storage.resolve_session(session_id).await? else {
        return Ok(());
    };
    let project_dir = effective_project_dir(&resolved).to_path_buf();
    let context_root = session_service::signal_context_root(&project_dir);
    let mut needs_filesystem_fallback = false;
    for indexed_signal in &expired {
        if !acknowledge_indexed_expired_signal_async(
            session_id,
            &project_dir,
            &context_root,
            &resolved.state,
            storage,
            indexed_signal,
        )
        .await?
        {
            needs_filesystem_fallback = true;
        }
    }

    if needs_filesystem_fallback {
        let expired = session_service::collect_expired_pending_signals_for_state(
            &resolved.state,
            &project_dir,
        )?;
        for signal in expired {
            let ack = SignalAck {
                signal_id: signal.signal.signal_id.clone(),
                acknowledged_at: utc_now(),
                result: AckResult::Expired,
                agent: signal.signal_session_id.clone(),
                session_id: session_id.to_string(),
                details: Some("expired before agent acknowledged delivery".to_string()),
            };
            write_signal_ack(&signal.signal_dir, &ack)?;
            record_signal_ack_direct_async(
                session_id,
                &SignalAckRequest {
                    agent_id: signal.agent_id,
                    signal_id: signal.signal.signal_id,
                    result: AckResult::Expired,
                    project_dir: project_dir.display().to_string(),
                },
                storage,
            )
            .await?;
        }
    }

    Ok(())
}

async fn acknowledge_indexed_expired_signal_async<A: AsyncSignalStorage>(
    session_id: &str,
    project_dir: &Path,
    context_root: &Path,
    state: &SessionState,
    storage: &A,
    indexed_signal: &ExpiredPendingSignalIndexRecord,
) -> Result<bool, CliError> {
    let Some(agent) = state.agents.get(&indexed_signal.agent_id) else {
        return Ok(false);
    };
    let Some(runtime) = harness_agents::runtime::runtime_for_name(&indexed_signal.runtime) else {
        return Ok(false);
    };

    let Some((signal_session_id, signal_dir)) =
        session_service::signal_dirs_for_agent_in_context_root(
            runtime,
            session_id,
            agent.agent_session_id.as_deref(),
            context_root,
        )
        .into_iter()
        .find(|(_, signal_dir)| {
            harness_agents::runtime::signal::pending_dir(signal_dir)
                .join(format!("{}.json", indexed_signal.signal.signal_id))
                .is_file()
        })
    else {
        return Ok(false);
    };

    let ack = SignalAck {
        signal_id: indexed_signal.signal.signal_id.clone(),
        acknowledged_at: utc_now(),
        result: AckResult::Expired,
        agent: signal_session_id,
        session_id: session_id.to_string(),
        details: Some("expired before agent acknowledged delivery".to_string()),
    };
    write_signal_ack(&signal_dir, &ack)?;
    record_signal_ack_direct_async(
        session_id,
        &SignalAckRequest {
            agent_id: indexed_signal.agent_id.clone(),
            signal_id: indexed_signal.signal.signal_id.clone(),
            result: AckResult::Expired,
            project_dir: project_dir.display().to_string(),
        },
        storage,
    )
    .await?;
    Ok(true)
}
