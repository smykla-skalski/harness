use std::path::PathBuf;

use harness_daemon_snapshot as snapshot;
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_session::index::ResolvedSession;
use harness_session::service as session_service;
use harness_session::types::SessionTransition;
use harness_session::wire::{
    LeaderTransferRequest, SessionDetail, SessionEndRequest,
};
use harness_workspace::workspace::utc_now;
use tokio::task::spawn_blocking;

use crate::persistence::{
    build_log_entry, effective_project_dir, project_dir_for_db_session, refresh_signal_index,
    session_detail, session_not_found,
};
use crate::ports::{AsyncSignalStorage, SignalStorage};

/// # Errors
/// Returns an error when the session cannot be resolved or the transfer fails.
pub fn transfer_leader<S: SignalStorage>(
    session_id: &str,
    request: &LeaderTransferRequest,
    storage: Option<&S>,
) -> Result<SessionDetail, CliError> {
    if let Some(storage) = storage
        && let Some(mut state) = storage.load_session_state_for_mutation(session_id)?
    {
        let plan = session_service::apply_transfer_leader(
            &mut state,
            &request.new_leader_id,
            &request.actor,
            request.reason.as_deref(),
            &utc_now(),
        )?;
        let project_id = storage
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        storage.save_session_state(&project_id, &state)?;
        append_transfer_logs(storage, session_id, &request.actor, &plan)?;
        storage.bump_change(session_id)?;
        storage.bump_change("global")?;
        return storage.session_detail(session_id);
    }

    let resolved = harness_session::index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    session_service::transfer_leader_local(
        session_id,
        &request.new_leader_id,
        request.reason.as_deref(),
        &request.actor,
        project_dir,
    )?;
    session_detail(session_id, storage)
}

/// # Errors
/// Returns an error when the session cannot be resolved or the transfer fails.
pub async fn transfer_leader_async<A: AsyncSignalStorage>(
    session_id: &str,
    request: &LeaderTransferRequest,
    storage: &A,
) -> Result<SessionDetail, CliError> {
    let now = utc_now();
    let plan = storage
        .update_session_state_immediate(session_id, |state| {
            session_service::apply_transfer_leader(
                state,
                &request.new_leader_id,
                &request.actor,
                request.reason.as_deref(),
                &now,
            )
        })
        .await?;
    sync_file_state_from_storage_async(storage, session_id).await?;
    append_transfer_logs_async(storage, session_id, &request.actor, &plan).await?;
    bump_session_async(storage, session_id).await?;
    storage.session_detail(session_id).await
}

/// # Errors
/// Returns an error when the session cannot be resolved or ending fails.
pub fn end_session<S: SignalStorage>(
    session_id: &str,
    request: &SessionEndRequest,
    storage: Option<&S>,
) -> Result<SessionDetail, CliError> {
    if let Some(storage) = storage
        && let Some(mut state) = storage.load_session_state_for_mutation(session_id)?
    {
        let now = utc_now();
        let project_dir = project_dir_for_db_session(storage, session_id)?;
        let leave_signals =
            session_service::prepare_end_session_leave_signals(&state, &request.actor, &now)?;
        session_service::write_prepared_leave_signals(&project_dir, &leave_signals, "end session")?;
        session_service::apply_end_session(&mut state, &request.actor, &now)?;
        let project_id = storage
            .project_id_for_session(session_id)?
            .ok_or_else(|| session_not_found(session_id))?;
        storage.save_session_state(&project_id, &state)?;
        storage.mark_session_inactive(session_id)?;
        append_leave_signal_logs(storage, session_id, &request.actor, &leave_signals)?;
        storage.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_session_ended(),
            Some(&request.actor),
            None,
        ))?;
        refresh_signal_index(storage, session_id)?;
        storage.bump_change(session_id)?;
        storage.bump_change("global")?;
        return storage.session_detail(session_id);
    }

    let resolved = harness_session::index::resolve_session(session_id)?;
    let project_dir = effective_project_dir(&resolved);
    session_service::end_session_local(session_id, &request.actor, project_dir)?;
    session_detail(session_id, storage)
}

/// # Errors
/// Returns an error when the session cannot be resolved or ending fails.
#[expect(
    clippy::cognitive_complexity,
    reason = "session ending keeps state mutation and leave-signal persistence ordered"
)]
pub async fn end_session_async<A: AsyncSignalStorage>(
    session_id: &str,
    request: &SessionEndRequest,
    storage: &A,
) -> Result<SessionDetail, CliError> {
    let project_dir =
        effective_project_dir(&resolved_session_for_mutation(storage, session_id).await?)
            .to_path_buf();
    let now = utc_now();
    let leave_signals = storage
        .update_session_state_immediate(session_id, |state| {
            let leave_signals =
                session_service::prepare_end_session_leave_signals(state, &request.actor, &now)?;
            session_service::apply_end_session(state, &request.actor, &now)?;
            Ok(leave_signals)
        })
        .await?;
    sync_file_state_from_storage_async(storage, session_id).await?;
    write_prepared_leave_signals_async(project_dir.clone(), leave_signals.clone(), "end session")
        .await?;
    let resolved = resolved_session_for_mutation(storage, session_id).await?;
    persist_leave_signal_mutation(
        storage,
        &resolved,
        session_id,
        &request.actor,
        &leave_signals,
        session_service::log_session_ended(),
    )
    .await?;
    storage.session_detail(session_id).await
}

fn append_leave_signal_logs<S: SignalStorage>(
    storage: &S,
    session_id: &str,
    actor_id: &str,
    signals: &[session_service::LeaveSignalRecord],
) -> Result<(), CliError> {
    for signal in signals {
        storage.append_log_entry(&build_log_entry(
            session_id,
            session_service::log_signal_sent(
                &signal.signal.signal_id,
                &signal.agent_id,
                &signal.signal.command,
            ),
            Some(actor_id),
            None,
        ))?;
    }
    Ok(())
}

fn append_transfer_logs<S: SignalStorage>(
    storage: &S,
    session_id: &str,
    actor_id: &str,
    plan: &session_service::LeaderTransferPlan,
) -> Result<(), CliError> {
    if let Some(ref request) = plan.pending_request {
        storage.append_log_entry(&build_log_entry(
            session_id,
            SessionTransition::LeaderTransferRequested {
                from: request.current_leader_id.clone(),
                to: request.new_leader_id.clone(),
            },
            Some(actor_id),
            request.reason.as_deref(),
        ))?;
        return Ok(());
    }
    let Some(ref outcome) = plan.outcome else {
        return Ok(());
    };
    if outcome.log_request_before_transfer {
        storage.append_log_entry(&build_log_entry(
            session_id,
            SessionTransition::LeaderTransferRequested {
                from: outcome.old_leader.clone(),
                to: outcome.new_leader_id.clone(),
            },
            Some(actor_id),
            outcome.reason.as_deref(),
        ))?;
    }
    if let Some(ref confirmed_by) = outcome.confirmed_by {
        storage.append_log_entry(&build_log_entry(
            session_id,
            SessionTransition::LeaderTransferConfirmed {
                from: outcome.old_leader.clone(),
                to: outcome.new_leader_id.clone(),
                confirmed_by: confirmed_by.clone(),
            },
            Some(confirmed_by),
            outcome.reason.as_deref(),
        ))?;
    }
    storage.append_log_entry(&build_log_entry(
        session_id,
        SessionTransition::LeaderTransferred {
            from: outcome.old_leader.clone(),
            to: outcome.new_leader_id.clone(),
        },
        Some(actor_id),
        outcome.reason.as_deref(),
    ))
}

pub(crate) async fn resolved_session_for_mutation<A: AsyncSignalStorage>(
    storage: &A,
    session_id: &str,
) -> Result<ResolvedSession, CliError> {
    storage
        .resolve_session(session_id)
        .await?
        .ok_or_else(|| session_not_found(session_id))
}

pub(crate) async fn bump_session_async<A: AsyncSignalStorage>(
    storage: &A,
    session_id: &str,
) -> Result<(), CliError> {
    storage.bump_change(session_id).await?;
    storage.bump_change("global").await
}

pub(crate) async fn sync_file_state_from_storage_async<A: AsyncSignalStorage>(
    storage: &A,
    session_id: &str,
) -> Result<(), CliError> {
    let resolved = resolved_session_for_mutation(storage, session_id).await?;
    sync_file_state_for_resolved_async(&resolved).await
}

async fn sync_file_state_for_resolved_async(resolved: &ResolvedSession) -> Result<(), CliError> {
    let resolved = resolved.clone();
    spawn_blocking(move || sync_file_state_for_resolved(&resolved))
        .await
        .unwrap_or_else(|error| {
            Err(
                CliErrorKind::workflow_io(format!("session file mirror worker failed: {error}"))
                    .into(),
            )
        })
}

fn sync_file_state_for_resolved(resolved: &ResolvedSession) -> Result<(), CliError> {
    let project_dir = effective_project_dir(resolved);
    let layout =
        harness_session::storage::layout_from_project_dir(project_dir, &resolved.state.session_id)?;
    harness_session::storage::save_state(&layout, &resolved.state)
}

async fn append_transfer_logs_async<A: AsyncSignalStorage>(
    storage: &A,
    session_id: &str,
    actor_id: &str,
    plan: &session_service::LeaderTransferPlan,
) -> Result<(), CliError> {
    if let Some(ref request) = plan.pending_request {
        append_async_transfer_log(
            storage,
            session_id,
            SessionTransition::LeaderTransferRequested {
                from: request.current_leader_id.clone(),
                to: request.new_leader_id.clone(),
            },
            Some(actor_id),
            request.reason.as_deref(),
        )
        .await?;
        return Ok(());
    }
    let Some(ref outcome) = plan.outcome else {
        return Ok(());
    };
    if outcome.log_request_before_transfer {
        append_async_transfer_log(
            storage,
            session_id,
            SessionTransition::LeaderTransferRequested {
                from: outcome.old_leader.clone(),
                to: outcome.new_leader_id.clone(),
            },
            Some(actor_id),
            outcome.reason.as_deref(),
        )
        .await?;
    }
    if let Some(ref confirmed_by) = outcome.confirmed_by {
        append_async_transfer_log(
            storage,
            session_id,
            SessionTransition::LeaderTransferConfirmed {
                from: outcome.old_leader.clone(),
                to: outcome.new_leader_id.clone(),
                confirmed_by: confirmed_by.clone(),
            },
            Some(confirmed_by),
            outcome.reason.as_deref(),
        )
        .await?;
    }
    append_async_transfer_log(
        storage,
        session_id,
        SessionTransition::LeaderTransferred {
            from: outcome.old_leader.clone(),
            to: outcome.new_leader_id.clone(),
        },
        Some(actor_id),
        outcome.reason.as_deref(),
    )
    .await
}

async fn append_async_transfer_log<A: AsyncSignalStorage>(
    storage: &A,
    session_id: &str,
    transition: SessionTransition,
    actor_id: Option<&str>,
    reason: Option<&str>,
) -> Result<(), CliError> {
    storage
        .append_log_entry(&build_log_entry(session_id, transition, actor_id, reason))
        .await
}

async fn append_leave_signal_logs_async<A: AsyncSignalStorage>(
    storage: &A,
    session_id: &str,
    actor_id: &str,
    signals: &[session_service::LeaveSignalRecord],
) -> Result<(), CliError> {
    for signal in signals {
        let transition = session_service::log_signal_sent(
            &signal.signal.signal_id,
            &signal.agent_id,
            &signal.signal.command,
        );
        append_async_transfer_log_entry(storage, session_id, transition, actor_id).await?;
    }
    Ok(())
}

async fn append_async_transfer_log_entry<A: AsyncSignalStorage>(
    storage: &A,
    session_id: &str,
    transition: SessionTransition,
    actor_id: &str,
) -> Result<(), CliError> {
    storage
        .append_log_entry(&build_log_entry(
            session_id,
            transition,
            Some(actor_id),
            None,
        ))
        .await
}

async fn refresh_signal_index_for_resolved_async<A: AsyncSignalStorage>(
    storage: &A,
    resolved: &ResolvedSession,
) -> Result<(), CliError> {
    let project = resolved.project.clone();
    let state = resolved.state.clone();
    let signals = spawn_blocking(move || snapshot::load_signals_for(&project, &state))
        .await
        .unwrap_or_else(|error| {
            Err(
                CliErrorKind::workflow_io(format!("signal index refresh worker failed: {error}"))
                    .into(),
            )
        })?;
    storage
        .sync_signal_index(&resolved.state.session_id, &signals)
        .await
}

async fn persist_leave_signal_mutation<A: AsyncSignalStorage>(
    storage: &A,
    resolved: &ResolvedSession,
    session_id: &str,
    actor_id: &str,
    leave_signals: &[session_service::LeaveSignalRecord],
    transition: SessionTransition,
) -> Result<(), CliError> {
    sync_file_state_for_resolved_async(resolved).await?;
    append_leave_signal_logs_async(storage, session_id, actor_id, leave_signals).await?;
    append_async_transfer_log_entry(storage, session_id, transition, actor_id).await?;
    refresh_signal_index_for_resolved_async(storage, resolved).await?;
    bump_session_async(storage, session_id).await
}

async fn write_prepared_leave_signals_async(
    project_dir: PathBuf,
    leave_signals: Vec<session_service::LeaveSignalRecord>,
    operation: &'static str,
) -> Result<(), CliError> {
    spawn_blocking(move || {
        session_service::write_prepared_leave_signals(&project_dir, &leave_signals, operation)
    })
    .await
    .unwrap_or_else(|error| {
        Err(
            CliErrorKind::workflow_io(format!("{operation} leave-signal worker failed: {error}"))
                .into(),
        )
    })
}
